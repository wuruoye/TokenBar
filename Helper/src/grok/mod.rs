//! Grok Build session parsing.
//!
//! `updates.jsonl` is Grok Build's durable session-update stream. Token usage
//! is attached to `turn_completed` records, while prompts and responses arrive
//! as adjacent ACP chunks. Keep all compatibility handling inside this adapter
//! so the rest of TokenBar only sees disjoint token buckets.

use std::collections::HashSet;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use chrono::NaiveDate;
use rayon::prelude::*;
use serde_json::Value;

use crate::usage::{
    content_preview_from_str, normalize_workspace_key, workspace_label_from_key, CostSource,
    TokenBreakdown, UnifiedMessage,
};
use crate::{RequestDetail, SessionTitleMap};

const USD_TICKS_PER_USD: f64 = 10_000_000_000.0;

#[derive(Debug, Clone, Default)]
pub struct LocalParseOptions {
    pub home_dir: Option<String>,
    pub use_env_roots: bool,
    pub since: Option<String>,
    pub until: Option<String>,
}

#[derive(Debug, Clone)]
struct SessionMetadata {
    physical_session_id: String,
    logical_session_id: String,
    is_subagent: bool,
    agent: Option<String>,
    workspace_key: Option<String>,
    workspace_label: Option<String>,
    fallback_model: String,
}

#[derive(Debug, Default)]
struct PendingTurn {
    prompt_parts: Vec<String>,
    output_parts: Vec<String>,
    model_hint: Option<String>,
    started_at_ms: Option<i64>,
}

pub fn parse_local_grok_messages(
    options: LocalParseOptions,
) -> Result<Vec<UnifiedMessage>, String> {
    let paths = discover_grok_files(&options)?;
    let parsed = paths
        .par_iter()
        .map(|path| parse_grok_file(path))
        .collect::<Vec<_>>();

    let mut messages = Vec::new();
    let mut dedup_keys = HashSet::new();
    for (path, file_messages) in paths.iter().zip(parsed) {
        let path_text = path.to_string_lossy().into_owned();
        for mut message in file_messages {
            message.session_path = Some(path_text.clone());
            if message
                .dedup_key
                .as_ref()
                .is_some_and(|key| !dedup_keys.insert(key.clone()))
            {
                continue;
            }
            messages.push(message);
        }
    }

    if let Some(since) = options.since.as_deref() {
        messages.retain(|message| message.date.as_str() >= since);
    }
    if let Some(until) = options.until.as_deref() {
        messages.retain(|message| message.date.as_str() <= until);
    }
    Ok(messages)
}

pub fn load_grok_session_titles(messages: &[UnifiedMessage]) -> SessionTitleMap {
    let mut seen_paths = HashSet::new();
    let mut titles = SessionTitleMap::new();
    for message in messages {
        if message.client != "grok"
            || message.is_subagent
            || message.physical_session_id.as_deref() != Some(message.session_id.as_str())
        {
            continue;
        }
        let Some(path) = message.session_path.as_deref() else {
            continue;
        };
        if !seen_paths.insert(path) {
            continue;
        }
        let summary_path = Path::new(path).with_file_name("summary.json");
        let Some(title) = read_summary(&summary_path).and_then(|summary| {
            nonempty_string(summary.get("generated_title"))
                .or_else(|| nonempty_string(summary.get("session_summary")))
        }) else {
            continue;
        };
        titles.insert(("grok".to_string(), message.session_id.clone()), title);
    }
    titles
}

pub fn extract_request_detail(
    session_path: &Path,
    start_ms: i64,
    end_ms: i64,
) -> Result<RequestDetail, String> {
    if start_ms > end_ms {
        return Err("request start must not be after request end".to_string());
    }
    let file = fs::File::open(session_path).map_err(|error| {
        format!(
            "could not open Grok session {}: {error}",
            session_path.display()
        )
    })?;
    let fallback_timestamp = file_modified_timestamp_ms(session_path);
    let mut pending = PendingTurn::default();

    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(entry) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let timestamp = entry_timestamp_ms(&entry).unwrap_or(fallback_timestamp);
        let Some(update) = session_update(&entry) else {
            continue;
        };
        match update_kind(update) {
            Some("user_message_chunk") => capture_user_chunk(&mut pending, update, timestamp),
            Some("agent_message_chunk") => capture_agent_chunk(&mut pending, update),
            Some("turn_completed") => {
                if timestamp >= start_ms && timestamp <= end_ms {
                    let prompt = joined_prompt(&pending.prompt_parts);
                    let output = joined_output(&pending.output_parts).or_else(|| {
                        nonempty_string(
                            update
                                .get("agent_result")
                                .or_else(|| update.get("agentResult")),
                        )
                    });
                    return Ok(RequestDetail { prompt, output });
                }
                pending = PendingTurn::default();
            }
            _ => {}
        }
    }

    Ok(RequestDetail::default())
}

