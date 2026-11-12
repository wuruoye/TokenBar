//! WorkBuddy session parsing.
//!
//! WorkBuddy (CodeBuddy's desktop host) writes one JSONL transcript per
//! session under `~/.workbuddy/projects/<project>/<session>.jsonl`. Each model
//! response spans several rows (reasoning, assistant message, function calls)
//! that share `providerData.messageId`; only the last row of the response
//! carries `providerData.usage`, so every usage row is exactly one request.
//! A user row with `providerData.startsNewUserRequest` opens a turn, and every
//! request of that turn carries the same `conversationRequestId`.
//!
//! WorkBuddy routes requests through Tencent's internal model gateway, so no
//! public price applies and cost stays unknown.

use std::collections::{HashMap, HashSet};
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

pub const PLATFORM: &str = "workbuddy";

#[derive(Debug, Clone, Default)]
pub struct LocalParseOptions {
    pub home_dir: Option<String>,
    pub use_env_roots: bool,
    pub since: Option<String>,
    pub until: Option<String>,
}

#[derive(Debug, Default)]
struct TurnState {
    request_id: Option<String>,
    prompt: Option<String>,
    output: Option<String>,
    first_index: Option<usize>,
}

pub fn parse_local_workbuddy_messages(
    options: LocalParseOptions,
) -> Result<Vec<UnifiedMessage>, String> {
    let paths = discover_files(&options)?;
    let parsed = paths.par_iter().map(|path| parse_file(path)).collect::<Vec<_>>();
    let mut dedup_keys = HashSet::new();
    let mut messages = Vec::new();
    for message in parsed.into_iter().flatten() {
        if message
            .dedup_key
            .as_ref()
            .is_some_and(|key| !dedup_keys.insert(key.clone()))
        {
            continue;
        }
        messages.push(message);
    }
    if let Some(since) = options.since.as_deref() {
        messages.retain(|message| message.date.as_str() >= since);
    }
    if let Some(until) = options.until.as_deref() {
        messages.retain(|message| message.date.as_str() <= until);
    }
    Ok(messages)
}

/// Reads the `ai-title` rows of every transcript that produced messages.
pub fn load_workbuddy_session_titles(messages: &[UnifiedMessage]) -> SessionTitleMap {
    let mut seen = HashSet::new();
    let mut titles = SessionTitleMap::new();
    for message in messages {
        if message.client != PLATFORM || message.is_subagent {
            continue;
        }
        let Some(path) = message.session_path.as_deref() else {
            continue;
        };
        if !seen.insert(path) {
            continue;
        }
        if let Some(title) = read_title(Path::new(path)) {
            titles.insert((PLATFORM.to_string(), message.session_id.clone()), title);
        }
    }
    titles
}

/// Returns the turn prompt and the response text of the request that finished
/// inside `[start_ms, end_ms]`.
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
            "could not open WorkBuddy session {}: {error}",
            session_path.display()
        )
    })?;
    let mut prompt = None;
    let mut response_text: HashMap<String, Vec<String>> = HashMap::new();
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(row) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if is_turn_start(&row) {
            prompt = user_prompt(&row);
            response_text.clear();
            continue;
        }
        let provider = row.get("providerData");
        let message_id = provider
            .and_then(|data| data.get("messageId"))
            .and_then(Value::as_str)
            .map(str::to_string);
        if let (Some(id), Some(text)) = (message_id.as_ref(), response_part(&row)) {
            response_text.entry(id.clone()).or_default().push(text);
        }
        if provider.and_then(|data| data.get("usage")).is_none() {
            continue;
        }
        let Some(timestamp) = row.get("timestamp").and_then(timestamp_ms) else {
            continue;
        };
        if timestamp >= start_ms && timestamp <= end_ms {
            let output = message_id
                .and_then(|id| response_text.remove(&id))
                .filter(|parts| !parts.is_empty())
                .map(|parts| parts.join("\n"));
            return Ok(RequestDetail {
                prompt: prompt.clone(),
                output,
            });
        }
    }
    Ok(RequestDetail::default())
}

