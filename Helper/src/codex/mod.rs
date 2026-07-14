mod parser;

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use chrono::NaiveDate;
use rayon::prelude::*;
use serde_json::Value;

use crate::pricing::CodexPricing;
use crate::usage::{CostSource, UnifiedMessage};

#[derive(Debug, Clone, Default)]
pub struct LocalParseOptions {
    pub home_dir: Option<String>,
    pub use_env_roots: bool,
    pub since: Option<String>,
    pub until: Option<String>,
}

/// Parse local Codex usage without consulting Tokscale code, directories, or
/// pricing state.
pub fn parse_local_codex_messages(
    options: LocalParseOptions,
    pricing: &CodexPricing,
) -> Result<Vec<UnifiedMessage>, String> {
    let paths = discover_codex_files(&options)?;
    let mut messages = Vec::new();
    let mut seen_dedup_keys = HashSet::new();

    let parsed_files = paths
        .par_iter()
        .map(|path| parser::parse_codex_file(path).ok())
        .collect::<Vec<_>>();
    for (path, file_messages) in paths.iter().zip(parsed_files) {
        let path_text = path.to_string_lossy().into_owned();
        let Some(file_messages) = file_messages else {
            continue;
        };
        for mut message in file_messages {
            message.session_path = Some(path_text.clone());
            message.refresh_derived_fields();
            if message
                .dedup_key
                .as_ref()
                .is_some_and(|key| !seen_dedup_keys.insert(key.clone()))
            {
                continue;
            }
            messages.push(message);
        }
    }

    assign_subagent_messages_to_root_sessions(&mut messages, &paths);
    for message in &mut messages {
        apply_pricing(message, pricing);
    }
    if let Some(since) = options.since.as_deref() {
        messages.retain(|message| message.date.as_str() >= since);
    }
    if let Some(until) = options.until.as_deref() {
        messages.retain(|message| message.date.as_str() <= until);
    }
    Ok(messages)
}

fn apply_pricing(message: &mut UnifiedMessage, pricing: &CodexPricing) {
    message.cost = 0.0;
    message.cost_source = CostSource::Unknown;
    if let Some(cost) = pricing.calculate_cost_with_provider(
        &message.model_id,
        Some(&message.provider_id),
        &message.tokens,
    ) {
        message.cost = cost;
        message.cost_source = CostSource::Estimated;
    }
}