fn discover_grok_files(options: &LocalParseOptions) -> Result<Vec<PathBuf>, String> {
    let home = options
        .home_dir
        .as_deref()
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
        .ok_or("could not resolve the home directory")?;
    let grok_home = if options.home_dir.is_none() && options.use_env_roots {
        std::env::var_os("GROK_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".grok"))
    } else {
        home.join(".grok")
    };

    let mut files = Vec::new();
    collect_update_files(&grok_home.join("sessions"), &mut files);
    if let Some(since) = options
        .since
        .as_deref()
        .and_then(|value| NaiveDate::parse_from_str(value, "%Y-%m-%d").ok())
    {
        files.retain(|path| {
            path.metadata()
                .and_then(|metadata| metadata.modified())
                .ok()
                .map(chrono::DateTime::<chrono::Local>::from)
                .map(|timestamp| timestamp.date_naive() >= since)
                .unwrap_or(true)
        });
    }
    files.sort();
    files.dedup();
    Ok(files)
}

fn collect_update_files(directory: &Path, files: &mut Vec<PathBuf>) {
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
            collect_update_files(&path, files);
        } else if file_type.is_file()
            && path.file_name().and_then(|name| name.to_str()) == Some("updates.jsonl")
            && path.with_file_name("summary.json").is_file()
        {
            files.push(path);
        }
    }
}

fn parse_grok_file(path: &Path) -> Vec<UnifiedMessage> {
    let Some(summary) = read_summary(&path.with_file_name("summary.json")) else {
        return Vec::new();
    };
    let metadata = session_metadata(path, &summary);
    let Ok(file) = fs::File::open(path) else {
        return Vec::new();
    };
    let fallback_timestamp = file_modified_timestamp_ms(path);
    let mut pending = PendingTurn::default();
    let mut messages = Vec::new();

    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(entry) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let timestamp = entry_timestamp_ms(&entry).unwrap_or(fallback_timestamp);
        let Some(update) = session_update(&entry) else {
            continue;
        };
        match update_kind(update) {
            Some("user_message_chunk") => capture_user_chunk(&mut pending, update, timestamp),
            Some("agent_message_chunk") => capture_agent_chunk(&mut pending, update),
            Some("turn_completed") => {
                append_completed_turn(&mut messages, &metadata, &pending, update, timestamp);
                pending = PendingTurn::default();
            }
            _ => {}
        }
    }
    messages
}