fn workbuddy_home(options: &LocalParseOptions) -> Result<PathBuf, String> {
    if options.home_dir.is_none() && options.use_env_roots {
        if let Some(root) = std::env::var_os("WORKBUDDY_HOME").filter(|value| !value.is_empty()) {
            return Ok(PathBuf::from(root));
        }
    }
    let home = options
        .home_dir
        .as_deref()
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
        .or_else(|| std::env::var_os("USERPROFILE").map(PathBuf::from))
        .ok_or("could not resolve the home directory")?;
    Ok(home.join(".workbuddy"))
}

fn discover_files(options: &LocalParseOptions) -> Result<Vec<PathBuf>, String> {
    let mut files = Vec::new();
    collect_transcripts(&workbuddy_home(options)?.join("projects"), 0, &mut files);
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

/// Collects `<project>/<session>.jsonl`, the cloud layout
/// `cloud/<user>/<session>.jsonl`, and subagent transcripts in
/// `<project>/<session>/subagents/agent-<id>.jsonl`. Other session folders only
/// hold tool output, so the walk stays shallow.
fn collect_transcripts(directory: &Path, depth: usize, files: &mut Vec<PathBuf>) {
    if depth > 3 {
        return;
    }
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() && !file_type.is_symlink() {
            if path.file_name().and_then(|name| name.to_str()) != Some("tool-results") {
                collect_transcripts(&path, depth + 1, files);
            }
        } else if file_type.is_file()
            && depth > 0
            && path.extension().and_then(|extension| extension.to_str()) == Some("jsonl")
        {
            files.push(path);
        }
    }
}

fn parse_file(path: &Path) -> Vec<UnifiedMessage> {
    let mut messages = Vec::new();
    let Ok(file) = fs::File::open(path) else {
        return messages;
    };
    let fallback_session_id = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("unknown")
        .to_string();
    let fallback_timestamp = file_modified_timestamp_ms(path);
    let path_text = path.to_string_lossy().into_owned();
    // A subagent writes its own session id; its parent is the folder that holds
    // the `subagents` directory.
    let parent_session_id = (path.parent().and_then(Path::file_name).and_then(|name| name.to_str())
        == Some("subagents"))
    .then(|| {
        path.parent()
            .and_then(Path::parent)
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            .map(str::to_string)
    })
    .flatten();
    let mut turn = TurnState::default();
    let mut workspace: Option<String> = None;
    // A response spans every row sharing one `messageId`; it was requested when
    // the last row before it was written (the user prompt or a tool result).
    let mut previous_row_at: Option<i64> = None;
    let mut response_id: Option<String> = None;
    let mut response_started_at: Option<i64> = None;

    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(row) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let timestamp = row
            .get("timestamp")
            .and_then(timestamp_ms)
            .unwrap_or(fallback_timestamp);
        if workspace.is_none() {
            workspace = row
                .get("cwd")
                .and_then(Value::as_str)
                .and_then(normalize_workspace_key);
        }
        if matches!(
            row.get("type").and_then(Value::as_str),
            Some("ai-title" | "session-meta" | "file-history-snapshot")
        ) {
            continue;
        }
        if is_turn_start(&row) {
            finish_turn(&mut messages, &turn);
            turn = TurnState {
                request_id: conversation_request_id(&row),
                prompt: user_prompt(&row),
                ..TurnState::default()
            };
            previous_row_at = Some(timestamp);
            response_id = None;
            continue;
        }

        let provider = row.get("providerData");
        let message_id = provider
            .and_then(|data| data.get("messageId"))
            .and_then(Value::as_str)
            .map(str::to_string);
        if message_id.is_some() && message_id != response_id {
            response_id = message_id.clone();
            response_started_at = previous_row_at;
        }
        previous_row_at = Some(timestamp);
        if let Some(text) = assistant_text(&row) {
            turn.output = Some(text);
        }

        let Some(usage) = provider.and_then(|data| data.get("usage")) else {
            continue;
        };
        let raw_usage = provider.and_then(|data| data.get("rawUsage"));
        let tokens = disjoint_tokens(usage, raw_usage);
        if tokens.total() == 0 {
            continue;
        }
        let physical_session_id = row
            .get("sessionId")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .unwrap_or(&fallback_session_id)
            .to_string();
        let session_id = parent_session_id
            .clone()
            .unwrap_or_else(|| physical_session_id.clone());
        let agent = parent_session_id.as_ref().map(|_| {
            provider
                .and_then(|data| nonempty(data.get("agent")))
                .unwrap_or_else(|| "subagent".to_string())
        });
        let model = provider
            .and_then(|data| nonempty(data.get("requestModelId")).or_else(|| nonempty(data.get("model"))))
            .map(|model| canonical_model(&model))
            .unwrap_or_else(|| PLATFORM.to_string());
        let mut message = UnifiedMessage::new_with_agent(
            PLATFORM,
            model,
            "tencent",
            session_id.clone(),
            timestamp,
            tokens,
            0.0,
            agent,
        );
        message.physical_session_id = Some(physical_session_id.clone());
        message.is_subagent = parent_session_id.is_some();
        message.session_path = Some(path_text.clone());
        message.cost_source = CostSource::Unknown;
        let duration = response_started_at
            .map(|started| timestamp.saturating_sub(started))
            .filter(|duration| *duration > 0);
        message.duration_ms = duration;
        message.model_duration_ms = duration;
        message.set_workspace(
            workspace.clone(),
            workspace.as_deref().and_then(workspace_label_from_key),
        );
        let request_key = message_id
            .clone()
            .or_else(|| nonempty(row.get("id")))
            .unwrap_or_else(|| timestamp.to_string());
        message.dedup_key = Some(format!("{PLATFORM}:{physical_session_id}:{request_key}"));
        if turn.first_index.is_none() && turn.request_id.is_some() {
            message.is_turn_start = true;
            message.set_content_preview(turn.prompt.as_deref().and_then(content_preview_from_str));
            turn.first_index = Some(messages.len());
        }
        messages.push(message);
    }
    finish_turn(&mut messages, &turn);
    messages
}

