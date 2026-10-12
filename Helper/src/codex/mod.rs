mod messages;
mod parser;

pub(crate) use messages::{human_message_text, message_content_text};

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use chrono::NaiveDate;
use rayon::prelude::*;
use serde_json::Value;

use crate::pricing::CodexPricing;
use crate::usage::{CostSource, ServiceTier, UnifiedMessage};

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
    let mut service_tier_snapshots_by_physical = HashMap::new();
    for (path, parsed_file) in paths.iter().zip(parsed_files) {
        let path_text = path.to_string_lossy().into_owned();
        let Some(parsed_file) = parsed_file else {
            continue;
        };
        if let Some(physical_id) = path.file_stem().and_then(|stem| stem.to_str()) {
            service_tier_snapshots_by_physical.insert(
                physical_id.to_string(),
                parsed_file.service_tier_snapshots,
            );
        }
        for mut message in parsed_file.messages {
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

    assign_subagent_messages_to_root_sessions(
        &mut messages,
        &paths,
        &service_tier_snapshots_by_physical,
    );
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
    message.token_costs = None;
    message.cost_source = CostSource::Unknown;
    if let Some(token_costs) = pricing.calculate_token_costs_with_service_tier(
        &message.model_id,
        Some(&message.provider_id),
        &message.tokens,
        message.service_tier,
    ) {
        message.cost = token_costs.total();
        message.token_costs = Some(token_costs);
        message.cost_source = CostSource::Estimated;
    }
}

fn discover_codex_files(options: &LocalParseOptions) -> Result<Vec<PathBuf>, String> {
    let home = options
        .home_dir
        .as_deref()
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
        .or_else(|| std::env::var_os("USERPROFILE").map(PathBuf::from))
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
    started_at_ms: Option<i64>,
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
        let started_at_ms = entry
            .get("timestamp")
            .or_else(|| payload.get("timestamp"))
            .and_then(codex_timestamp_ms);
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
            started_at_ms,
        });
    }
    None
}

fn codex_timestamp_ms(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| {
        value
            .as_str()
            .and_then(|timestamp| chrono::DateTime::parse_from_rfc3339(timestamp).ok())
            .map(|timestamp| timestamp.timestamp_millis())
    })
}

/// Resolve explicit Codex subagent lineage after replay filtering and global
/// deduplication. Adapted from tokscale-core's MIT-licensed implementation.
fn assign_subagent_messages_to_root_sessions(
    messages: &mut [UnifiedMessage],
    paths: &[PathBuf],
    service_tier_snapshots_by_physical: &HashMap<
        String,
        Vec<parser::ServiceTierSnapshot>,
    >,
) {
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

    inherit_standalone_subagent_service_tiers(
        messages,
        &identities,
        &physical_by_upstream,
        &parent_by_upstream,
        service_tier_snapshots_by_physical,
    );

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
        if let Some(upstream_id) = upstream_by_physical.get(&message.session_id) {
            message.is_subagent = parent_by_upstream.contains_key(upstream_id);
        }
        if let Some(root_session_id) = root_by_physical.get(&message.session_id) {
            message.session_id.clone_from(root_session_id);
        }
    }
}