fn append_completed_turn(
    messages: &mut Vec<UnifiedMessage>,
    metadata: &SessionMetadata,
    pending: &PendingTurn,
    update: &Value,
    timestamp: i64,
) {
    let Some(usage) = update.get("usage") else {
        return;
    };
    let usage_incomplete = boolean(usage, "usageIsIncomplete", "usage_is_incomplete");
    let prompt_id = string_field(update, "prompt_id", "promptId").unwrap_or("unknown");
    let prompt_preview = joined_prompt(&pending.prompt_parts)
        .and_then(|value| content_preview_from_str(&value));
    let output_preview = joined_output(&pending.output_parts)
        .or_else(|| nonempty_string(update.get("agent_result").or_else(|| update.get("agentResult"))))
        .and_then(|value| content_preview_from_str(&value));
    let duration_ms = pending
        .started_at_ms
        .map(|started_at| timestamp.saturating_sub(started_at))
        .filter(|duration| *duration > 0);

    let model_rows = usage
        .get("modelUsage")
        .or_else(|| usage.get("model_usage"))
        .and_then(Value::as_object)
        .filter(|rows| !rows.is_empty())
        .map(|rows| {
            rows.iter()
                .map(|(model, value)| (model.as_str(), value))
                .collect::<Vec<_>>()
        })
        .unwrap_or_else(|| {
            vec![(
                pending
                    .model_hint
                    .as_deref()
                    .unwrap_or(metadata.fallback_model.as_str()),
                usage,
            )]
        });

    let mut emitted = 0usize;
    for (model, row) in model_rows {
        let tokens = disjoint_tokens(row);
        if tokens.total() == 0 {
            continue;
        }
        let cost_is_partial = boolean(row, "costIsPartial", "cost_is_partial")
            || boolean(usage, "costIsPartial", "cost_is_partial");
        let cost_ticks = integer_field(row, "costUsdTicks", "cost_usd_ticks");
        let trusted_cost = !usage_incomplete
            && !cost_is_partial
            && cost_ticks.is_some_and(|ticks| ticks >= 0);
        let cost = if trusted_cost {
            cost_ticks.unwrap_or_default().max(0) as f64 / USD_TICKS_PER_USD
        } else {
            0.0
        };
        let mut message = UnifiedMessage::new_with_agent(
            "grok",
            canonical_model(model),
            "xai",
            metadata.logical_session_id.clone(),
            timestamp,
            tokens,
            cost,
            metadata.agent.clone(),
        );
        message.physical_session_id = Some(metadata.physical_session_id.clone());
        message.is_subagent = metadata.is_subagent;
        message.cost_source = if trusted_cost {
            CostSource::ProviderReported
        } else {
            CostSource::Unknown
        };
        message.model_duration_ms = integer_field(row, "apiDurationMs", "api_duration_ms")
            .filter(|duration| *duration > 0);
        message.duration_ms = (emitted == 0).then_some(duration_ms).flatten();
        message.is_turn_start = emitted == 0;
        if emitted == 0 {
            message.set_content_preview(prompt_preview.clone());
            message.set_output_preview(output_preview.clone());
        }
        message.set_workspace(
            metadata.workspace_key.clone(),
            metadata.workspace_label.clone(),
        );
        message.dedup_key = Some(format!(
            "grok:{}:{prompt_id}:{}",
            metadata.physical_session_id, message.model_id
        ));
        messages.push(message);
        emitted = emitted.saturating_add(1);
    }
}

fn session_metadata(path: &Path, summary: &Value) -> SessionMetadata {
    let fallback_id = path
        .parent()
        .and_then(Path::file_name)
        .and_then(|name| name.to_str())
        .unwrap_or("unknown")
        .to_string();
    let physical_session_id = summary
        .pointer("/info/id")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(&fallback_id)
        .to_string();
    let session_kind = summary.get("session_kind").and_then(Value::as_str);
    let is_subagent = session_kind.is_some_and(|kind| kind.starts_with("subagent"));
    let logical_session_id = if is_subagent {
        summary
            .get("parent_session_id")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .unwrap_or(&physical_session_id)
            .to_string()
    } else {
        physical_session_id.clone()
    };
    let workspace_key = summary
        .pointer("/info/cwd")
        .and_then(Value::as_str)
        .and_then(normalize_workspace_key);
    let workspace_label = workspace_key
        .as_deref()
        .and_then(workspace_label_from_key);
    let fallback_model = nonempty_string(summary.get("current_model_id"))
        .unwrap_or_else(|| "grok".to_string());
    let agent = is_subagent
        .then(|| nonempty_string(summary.get("agent_name")))
        .flatten()
        .or_else(|| is_subagent.then(|| "grok-subagent".to_string()));
    SessionMetadata {
        physical_session_id,
        logical_session_id,
        is_subagent,
        agent,
        workspace_key,
        workspace_label,
        fallback_model,
    }
}

