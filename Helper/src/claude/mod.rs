//! Claude Code JSONL parsing adapted from tokscale-core's MIT-licensed parser.
//!
//! Claude Code's transcript schema is not a stable public contract, so this
//! module deliberately keeps all compatibility handling behind one adapter.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use chrono::NaiveDate;
use rayon::prelude::*;
use serde_json::Value;

use crate::pricing::AnthropicPricing;
use crate::usage::{
    content_preview_from_str, normalize_workspace_key, workspace_label_from_key,
    CacheWriteBreakdown, CostSource, TokenBreakdown, UnifiedMessage,
};
use crate::RequestDetail;

const INTERNAL_USER_PREFIXES: [&str; 8] = [
    "<local-command-stdout>",
    "<local-command-stderr>",
    "<command-name>",
    "<command-message>",
    "<system-reminder>",
    "<bash-input>",
    "<bash-stdout>",
    "<bash-stderr>",
];

#[derive(Debug, Clone, Default)]
pub struct LocalParseOptions {
    pub home_dir: Option<String>,
    pub use_env_roots: bool,
    pub since: Option<String>,
    pub until: Option<String>,
}

pub fn parse_local_claude_messages(
    options: LocalParseOptions,
    pricing: &AnthropicPricing,
) -> Result<Vec<UnifiedMessage>, String> {
    let paths = discover_claude_files(&options)?;
    let parsed = paths
        .par_iter()
        .map(|path| parse_claude_file(path))
        .collect::<Vec<_>>();

    let mut messages = Vec::new();
    let mut seen_dedup_keys = HashSet::new();
    for (path, file_messages) in paths.iter().zip(parsed) {
        let path_text = path.to_string_lossy().into_owned();
        for mut message in file_messages {
            message.session_path = Some(path_text.clone());
            if message
                .dedup_key
                .as_ref()
                .is_some_and(|key| !seen_dedup_keys.insert(key.clone()))
            {
                continue;
            }
            if let Some(costs) = pricing.calculate_token_costs_with_cache_writes(
                &message.model_id,
                &message.tokens,
                message.cache_write_breakdown.as_ref(),
            ) {
                message.cost = costs.total();
                message.token_costs = Some(costs);
                message.cost_source = CostSource::Estimated;
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
            "could not open Claude Code session {}: {error}",
            session_path.display()
        )
    })?;

    let mut prompt = None;
    let mut output = Vec::new();
    let mut seen_messages = HashSet::new();
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(entry) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let Some(timestamp) = entry_timestamp_ms(&entry) else {
            continue;
        };
        if timestamp < start_ms || timestamp > end_ms {
            continue;
        }

        match entry.get("type").and_then(Value::as_str) {
            Some("user") if prompt.is_none() => {
                prompt = human_prompt(&entry);
            }
            Some("assistant") => {
                let message = entry.get("message").unwrap_or(&entry);
                let dedup = message
                    .get("id")
                    .and_then(Value::as_str)
                    .or_else(|| entry.get("uuid").and_then(Value::as_str));
                if dedup.is_some_and(|id| !seen_messages.insert(id.to_string())) {
                    continue;
                }
                if let Some(text) = message_content_text(message.get("content")) {
                    output.push(text);
                }
            }
            _ => {}
        }
    }

    Ok(RequestDetail {
        prompt,
        output: (!output.is_empty()).then(|| output.join("\n\n")),
    })
}

fn discover_claude_files(options: &LocalParseOptions) -> Result<Vec<PathBuf>, String> {
    let home = options
        .home_dir
        .as_deref()
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
        .ok_or("could not resolve the home directory")?;
    let claude_home = if options.home_dir.is_none() && options.use_env_roots {
        std::env::var_os("CLAUDE_CONFIG_DIR")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".claude"))
    } else {
        home.join(".claude")
    };

    let mut files = Vec::new();
    collect_jsonl_files(&claude_home.join("projects"), &mut files);
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
            && path.file_name().and_then(|name| name.to_str()) != Some("journal.jsonl")
        {
            files.push(path);
        }
    }
}