/// Newer standalone subagent logs carry parent lineage but may omit their own
/// thread-settings event. Fill only all-unknown children from the parent's
/// exact tier at spawn time; an explicit child tier always remains authoritative.
fn inherit_standalone_subagent_service_tiers(
    messages: &mut [UnifiedMessage],
    identities: &[CodexSessionIdentity],
    physical_by_upstream: &HashMap<String, String>,
    parent_by_upstream: &HashMap<String, String>,
    service_tier_snapshots_by_physical: &HashMap<
        String,
        Vec<parser::ServiceTierSnapshot>,
    >,
) {
    let mut ordered_subagents = identities
        .iter()
        .filter(|identity| identity.subagent_parent_id.is_some())
        .map(|identity| {
            (
                lineage_depth(&identity.upstream_id, parent_by_upstream),
                identity,
            )
        })
        .collect::<Vec<_>>();
    ordered_subagents.sort_by(|(left_depth, left), (right_depth, right)| {
        left_depth
            .cmp(right_depth)
            .then_with(|| {
                left.started_at_ms
                    .unwrap_or(i64::MAX)
                    .cmp(&right.started_at_ms.unwrap_or(i64::MAX))
            })
            .then_with(|| left.physical_id.cmp(&right.physical_id))
    });

    for (_, identity) in ordered_subagents {
        let child_has_messages = messages
            .iter()
            .any(|message| message.session_id == identity.physical_id);
        let child_has_explicit_tier = messages.iter().any(|message| {
            message.session_id == identity.physical_id
                && message.service_tier != ServiceTier::Unknown
        });
        if !child_has_messages || child_has_explicit_tier {
            continue;
        }

        let Some(parent_upstream_id) = identity.subagent_parent_id.as_ref() else {
            continue;
        };
        let Some(parent_physical_id) = physical_by_upstream.get(parent_upstream_id) else {
            continue;
        };
        let child_started_at_ms = identity.started_at_ms.or_else(|| {
            earliest_session_message_start(messages, &identity.physical_id)
        });
        let Some(child_started_at_ms) = child_started_at_ms else {
            continue;
        };
        let Some(inherited_tier) = service_tier_at(
            messages,
            parent_physical_id,
            child_started_at_ms,
            service_tier_snapshots_by_physical
                .get(parent_physical_id)
                .map(Vec::as_slice)
                .unwrap_or_default(),
        ) else {
            continue;
        };

        for message in messages.iter_mut().filter(|message| {
            message.session_id == identity.physical_id
                && message.service_tier == ServiceTier::Unknown
        }) {
            message.service_tier = inherited_tier;
        }
    }
}

fn lineage_depth(
    upstream_id: &str,
    parent_by_upstream: &HashMap<String, String>,
) -> usize {
    let mut current = upstream_id;
    let mut visited = HashSet::new();
    let mut depth = 0_usize;
    while visited.insert(current.to_string()) {
        let Some(parent) = parent_by_upstream.get(current) else {
            break;
        };
        depth = depth.saturating_add(1);
        current = parent;
    }
    depth
}

fn earliest_session_message_start(
    messages: &[UnifiedMessage],
    physical_id: &str,
) -> Option<i64> {
    messages
        .iter()
        .filter(|message| message.session_id == physical_id)
        .map(|message| {
            message
                .duration_ms
                .filter(|duration| *duration > 0)
                .map_or(message.timestamp, |duration| {
                    message.timestamp.saturating_sub(duration)
                })
        })
        .min()
}

fn service_tier_at(
    messages: &[UnifiedMessage],
    physical_id: &str,
    timestamp_ms: i64,
    snapshots: &[parser::ServiceTierSnapshot],
) -> Option<ServiceTier> {
    if !snapshots.is_empty() {
        if let Some(snapshot) = snapshots
            .iter()
            .filter(|snapshot| snapshot.timestamp_ms <= timestamp_ms)
            .max_by_key(|snapshot| snapshot.timestamp_ms)
        {
            return (snapshot.tier != ServiceTier::Unknown).then_some(snapshot.tier);
        }
        let first_tier = snapshots[0].tier;
        return (first_tier != ServiceTier::Unknown
            && snapshots
                .iter()
                .all(|snapshot| snapshot.tier == first_tier))
        .then_some(first_tier);
    }

    if let Some(message) = messages
        .iter()
        .filter(|message| {
            message.session_id == physical_id && message.timestamp <= timestamp_ms
        })
        .max_by_key(|message| message.timestamp)
    {
        return (message.service_tier != ServiceTier::Unknown)
            .then_some(message.service_tier);
    }

    let mut tiers = messages
        .iter()
        .filter(|message| message.session_id == physical_id)
        .map(|message| message.service_tier);
    let first_tier = tiers.next()?;
    (first_tier != ServiceTier::Unknown && tiers.all(|tier| tier == first_tier))
        .then_some(first_tier)
}