fn capture_user_chunk(pending: &mut PendingTurn, update: &Value, timestamp: i64) {
    pending.started_at_ms.get_or_insert(timestamp);
    if pending.model_hint.is_none() {
        pending.model_hint = update
            .get("_meta")
            .and_then(|meta| meta.get("modelId").or_else(|| meta.get("model_id")))
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_string);
    }
    let hidden = update
        .get("_meta")
        .and_then(|meta| meta.get("hideFromScrollback"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if hidden {
        return;
    }
    if let Some(text) = content_text(update.get("content")) {
        pending.prompt_parts.push(text);
    }
}

fn capture_agent_chunk(pending: &mut PendingTurn, update: &Value) {
    if let Some(text) = content_text(update.get("content")) {
        pending.output_parts.push(text);
    }
}

fn disjoint_tokens(value: &Value) -> TokenBreakdown {
    let full_input = integer_field(value, "inputTokens", "input_tokens")
        .unwrap_or_default()
        .max(0);
    let cache_read = integer_field(value, "cachedReadTokens", "cached_read_tokens")
        .unwrap_or_default()
        .max(0);
    let cache_write = integer_field(value, "cacheCreationTokens", "cache_creation_tokens")
        .unwrap_or_default()
        .max(0);
    let full_output = integer_field(value, "outputTokens", "output_tokens")
        .unwrap_or_default()
        .max(0);
    let reasoning = integer_field(value, "reasoningTokens", "reasoning_tokens")
        .unwrap_or_default()
        .max(0);
    TokenBreakdown {
        input: full_input
            .saturating_sub(cache_read)
            .saturating_sub(cache_write),
        output: full_output.saturating_sub(reasoning),
        cache_read,
        cache_write,
        reasoning,
    }
}

fn session_update(entry: &Value) -> Option<&Value> {
    entry
        .pointer("/params/update")
        .or_else(|| entry.get("update"))
        .or_else(|| entry.get("sessionUpdate").is_some().then_some(entry))
}

fn update_kind(update: &Value) -> Option<&str> {
    update
        .get("sessionUpdate")
        .or_else(|| update.get("session_update"))
        .and_then(Value::as_str)
}

fn entry_timestamp_ms(entry: &Value) -> Option<i64> {
    let value = entry.get("timestamp")?;
    if let Some(number) = value.as_i64() {
        return Some(if number < 10_000_000_000 {
            number.saturating_mul(1000)
        } else {
            number
        });
    }
    if let Some(number) = value.as_f64() {
        let milliseconds = if number < 10_000_000_000.0 {
            number * 1000.0
        } else {
            number
        };
        if milliseconds.is_finite()
            && milliseconds >= i64::MIN as f64
            && milliseconds <= i64::MAX as f64
        {
            return Some(milliseconds.round() as i64);
        }
    }
    chrono::DateTime::parse_from_rfc3339(value.as_str()?)
        .ok()
        .map(|timestamp| timestamp.timestamp_millis())
}

fn content_text(content: Option<&Value>) -> Option<String> {
    let content = content?;
    if let Some(text) = content.as_str() {
        return (!text.trim().is_empty()).then(|| text.to_string());
    }
    let content_type = content.get("type").and_then(Value::as_str);
    if content_type.is_some_and(|kind| kind != "text" && kind != "output_text") {
        return None;
    }
    content
        .get("text")
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty())
        .map(str::to_string)
}

fn joined_prompt(parts: &[String]) -> Option<String> {
    (!parts.is_empty()).then(|| parts.join("\n"))
}

fn joined_output(parts: &[String]) -> Option<String> {
    (!parts.is_empty()).then(|| parts.concat())
}

fn read_summary(path: &Path) -> Option<Value> {
    serde_json::from_reader(fs::File::open(path).ok()?).ok()
}

fn nonempty_string(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn string_field<'a>(value: &'a Value, camel: &str, snake: &str) -> Option<&'a str> {
    value
        .get(camel)
        .or_else(|| value.get(snake))
        .and_then(Value::as_str)
}