fn parse_claude_file(path: &Path) -> Vec<UnifiedMessage> {
    let Ok(file) = fs::File::open(path) else {
        return Vec::new();
    };
    let physical_session_id = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("unknown")
        .to_string();
    let fallback_timestamp = file_modified_timestamp_ms(path);
    let fallback_workspace = workspace_from_path(path);
    let mut logical_session_id = physical_session_id.clone();
    let mut is_subagent = false;
    let mut agent = None;
    let mut workspace = fallback_workspace;
    let mut pending_prompt = None;
    let mut pending_turn_start = false;
    let mut request_started_at = None;
    let mut last_model = None;
    let mut last_provider = None;
    let mut messages: Vec<UnifiedMessage> = Vec::new();
    let mut dedup_indices = HashMap::new();

    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(entry) = serde_json::from_str::<Value>(&line) else {
            continue;
        };

        if entry
            .get("isSidechain")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            is_subagent = true;
            if let Some(parent) = entry
                .get("sessionId")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
            {
                logical_session_id = parent.to_string();
            }
            if agent.is_none() {
                agent = resolve_agent_name(path, &entry);
            }
        }
        if let Some(cwd) = entry
            .get("cwd")
            .and_then(Value::as_str)
            .and_then(normalize_workspace_key)
        {
            workspace = (Some(cwd.clone()), workspace_label_from_key(&cwd));
        }

        let entry_type = entry.get("type").and_then(Value::as_str);
        if matches!(entry_type, Some("user" | "tool_result")) {
            request_started_at = entry_timestamp_ms(&entry).or(request_started_at);
            if entry_type == Some("user") {
                if let Some(prompt) = human_prompt(&entry) {
                    pending_prompt = Some(prompt);
                    pending_turn_start = true;
                }
            }
            continue;
        }
        if entry_type != Some("assistant") {
            continue;
        }

        let message = entry.get("message").unwrap_or(&entry);
        let Some(usage) = message.get("usage").or_else(|| entry.get("usage")) else {
            continue;
        };
        let raw_model = message
            .get("model")
            .and_then(Value::as_str)
            .or_else(|| entry.get("model").and_then(Value::as_str))
            .map(str::to_string)
            .or_else(|| last_model.clone());
        let Some(raw_model) = raw_model else {
            continue;
        };
        last_model = Some(raw_model.clone());

        let explicit_provider = provider_hint(&entry, message).or_else(|| last_provider.clone());
        if explicit_provider.is_some() {
            last_provider.clone_from(&explicit_provider);
        }
        let provider = canonical_provider(explicit_provider.as_deref(), &raw_model);
        let model = canonical_model(&raw_model);
        let timestamp = entry_timestamp_ms(&entry).unwrap_or(fallback_timestamp);
        let request_id = entry.get("requestId").and_then(Value::as_str);
        let message_id = message.get("id").and_then(Value::as_str);
        let time_to_first_token_ms = request_started_at
            .zip(message_id)
            .and_then(|(request_started_at, message_id)| {
                claude_time_to_first_token_ms(request_started_at, message_id)
            });
        let tokens = TokenBreakdown {
            input: integer(usage.get("input_tokens")).max(0),
            output: integer(usage.get("output_tokens")).max(0),
            cache_read: integer(usage.get("cache_read_input_tokens")).max(0),
            cache_write: integer(usage.get("cache_creation_input_tokens")).max(0),
            reasoning: 0,
        };
        let cache_write_breakdown = cache_write_breakdown(usage);
        if tokens.total() == 0 {
            continue;
        }

        let dedup_key = message_id.map(|message_id| {
            request_id
                .map(|request_id| format!("claude:{message_id}:{request_id}"))
                .unwrap_or_else(|| format!("claude:message:{message_id}"))
        });
        if let Some(index) = dedup_key
            .as_ref()
            .and_then(|key| dedup_indices.get(key))
            .copied()
        {
            merge_streaming_duplicate(
                &mut messages[index],
                &tokens,
                cache_write_breakdown.as_ref(),
                timestamp,
                request_started_at,
                message.get("content"),
            );
            continue;
        }

        let mut unified = UnifiedMessage::new_with_agent(
            "claude",
            model,
            provider,
            logical_session_id.clone(),
            timestamp,
            tokens,
            0.0,
            agent.clone(),
        );
        unified.physical_session_id = Some(physical_session_id.clone());
        unified.cache_write_breakdown = cache_write_breakdown;
        unified.is_subagent = is_subagent;
        unified.dedup_key.clone_from(&dedup_key);
        unified.duration_ms = request_started_at
            .map(|started_at| timestamp.saturating_sub(started_at))
            .filter(|duration| *duration > 0);
        unified.model_duration_ms = unified.duration_ms;
        unified.time_to_first_token_ms = time_to_first_token_ms;
        unified.is_turn_start = pending_turn_start;
        unified.set_content_preview(pending_prompt.take());
        unified.set_output_preview(
            message_content_text(message.get("content"))
                .and_then(|text| content_preview_from_str(&text)),
        );
        unified.set_workspace(workspace.0.clone(), workspace.1.clone());
        if let Some(key) = dedup_key {
            dedup_indices.insert(key, messages.len());
        }
        messages.push(unified);
        pending_turn_start = false;
        request_started_at = None;
    }
    messages
}