fn discover_codex_files(options: &LocalParseOptions) -> Result<Vec<PathBuf>, String> {
    let home = options
        .home_dir
        .as_deref()
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
        .ok_or("could not resolve the home directory")?;
    let codex_home = if options.home_dir.is_none() && options.use_env_roots {
        std::env::var_os("CODEX_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".codex"))
    } else {
        home.join(".codex")
    };

    let mut files = Vec::new();
    collect_jsonl_files(&codex_home.join("sessions"), &mut files);
    collect_jsonl_files(&codex_home.join("archived_sessions"), &mut files);
    if let Some(since) = options
        .since
        .as_deref()
        .and_then(|value| NaiveDate::parse_from_str(value, "%Y-%m-%d").ok())
    {
        files.retain(|path| file_may_overlap_since(path, &codex_home, since));
    }
    files.sort();
    files.dedup();
    Ok(files)
}

fn file_may_overlap_since(path: &Path, codex_home: &Path, since: NaiveDate) -> bool {
    let Some(start_date) = session_start_date_hint(path, codex_home) else {
        return true;
    };
    let Some(modified_date) = path
        .metadata()
        .and_then(|metadata| metadata.modified())
        .ok()
        .map(chrono::DateTime::<chrono::Local>::from)
        .map(|timestamp| timestamp.date_naive())
    else {
        return true;
    };

    // A session can remain active across date boundaries, and archived files
    // can be moved long after their filename date. Skip it only when both its
    // creation hint and its last filesystem update are outside the window.
    date_hints_may_overlap_since(start_date, modified_date, since)
}

fn date_hints_may_overlap_since(
    start_date: NaiveDate,
    modified_date: NaiveDate,
    since: NaiveDate,
) -> bool {
    start_date >= since || modified_date >= since
}

fn session_start_date_hint(path: &Path, codex_home: &Path) -> Option<NaiveDate> {
    if let Ok(relative) = path.strip_prefix(codex_home.join("sessions")) {
        let mut components = relative.components();
        let year = components.next()?.as_os_str().to_str()?;
        let month = components.next()?.as_os_str().to_str()?;
        let day = components.next()?.as_os_str().to_str()?;
        if let Ok(date) = NaiveDate::parse_from_str(&format!("{year}-{month}-{day}"), "%Y-%m-%d") {
            return Some(date);
        }
    }

    date_from_filename(path.file_name()?.to_str()?)
}

fn date_from_filename(filename: &str) -> Option<NaiveDate> {
    let bytes = filename.as_bytes();
    if bytes.len() < 10 {
        return None;
    }
    for start in 0..=bytes.len() - 10 {
        let candidate = &bytes[start..start + 10];
        if candidate[4] != b'-'
            || candidate[7] != b'-'
            || !candidate
                .iter()
                .enumerate()
                .all(|(index, byte)| matches!(index, 4 | 7) || byte.is_ascii_digit())
        {
            continue;
        }
        if let Ok(candidate) = std::str::from_utf8(candidate) {
            if let Ok(date) = NaiveDate::parse_from_str(candidate, "%Y-%m-%d") {
                return Some(date);
            }
        }
    }
    None
}

fn collect_jsonl_files(directory: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    let mut entries = entries.filter_map(Result::ok).collect::<Vec<_>>();
    entries.sort_by_key(|entry| entry.path());
    for entry in entries {
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() && !file_type.is_symlink() {
            collect_jsonl_files(&path, files);
        } else if file_type.is_file()
            && path.extension().and_then(|extension| extension.to_str()) == Some("jsonl")
        {
            files.push(path);
        }
    }
}

#[derive(Debug, Clone)]
struct CodexSessionIdentity {
    physical_id: String,
    upstream_id: String,
    subagent_parent_id: Option<String>,
}

fn read_codex_session_identity(path: &Path) -> Option<CodexSessionIdentity> {
    let reader = BufReader::new(fs::File::open(path).ok()?);
    for line in reader.lines().map_while(Result::ok).take(64) {
        let Ok(entry) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if entry.get("type").and_then(Value::as_str) != Some("session_meta") {
            continue;
        }
        let payload = entry.get("payload")?;
        let upstream_id = payload
            .get("id")?
            .as_str()
            .filter(|id| !id.is_empty())?
            .to_string();
        let structured_parent = payload
            .get("source")
            .and_then(|source| source.get("subagent"))
            .and_then(|subagent| subagent.get("thread_spawn"))
            .and_then(|spawn| spawn.get("parent_thread_id"))
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty());
        let legacy_parent = (payload.get("thread_source").and_then(Value::as_str)
            == Some("subagent"))
        .then(|| payload.get("forked_from_id").and_then(Value::as_str))
        .flatten()
        .filter(|id| !id.is_empty());
        return Some(CodexSessionIdentity {
            physical_id: path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .unwrap_or("unknown")
                .to_string(),
            upstream_id,
            subagent_parent_id: structured_parent.or(legacy_parent).map(str::to_string),
        });
    }
    None
}