/// The reply is only known once the turn ends, so its preview is attached to
/// the turn's first request afterwards.
fn finish_turn(messages: &mut [UnifiedMessage], turn: &TurnState) {
    let Some(index) = turn.first_index else {
        return;
    };
    if let Some(message) = messages.get_mut(index) {
        message.set_output_preview(turn.output.as_deref().and_then(content_preview_from_str));
    }
}

fn is_turn_start(row: &Value) -> bool {
    row.get("type").and_then(Value::as_str) == Some("message")
        && row.get("role").and_then(Value::as_str) == Some("user")
        && row
            .pointer("/providerData/startsNewUserRequest")
            .and_then(Value::as_bool)
            .unwrap_or(true)
}

fn conversation_request_id(row: &Value) -> Option<String> {
    nonempty(row.pointer("/providerData/conversationRequestId"))
        .or_else(|| nonempty(row.get("id")))
}

/// The user's own text, skipping the `<system-reminder>` blocks WorkBuddy
/// prepends with workspace and identity context.
fn user_prompt(row: &Value) -> Option<String> {
    let content = row.get("content")?;
    if let Some(text) = content.as_str() {
        return (!text.trim().is_empty()).then(|| text.to_string());
    }
    let parts = content
        .as_array()?
        .iter()
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .map(str::trim)
        .filter(|text| !text.is_empty() && !text.starts_with("<system-reminder"))
        .collect::<Vec<_>>();
    (!parts.is_empty()).then(|| parts.join("\n"))
}

fn assistant_text(row: &Value) -> Option<String> {
    if row.get("type").and_then(Value::as_str) != Some("message")
        || row.get("role").and_then(Value::as_str) != Some("assistant")
    {
        return None;
    }
    content_text(row.get("content"))
}