fn merge_streaming_duplicate(
    existing: &mut UnifiedMessage,
    tokens: &TokenBreakdown,
    cache_write_breakdown: Option<&CacheWriteBreakdown>,
    timestamp: i64,
    request_started_at: Option<i64>,
    content: Option<&Value>,
) {
    existing.tokens.input = existing.tokens.input.max(tokens.input);
    existing.tokens.output = existing.tokens.output.max(tokens.output);
    existing.tokens.cache_read = existing.tokens.cache_read.max(tokens.cache_read);
    existing.tokens.cache_write = existing.tokens.cache_write.max(tokens.cache_write);
    if let Some(incoming) = cache_write_breakdown {
        let existing = existing
            .cache_write_breakdown
            .get_or_insert_with(CacheWriteBreakdown::default);
        existing.five_minute = existing.five_minute.max(incoming.five_minute);
        existing.one_hour = existing.one_hour.max(incoming.one_hour);
    }
    if timestamp >= existing.timestamp {
        let start = existing
            .duration_ms
            .map(|duration| existing.timestamp.saturating_sub(duration))
            .or(request_started_at);
        existing.timestamp = timestamp;
        existing.refresh_derived_fields();
        existing.duration_ms = start
            .map(|started_at| timestamp.saturating_sub(started_at))
            .filter(|duration| *duration > 0);
        existing.model_duration_ms = existing.duration_ms;
        if let Some(preview) =
            message_content_text(content).and_then(|text| content_preview_from_str(&text))
        {
            existing.set_output_preview(Some(preview));
        }
    }
}

fn cache_write_breakdown(usage: &Value) -> Option<CacheWriteBreakdown> {
    let cache_creation = usage.get("cache_creation")?;
    let breakdown = CacheWriteBreakdown {
        five_minute: integer(cache_creation.get("ephemeral_5m_input_tokens")).max(0),
        one_hour: integer(cache_creation.get("ephemeral_1h_input_tokens")).max(0),
    };
    (breakdown.five_minute > 0 || breakdown.one_hour > 0).then_some(breakdown)
}

fn human_prompt(entry: &Value) -> Option<String> {
    let content = entry
        .get("message")
        .and_then(|message| message.get("content"))
        .or_else(|| entry.get("content"))?;
    match content {
        Value::String(text) => human_text(text).map(str::to_string),
        Value::Array(blocks) => {
            let text = blocks
                .iter()
                .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|block| block.get("text").and_then(Value::as_str))
                .filter_map(human_text)
                .collect::<Vec<_>>()
                .join("\n");
            (!text.is_empty()).then_some(text)
        }
        _ => None,
    }
}

fn human_text(text: &str) -> Option<&str> {
    let text = text.trim();
    (!text.is_empty()
        && !INTERNAL_USER_PREFIXES
            .iter()
            .any(|prefix| text.starts_with(prefix)))
    .then_some(text)
}

fn message_content_text(content: Option<&Value>) -> Option<String> {
    match content? {
        Value::String(text) => (!text.trim().is_empty()).then(|| text.to_string()),
        Value::Array(blocks) => {
            let text = blocks
                .iter()
                .filter(|block| {
                    block
                        .get("type")
                        .and_then(Value::as_str)
                        .is_none_or(|kind| matches!(kind, "text" | "output_text"))
                })
                .filter_map(|block| block.get("text").and_then(Value::as_str))
                .filter(|text| !text.trim().is_empty())
                .collect::<Vec<_>>()
                .join("\n");
            (!text.is_empty()).then_some(text)
        }
        _ => None,
    }
}