/// Resolve explicit Codex subagent lineage after replay filtering and global
/// deduplication. Adapted from tokscale-core's MIT-licensed implementation.
fn assign_subagent_messages_to_root_sessions(messages: &mut [UnifiedMessage], paths: &[PathBuf]) {
    let mut identities = paths
        .iter()
        .filter_map(|path| read_codex_session_identity(path))
        .collect::<Vec<_>>();
    identities.sort_by(|left, right| left.physical_id.cmp(&right.physical_id));

    let upstream_by_physical = identities
        .iter()
        .map(|identity| (identity.physical_id.clone(), identity.upstream_id.clone()))
        .collect::<HashMap<_, _>>();
    let mut physical_by_upstream = HashMap::new();
    let mut parent_by_upstream = HashMap::new();

    for message in messages.iter() {
        if let Some(upstream_id) = upstream_by_physical.get(&message.session_id) {
            physical_by_upstream
                .entry(upstream_id.clone())
                .or_insert_with(|| message.session_id.clone());
        }
    }
    for identity in &identities {
        physical_by_upstream
            .entry(identity.upstream_id.clone())
            .or_insert_with(|| identity.physical_id.clone());
        if let Some(parent_id) = identity.subagent_parent_id.as_ref() {
            parent_by_upstream
                .entry(identity.upstream_id.clone())
                .or_insert_with(|| parent_id.clone());
        }
    }

    let mut root_by_physical = HashMap::new();
    for identity in &identities {
        let mut current = identity.upstream_id.as_str();
        let mut visited = HashSet::new();
        let mut logical_root = None;
        loop {
            if !visited.insert(current.to_string()) {
                break;
            }
            let Some(parent) = parent_by_upstream.get(current) else {
                logical_root = physical_by_upstream.get(current).cloned();
                break;
            };
            if !physical_by_upstream.contains_key(parent) {
                logical_root = Some(parent.clone());
                break;
            }
            current = parent;
        }
        if let Some(logical_root) = logical_root {
            root_by_physical.insert(identity.physical_id.clone(), logical_root);
        }
    }

    for message in messages {
        if let Some(root_session_id) = root_by_physical.get(&message.session_id) {
            message.session_id.clone_from(root_session_id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temporary_home(label: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let home = std::env::temp_dir().join(format!(
            "tokenbar-codex-{label}-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&home).unwrap();
        home
    }

    fn write_session(path: &Path, id: &str, parent: Option<&str>, input: i64) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let source = parent.map_or_else(
            || Value::String("vscode".to_string()),
            |parent| {
                serde_json::json!({
                    "subagent": {"thread_spawn": {"parent_thread_id": parent, "depth": 1}}
                })
            },
        );
        let content = format!(
            "{}\n{}\n{}\n",
            serde_json::json!({"type":"session_meta","payload":{"id":id,"source":source}}),
            serde_json::json!({"timestamp":"2026-07-01T00:00:00Z","type":"turn_context","payload":{"model":"gpt-5.4-mini"}}),
            serde_json::json!({"timestamp":"2026-07-01T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":input,"output_tokens":2}}}})
        );
        fs::write(path, content).unwrap();
    }

    #[test]
    fn scanner_reads_sessions_and_archives_but_not_tokscale_directories() {
        let home = temporary_home("scanner");
        write_session(
            &home.join(".codex/sessions/2026/root.jsonl"),
            "root-upstream",
            None,
            10,
        );
        write_session(
            &home.join(".codex/archived_sessions/old.jsonl"),
            "old-upstream",
            None,
            20,
        );
        write_session(
            &home.join(".config/tokscale/headless/codex/ignored.jsonl"),
            "ignored",
            None,
            30,
        );
        let paths = discover_codex_files(&LocalParseOptions {
            home_dir: Some(home.to_string_lossy().into_owned()),
            use_env_roots: false,
            ..Default::default()
        })
        .unwrap();
        assert_eq!(paths.len(), 2);
        assert!(paths
            .iter()
            .all(|path| !path.to_string_lossy().contains("tokscale")));
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn date_prefilter_keeps_uncertain_and_recently_modified_sessions() {
        let home = Path::new("/tmp/home/.codex");
        let since = NaiveDate::from_ymd_opt(2026, 7, 1).unwrap();

        assert_eq!(
            session_start_date_hint(
                Path::new("/tmp/home/.codex/sessions/2026/06/01/rollout.jsonl"),
                home,
            ),
            NaiveDate::from_ymd_opt(2026, 6, 1)
        );
        assert_eq!(
            session_start_date_hint(
                Path::new("/tmp/home/.codex/archived_sessions/rollout-2026-06-02T01-02-03.jsonl"),
                home,
            ),
            NaiveDate::from_ymd_opt(2026, 6, 2)
        );
        assert!(session_start_date_hint(
            Path::new("/tmp/home/.codex/archived_sessions/imported-session.jsonl"),
            home,
        )
        .is_none());

        let old = NaiveDate::from_ymd_opt(2026, 6, 1).unwrap();
        let recent = NaiveDate::from_ymd_opt(2026, 7, 2).unwrap();
        assert!(!date_hints_may_overlap_since(old, old, since));
        assert!(date_hints_may_overlap_since(old, recent, since));
        assert!(date_hints_may_overlap_since(recent, old, since));
    }

    #[test]
    fn subagent_and_grandchild_resolve_to_root() {
        let home = temporary_home("lineage");
        let directory = home.join(".codex/sessions");
        write_session(&directory.join("root.jsonl"), "root-id", None, 10);
        write_session(
            &directory.join("child.jsonl"),
            "child-id",
            Some("root-id"),
            20,
        );
        write_session(
            &directory.join("grandchild.jsonl"),
            "grandchild-id",
            Some("child-id"),
            30,
        );
        let messages = parse_local_codex_messages(
            LocalParseOptions {
                home_dir: Some(home.to_string_lossy().into_owned()),
                use_env_roots: false,
                ..Default::default()
            },
            &CodexPricing::bundled(),
        )
        .unwrap();
        assert_eq!(messages.len(), 3);
        assert!(messages.iter().all(|message| message.session_id == "root"));
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn live_and_archived_copies_are_globally_deduplicated() {
        let home = temporary_home("archive-dedup");
        write_session(
            &home.join(".codex/sessions/2026/07/01/live.jsonl"),
            "same-upstream",
            None,
            10,
        );
        write_session(
            &home.join(".codex/archived_sessions/rollout-2026-07-01-copy.jsonl"),
            "same-upstream",
            None,
            10,
        );
        let messages = parse_local_codex_messages(
            LocalParseOptions {
                home_dir: Some(home.to_string_lossy().into_owned()),
                use_env_roots: false,
                ..Default::default()
            },
            &CodexPricing::bundled(),
        )
        .unwrap();
        assert_eq!(messages.len(), 1);
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn user_fork_remains_an_independent_session() {
        let home = temporary_home("user-fork");
        let directory = home.join(".codex/sessions");
        write_session(&directory.join("root.jsonl"), "root-id", None, 10);
        let user_fork = directory.join("user-fork.jsonl");
        fs::write(
            &user_fork,
            concat!(
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"fork-id\",\"forked_from_id\":\"root-id\",\"thread_source\":\"user\",\"source\":\"vscode\"}}\n",
                "{\"timestamp\":\"2026-07-01T00:00:00Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.4-mini\"}}\n",
                "{\"timestamp\":\"2026-07-01T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":20,\"output_tokens\":2}}}}\n"
            ),
        )
        .unwrap();
        let messages = parse_local_codex_messages(
            LocalParseOptions {
                home_dir: Some(home.to_string_lossy().into_owned()),
                use_env_roots: false,
                ..Default::default()
            },
            &CodexPricing::bundled(),
        )
        .unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(
            messages
                .iter()
                .map(|message| message.session_id.as_str())
                .collect::<HashSet<_>>(),
            HashSet::from(["root", "user-fork"])
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn unknown_model_keeps_unknown_cost_source() {
        let home = temporary_home("unknown-price");
        let source = home.join(".codex/sessions/source.jsonl");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(
            &source,
            concat!(
                "{\"type\":\"turn_context\",\"payload\":{\"model\":\"fictional-codex-model\"}}\n",
                "{\"timestamp\":\"2026-07-01T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":10,\"output_tokens\":2}}}}\n"
            ),
        )
        .unwrap();
        let messages = parse_local_codex_messages(
            LocalParseOptions {
                home_dir: Some(home.to_string_lossy().into_owned()),
                use_env_roots: false,
                ..Default::default()
            },
            &CodexPricing::bundled(),
        )
        .unwrap();
        assert_eq!(messages[0].cost, 0.0);
        assert_eq!(messages[0].cost_source, CostSource::Unknown);
        fs::remove_dir_all(home).unwrap();
    }
}