/// Text a response row contributes to the request detail: assistant prose, or
/// the tool call it made.
fn response_part(row: &Value) -> Option<String> {
    match row.get("type").and_then(Value::as_str) {
        Some("message") if row.get("role").and_then(Value::as_str) == Some("assistant") => {
            content_text(row.get("content"))
        }
        Some("function_call") => {
            let name = row.get("name").and_then(Value::as_str).unwrap_or("tool");
            let arguments = row
                .pointer("/providerData/argumentsDisplayText")
                .or_else(|| row.get("arguments"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            Some(format!("{name}({arguments})"))
        }
        _ => None,
    }
}

fn content_text(content: Option<&Value>) -> Option<String> {
    let content = content?;
    if let Some(text) = content.as_str() {
        return (!text.trim().is_empty()).then(|| text.to_string());
    }
    let parts = content
        .as_array()?
        .iter()
        .filter(|part| {
            part.get("type")
                .and_then(Value::as_str)
                .is_none_or(|kind| kind == "output_text" || kind == "text")
        })
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .filter(|text| !text.trim().is_empty())
        .collect::<Vec<_>>();
    (!parts.is_empty()).then(|| parts.concat())
}

/// `inputTokens` includes cache hits and `outputTokens` includes reasoning, as
/// in the OpenAI usage shape; TokenBar's buckets are disjoint.
fn disjoint_tokens(usage: &Value, raw: Option<&Value>) -> TokenBreakdown {
    let full_input = integer(usage.get("inputTokens")).max(0);
    let full_output = integer(usage.get("outputTokens")).max(0);
    let cache_read = detail_sum(usage.get("inputTokensDetails"), "cached_tokens")
        .or_else(|| raw.and_then(|raw| raw.pointer("/prompt_tokens_details/cached_tokens")).map(|value| integer(Some(value))))
        .unwrap_or_default()
        .clamp(0, full_input);
    let cache_write = raw
        .map(|raw| {
            integer(raw.get("cache_creation_input_tokens"))
                .max(integer(raw.get("prompt_cache_write_tokens")))
        })
        .unwrap_or_default()
        .clamp(0, full_input - cache_read);
    let reasoning = detail_sum(usage.get("outputTokensDetails"), "reasoning_tokens")
        .unwrap_or_default()
        .clamp(0, full_output);
    TokenBreakdown {
        input: full_input - cache_read - cache_write,
        output: full_output - reasoning,
        cache_read,
        cache_write,
        reasoning,
    }
}

/// `inputTokensDetails` is a list of per-request detail objects.
fn detail_sum(details: Option<&Value>, key: &str) -> Option<i64> {
    let details = details?;
    if let Some(items) = details.as_array() {
        let values = items
            .iter()
            .filter_map(|item| item.get(key))
            .map(|value| integer(Some(value)))
            .collect::<Vec<_>>();
        return (!values.is_empty()).then(|| values.into_iter().sum());
    }
    details.get(key).map(|value| integer(Some(value)))
}

fn read_title(path: &Path) -> Option<String> {
    let file = fs::File::open(path).ok()?;
    let mut title = None;
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        if !line.contains("\"ai-title\"") {
            continue;
        }
        if let Ok(row) = serde_json::from_str::<Value>(&line) {
            if let Some(value) = nonempty(row.get("aiTitle")) {
                title = Some(value);
            }
        }
    }
    title
}

/// Internal gateway ids carry an `-ioa` suffix (`hy4-preview-ioa`); the model
/// is the same, so it is dropped for grouping.
fn canonical_model(model: &str) -> String {
    let model = model.trim().to_ascii_lowercase();
    let model = model.strip_suffix("-ioa").unwrap_or(&model).to_string();
    if model.is_empty() {
        PLATFORM.to_string()
    } else {
        model
    }
}

fn timestamp_ms(value: &Value) -> Option<i64> {
    if let Some(number) = value.as_i64() {
        return Some(if number < 10_000_000_000 {
            number.saturating_mul(1000)
        } else {
            number
        });
    }
    chrono::DateTime::parse_from_rfc3339(value.as_str()?)
        .ok()
        .map(|timestamp| timestamp.timestamp_millis())
}

fn integer(value: Option<&Value>) -> i64 {
    value
        .and_then(|number| {
            number
                .as_i64()
                .or_else(|| number.as_u64().map(|value| value.min(i64::MAX as u64) as i64))
        })
        .unwrap_or_default()
}

fn nonempty(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
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

    const TRANSCRIPT: &str = concat!(
        r#"{"type":"session-meta","sessionId":"s1","timestamp":1794459001000}"#, "\n",
        r#"{"id":"u1","type":"message","role":"user","sessionId":"s1","cwd":"/tmp/demo","timestamp":1794459001000,"content":[{"type":"input_text","text":"<system-reminder>ctx</system-reminder>"},{"type":"input_text","text":"fix the bug"}],"providerData":{"conversationRequestId":"r1","startsNewUserRequest":true}}"#, "\n",
        r#"{"type":"ai-title","aiTitle":"Fix bug","timestamp":1794459001100}"#, "\n",
        r#"{"id":"a1","type":"reasoning","sessionId":"s1","timestamp":1794459001500,"providerData":{"messageId":"m1","model":"hy4-ioa"}}"#, "\n",
        r#"{"id":"a2","type":"function_call","name":"read","arguments":"{}","sessionId":"s1","timestamp":1794459002000,"providerData":{"messageId":"m1","model":"hy4-ioa","usage":{"inputTokens":1000,"outputTokens":100,"inputTokensDetails":[{"cached_tokens":800}],"outputTokensDetails":[{"reasoning_tokens":40}]},"rawUsage":{"cache_creation_input_tokens":50}}}"#, "\n",
        r#"{"id":"a3","type":"function_call_result","sessionId":"s1","timestamp":1794459002500,"providerData":{"messageId":"m1"}}"#, "\n",
        r#"{"id":"a4","type":"message","role":"assistant","sessionId":"s1","timestamp":1794459004000,"content":[{"type":"output_text","text":"done"}],"providerData":{"messageId":"m2","model":"hy4-ioa","usage":{"inputTokens":1200,"outputTokens":20,"inputTokensDetails":[{"cached_tokens":1000}],"outputTokensDetails":[{"reasoning_tokens":0}]}}}"#, "\n",
    );

    #[test]
    fn parses_requests_turns_and_titles() {
        let directory = std::env::temp_dir().join(format!("tokenbar-workbuddy-{}", std::process::id()));
        let project = directory.join(".workbuddy/projects/demo");
        fs::create_dir_all(project.join("s1/tool-results")).unwrap();
        fs::write(project.join("s1.jsonl"), TRANSCRIPT).unwrap();
        fs::write(project.join("s1/tool-results/x.jsonl"), TRANSCRIPT).unwrap();
        fs::create_dir_all(project.join("s1/subagents")).unwrap();
        fs::write(
            project.join("s1/subagents/agent-x.jsonl"),
            TRANSCRIPT
                .replace("\"sessionId\":\"s1\"", "\"sessionId\":\"sub1\"")
                .replace("\"model\":\"hy4-ioa\"", "\"model\":\"hy4-ioa\",\"agent\":\"Explore\""),
        )
        .unwrap();

        let messages = parse_local_workbuddy_messages(LocalParseOptions {
            home_dir: Some(directory.to_string_lossy().into_owned()),
            ..LocalParseOptions::default()
        })
        .unwrap();
        assert_eq!(messages.len(), 4);
        let subagent = messages.iter().filter(|message| message.is_subagent).collect::<Vec<_>>();
        assert_eq!(subagent.len(), 2);
        assert!(subagent.iter().all(|message| message.session_id == "s1"
            && message.physical_session_id.as_deref() == Some("sub1")
            && message.agent.as_deref() == Some("Explore")));
        let messages = messages.into_iter().filter(|message| !message.is_subagent).collect::<Vec<_>>();
        let first = &messages[0];
        assert_eq!(first.model_id, "hy4");
        assert_eq!(first.session_id, "s1");
        assert_eq!(
            first.tokens,
            TokenBreakdown { input: 150, output: 60, cache_read: 800, cache_write: 50, reasoning: 40 }
        );
        assert!(first.is_turn_start);
        assert_eq!(first.content_preview.as_deref(), Some("fix the bug"));
        assert_eq!(first.output_preview.as_deref(), Some("done"));
        assert_eq!(first.model_duration_ms, Some(1000));
        assert_eq!(first.workspace_label.as_deref(), Some("demo"));
        assert_eq!(first.cost_source, CostSource::Unknown);
        assert!(!messages[1].is_turn_start);
        assert_eq!(messages[1].model_duration_ms, Some(1500));

        let titles = load_workbuddy_session_titles(&messages);
        assert_eq!(
            titles.get(&(PLATFORM.to_string(), "s1".to_string())).map(String::as_str),
            Some("Fix bug")
        );

        let detail = extract_request_detail(&project.join("s1.jsonl"), 1794459001900, 1794459002100).unwrap();
        assert_eq!(detail.prompt.as_deref(), Some("fix the bug"));
        assert_eq!(detail.output.as_deref(), Some("read({})"));
        let _ = fs::remove_dir_all(&directory);
    }
}