fn entry_timestamp_ms(entry: &Value) -> Option<i64> {
    let value = entry
        .get("timestamp")
        .or_else(|| entry.get("created_at"))
        .or_else(|| entry.get("message").and_then(|message| message.get("created_at")))?;
    if let Some(milliseconds) = value.as_i64() {
        return Some(if milliseconds < 10_000_000_000 {
            milliseconds.saturating_mul(1000)
        } else {
            milliseconds
        });
    }
    chrono::DateTime::parse_from_rfc3339(value.as_str()?)
        .ok()
        .map(|timestamp| timestamp.timestamp_millis())
}

fn claude_time_to_first_token_ms(request_started_at: i64, message_id: &str) -> Option<i64> {
    let message_timestamp = prefixed_uuid_v7_timestamp_ms(message_id, "msg_01")?;
    message_timestamp
        .checked_sub(request_started_at)
        .filter(|duration| *duration >= 0)
}

fn prefixed_uuid_v7_timestamp_ms(id: &str, prefix: &str) -> Option<i64> {
    const BASE58: &[u8; 58] =
        b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

    let encoded = id.strip_prefix(prefix)?;
    if encoded.len() != 22 {
        return None;
    }
    let value = encoded.bytes().try_fold(0_u128, |value, byte| {
        let digit = BASE58.iter().position(|candidate| *candidate == byte)? as u128;
        value.checked_mul(58)?.checked_add(digit)
    })?;
    let version = (value >> 76) & 0x0f;
    let variant = (value >> 62) & 0x03;
    if version != 7 || variant != 2 {
        return None;
    }
    i64::try_from(value >> 80).ok()
}

fn integer(value: Option<&Value>) -> i64 {
    value
        .and_then(|value| {
            value
                .as_i64()
                .or_else(|| value.as_u64().and_then(|number| i64::try_from(number).ok()))
        })
        .unwrap_or(0)
}

fn provider_hint(entry: &Value, message: &Value) -> Option<String> {
    ["providerId", "provider_id", "provider"]
        .into_iter()
        .find_map(|key| {
            message
                .get(key)
                .and_then(Value::as_str)
                .or_else(|| entry.get(key).and_then(Value::as_str))
        })
        .map(str::to_string)
}

fn canonical_provider(hint: Option<&str>, model: &str) -> String {
    let candidate = hint.unwrap_or_else(|| {
        if model.contains("bedrock") || model.starts_with("us.anthropic.") {
            "bedrock"
        } else if model.contains("vertex") {
            "vertex"
        } else {
            "anthropic"
        }
    });
    match candidate.trim().to_ascii_lowercase().as_str() {
        "aws" | "amazon" | "amazon-bedrock" | "bedrock" => "bedrock".to_string(),
        "google" | "vertex" | "vertex_ai" | "vertex-ai" => "vertex".to_string(),
        "anthropic" | "claude" | "first_party" => "anthropic".to_string(),
        other if !other.is_empty() => other.to_string(),
        _ => "anthropic".to_string(),
    }
}

fn canonical_model(model: &str) -> String {
    let mut model = model.trim().to_ascii_lowercase().replace('.', "-");
    for prefix in ["anthropic/", "bedrock/", "vertex/", "vertex_ai/"] {
        if let Some(stripped) = model.strip_prefix(prefix) {
            model = stripped.to_string();
            break;
        }
    }
    for prefix in ["us-anthropic-", "eu-anthropic-", "global-anthropic-", "anthropic-"] {
        if let Some(stripped) = model.strip_prefix(prefix) {
            model = stripped.to_string();
            break;
        }
    }
    if let Some(index) = model.find("-20") {
        model.truncate(index);
    }
    if let Some(index) = model.find("-v1") {
        model.truncate(index);
    }
    for (alias, canonical) in [
        ("claude-4-8-opus", "claude-opus-4-8"),
        ("claude-4-7-opus", "claude-opus-4-7"),
        ("claude-4-6-opus", "claude-opus-4-6"),
        ("claude-4-5-opus", "claude-opus-4-5"),
        ("claude-4-6-sonnet", "claude-sonnet-4-6"),
        ("claude-4-5-sonnet", "claude-sonnet-4-5"),
        ("claude-4-6-haiku", "claude-haiku-4-6"),
        ("claude-4-5-haiku", "claude-haiku-4-5"),
    ] {
        if model == alias {
            return canonical.to_string();
        }
    }
    model
}