fn boolean(value: &Value, camel: &str, snake: &str) -> bool {
    value
        .get(camel)
        .or_else(|| value.get(snake))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn integer_field(value: &Value, camel: &str, snake: &str) -> Option<i64> {
    value
        .get(camel)
        .or_else(|| value.get(snake))
        .and_then(|number| {
            number
                .as_i64()
                .or_else(|| number.as_u64().map(|value| value.min(i64::MAX as u64) as i64))
        })
}

fn canonical_model(model: &str) -> String {
    let model = model.trim().to_ascii_lowercase();
    (!model.is_empty()).then_some(model).unwrap_or_else(|| "grok".to_string())
}

fn file_modified_timestamp_ms(path: &Path) -> i64 {
    path.metadata()
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .and_then(|duration| i64::try_from(duration.as_millis()).ok())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn temporary_directory(name: &str) -> PathBuf {
        static NEXT_ID: AtomicU64 = AtomicU64::new(0);
        std::env::temp_dir().join(format!(
            "tokenbar-grok-{name}-{}-{}",
            std::process::id(),
            NEXT_ID.fetch_add(1, Ordering::Relaxed)
        ))
    }

    fn write_fixture(directory: &Path, partial: bool) -> PathBuf {
        fs::create_dir_all(directory).unwrap();
        fs::write(
            directory.join("summary.json"),
            r#"{
                "info":{"id":"session-1","cwd":"/tmp/TokenBar"},
                "session_summary":"Fallback title",
                "generated_title":"Add Grok support",
                "current_model_id":"grok-4.5"
            }"#,
        )
        .unwrap();
        let path = directory.join("updates.jsonl");
        let mut file = fs::File::create(&path).unwrap();
        writeln!(file, "{}", serde_json::json!({
            "timestamp": 1_785_856_800_i64,
            "params": {"update": {
                "sessionUpdate": "user_message_chunk",
                "content": {"type": "text", "text": "Implement it"},
                "_meta": {"modelId": "grok-4.5-build", "promptIndex": 0}
            }}
        }))
        .unwrap();
        writeln!(file, "{}", serde_json::json!({
            "timestamp": 1_785_856_801_i64,
            "params": {"update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "Done"}
            }}
        }))
        .unwrap();
        writeln!(file, "{}", serde_json::json!({
            "timestamp": 1_785_856_802_i64,
            "params": {"update": {
                "sessionUpdate": "turn_completed",
                "prompt_id": "prompt-1",
                "usage": {
                    "inputTokens": 180,
                    "outputTokens": 50,
                    "cachedReadTokens": 100,
                    "cacheCreationTokens": 20,
                    "reasoningTokens": 10,
                    "costUsdTicks": 250_000_000,
                    "costIsPartial": partial,
                    "modelUsage": {"grok-4.5-build": {
                        "inputTokens": 180,
                        "outputTokens": 50,
                        "cachedReadTokens": 100,
                        "cacheCreationTokens": 20,
                        "reasoningTokens": 10,
                        "apiDurationMs": 1_200,
                        "costUsdTicks": 250_000_000,
                        "costIsPartial": partial
                    }}
                }
            }}
        }))
        .unwrap();
        path
    }

    #[test]
    fn parses_turn_usage_as_disjoint_buckets_and_provider_cost() {
        let directory = temporary_directory("usage");
        let path = write_fixture(&directory, false);
        let messages = parse_grok_file(&path);
        let _ = fs::remove_dir_all(&directory);

        assert_eq!(messages.len(), 1);
        let message = &messages[0];
        assert_eq!(message.client, "grok");
        assert_eq!(message.model_id, "grok-4.5-build");
        assert_eq!(message.tokens.input, 60);
        assert_eq!(message.tokens.cache_read, 100);
        assert_eq!(message.tokens.cache_write, 20);
        assert_eq!(message.tokens.output, 40);
        assert_eq!(message.tokens.reasoning, 10);
        assert_eq!(message.cost, 0.025);
        assert_eq!(message.cost_source, CostSource::ProviderReported);
        assert_eq!(message.duration_ms, Some(2_000));
        assert_eq!(message.model_duration_ms, Some(1_200));
        assert_eq!(message.content_preview.as_deref(), Some("Implement it"));
        assert_eq!(message.output_preview.as_deref(), Some("Done"));
        assert_eq!(message.workspace_key.as_deref(), Some("/tmp/TokenBar"));
        assert!(message.is_turn_start);
    }

    #[test]
    fn refuses_to_present_partial_cost_as_complete() {
        let directory = temporary_directory("partial");
        let path = write_fixture(&directory, true);
        let messages = parse_grok_file(&path);
        let _ = fs::remove_dir_all(&directory);

        assert_eq!(messages[0].cost, 0.0);
        assert_eq!(messages[0].cost_source, CostSource::Unknown);
    }

    #[test]
    fn loads_titles_and_request_details_from_the_durable_session() {
        let directory = temporary_directory("detail");
        let path = write_fixture(&directory, false);
        let mut messages = parse_grok_file(&path);
        messages[0].session_path = Some(path.to_string_lossy().into_owned());

        let titles = load_grok_session_titles(&messages);
        let detail = extract_request_detail(&path, 1_785_856_800_000, 1_785_856_802_000)
            .unwrap();
        let _ = fs::remove_dir_all(&directory);

        assert_eq!(
            titles.get(&("grok".to_string(), "session-1".to_string())),
            Some(&"Add Grok support".to_string())
        );
        assert_eq!(detail.prompt.as_deref(), Some("Implement it"));
        assert_eq!(detail.output.as_deref(), Some("Done"));
    }
}