fn resolve_agent_name(path: &Path, entry: &Value) -> Option<String> {
    let stem = path.file_stem()?.to_str()?;
    let meta_path = path.with_file_name(format!("{stem}.meta.json"));
    if let Ok(data) = fs::read(&meta_path) {
        if let Ok(meta) = serde_json::from_slice::<Value>(&data) {
            if let Some(name) = meta
                .get("agentType")
                .and_then(Value::as_str)
                .filter(|name| !name.trim().is_empty())
            {
                return Some(name.to_string());
            }
        }
    }
    entry
        .get("agentType")
        .and_then(Value::as_str)
        .filter(|name| !name.trim().is_empty())
        .map(str::to_string)
        .or_else(|| {
            stem.strip_prefix("agent-")
                .filter(|name| !name.is_empty())
                .map(str::to_string)
        })
        .or_else(|| Some("claude-code-subagent".to_string()))
}

fn workspace_from_path(path: &Path) -> (Option<String>, Option<String>) {
    let components = path
        .components()
        .map(|component| component.as_os_str().to_string_lossy())
        .collect::<Vec<_>>();
    for window in components.windows(3) {
        if window[0] == ".claude" && window[1] == "projects" {
            let key = normalize_workspace_key(&window[2]);
            let label = key.as_deref().and_then(workspace_label_from_key);
            return (key, label);
        }
    }
    (None, None)
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

    fn temporary_path(name: &str) -> PathBuf {
        static NEXT_ID: AtomicU64 = AtomicU64::new(0);
        std::env::temp_dir().join(format!(
            "tokenbar-claude-{name}-{}-{}",
            std::process::id(),
            NEXT_ID.fetch_add(1, Ordering::Relaxed)
        ))
    }

    #[test]
    fn parses_main_turn_and_streaming_duplicate() {
        let path = temporary_path("main.jsonl");
        let mut file = fs::File::create(&path).unwrap();
        writeln!(
            file,
            r#"{{"type":"user","timestamp":"2026-07-24T10:00:00Z","cwd":"/tmp/TokenBar","message":{{"content":"Add Claude support"}}}}"#
        )
        .unwrap();
        writeln!(
            file,
            r#"{{"type":"assistant","timestamp":"2026-07-24T10:00:01Z","requestId":"req_011CdLgpfz8ktFeHGLvsS2at","message":{{"id":"msg_011CdLgpiYvHSmP4zgYLrnZn","model":"claude-sonnet-4-6","usage":{{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":40,"cache_creation_input_tokens":10,"cache_creation":{{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":10}}}},"content":[{{"type":"text","text":"Working"}}]}}}}"#
        )
        .unwrap();
        writeln!(
            file,
            r#"{{"type":"assistant","timestamp":"2026-07-24T10:00:02Z","requestId":"req_011CdLgpfz8ktFeHGLvsS2at","message":{{"id":"msg_011CdLgpiYvHSmP4zgYLrnZn","model":"claude-sonnet-4-6","usage":{{"input_tokens":110,"output_tokens":25,"cache_read_input_tokens":45,"cache_creation_input_tokens":12,"cache_creation":{{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":12}}}},"content":[{{"type":"text","text":"Done"}}]}}}}"#
        )
        .unwrap();

        drop(file);
        let messages = parse_claude_file(&path);
        let _ = fs::remove_file(&path);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].client, "claude");
        assert_eq!(messages[0].model_id, "claude-sonnet-4-6");
        assert_eq!(messages[0].tokens.input, 110);
        assert_eq!(messages[0].tokens.output, 25);
        assert_eq!(messages[0].tokens.cache_write, 12);
        assert_eq!(
            messages[0]
                .cache_write_breakdown
                .as_ref()
                .map(|value| value.one_hour),
            Some(12)
        );
        assert_eq!(messages[0].duration_ms, Some(2_000));
        assert_eq!(messages[0].model_duration_ms, Some(2_000));
        assert_eq!(messages[0].time_to_first_token_ms, Some(800));
        assert_eq!(messages[0].content_preview.as_deref(), Some("Add Claude support"));
        assert_eq!(messages[0].output_preview.as_deref(), Some("Done"));
        assert!(messages[0].is_turn_start);
        assert!(!messages[0].is_subagent);
    }

    #[test]
    fn model_request_duration_excludes_time_spent_waiting_for_a_tool_result() {
        let path = temporary_path("tool-wait.jsonl");
        fs::write(
            &path,
            r#"{"type":"user","timestamp":"2026-07-24T10:00:00Z","message":{"content":"Run the command"}}
{"type":"assistant","timestamp":"2026-07-24T10:00:02Z","requestId":"req_011CdLgpfz8ktFeHGLvsS2at","message":{"id":"msg_011CdLgpiYvHSmP4zgYLrnZn","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":20}}}
{"type":"user","timestamp":"2026-07-24T10:01:02Z","message":{"content":[{"type":"tool_result","content":"done"}]}}
{"type":"assistant","timestamp":"2026-07-24T10:01:05Z","requestId":"req_011CdLguF4aY9EYRMx8QD3xC","message":{"id":"msg_011CdLguJGZSqsiQXNeEzVvp","model":"claude-sonnet-4-6","usage":{"input_tokens":110,"output_tokens":30}}}
"#,
        )
        .unwrap();

        let messages = parse_claude_file(&path);
        let _ = fs::remove_file(&path);

        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].model_duration_ms, Some(2_000));
        assert_eq!(messages[1].model_duration_ms, Some(3_000));
        assert_eq!(messages[0].time_to_first_token_ms, Some(800));
        assert_eq!(messages[1].time_to_first_token_ms, Some(950));
        assert!(messages[0].is_turn_start);
        assert!(!messages[1].is_turn_start);
    }

    #[test]
    fn does_not_use_completed_assistant_block_timestamp_as_ttft() {
        let path = temporary_path("completed-block.jsonl");
        fs::write(
            &path,
            r#"{"type":"user","timestamp":"2026-07-24T10:00:00Z","message":{"content":"Think carefully"}}
{"type":"assistant","timestamp":"2026-07-24T10:01:14Z","requestId":"request-1","message":{"id":"message-1","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":20},"content":[{"type":"thinking","thinking":"Done thinking"}]}}
"#,
        )
        .unwrap();

        let messages = parse_claude_file(&path);
        let _ = fs::remove_file(&path);

        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].duration_ms, Some(74_000));
        assert_eq!(messages[0].time_to_first_token_ms, None);
    }

    #[test]
    fn maps_sidechain_to_parent_session() {
        let directory = temporary_path("sidechain");
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("agent-reviewer.jsonl");
        fs::write(
            &path,
            r#"{"type":"user","isSidechain":true,"sessionId":"parent-session","timestamp":"2026-07-24T10:00:00Z","message":{"content":"Review"}}
{"type":"assistant","isSidechain":true,"sessionId":"parent-session","timestamp":"2026-07-24T10:00:01Z","message":{"id":"child-message","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":5}}}
"#,
        )
        .unwrap();

        let messages = parse_claude_file(&path);
        let _ = fs::remove_dir_all(&directory);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].session_id, "parent-session");
        assert_eq!(
            messages[0].physical_session_id.as_deref(),
            Some("agent-reviewer")
        );
        assert!(messages[0].is_subagent);
        assert_eq!(messages[0].agent.as_deref(), Some("reviewer"));
    }

    #[test]
    fn extracts_human_text_blocks_without_treating_tool_results_as_prompts() {
        let human = serde_json::json!({
            "type": "user",
            "message": {
                "content": [
                    {"type": "text", "text": "<system-reminder>ignore</system-reminder>"},
                    {"type": "text", "text": "Implement the platform adapter"}
                ]
            }
        });
        let tool_result = serde_json::json!({
            "type": "user",
            "message": {
                "content": [
                    {"type": "tool_result", "content": "command output"}
                ]
            }
        });

        assert_eq!(
            human_prompt(&human).as_deref(),
            Some("Implement the platform adapter")
        );
        assert_eq!(human_prompt(&tool_result), None);
    }
}
