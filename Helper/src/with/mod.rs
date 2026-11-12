//! With (Knot desktop) session parsing.
//!
//! With keeps conversation history on its server. The only local token record
//! is `qa_detail.db`, a cache of message details the app has loaded, evicted by
//! last access. Each row is one user turn with `prompt_tokens` and
//! `completion_tokens` summed over every model call in that turn, without a
//! cache split, so:
//!
//! - coverage is limited to messages still in the cache;
//! - all prompt tokens land in `input`, and no cost is estimated, because
//!   pricing the cache hits as fresh input would overstate it many times over;
//! - the per-turn prompt total is not a prompt size, so context occupancy is
//!   left unknown.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{Local, NaiveDateTime, TimeZone};
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;

use crate::usage::{content_preview_from_str, normalize_reasoning_effort, CostSource, TokenBreakdown, UnifiedMessage};
use crate::RequestDetail;

pub const PLATFORM: &str = "with";

#[derive(Debug, Clone, Default)]
pub struct LocalParseOptions {
    pub home_dir: Option<String>,
    pub use_env_roots: bool,
    pub since: Option<String>,
    pub until: Option<String>,
}

/// One cached turn, decoded from `qa_message_detail.payload_json`.
#[derive(Debug, Clone)]
struct CachedTurn {
    message_id: String,
    session_id: String,
    model: String,
    reasoning_effort: Option<String>,
    started_at_ms: i64,
    duration_ms: Option<i64>,
    prompt_tokens: i64,
    completion_tokens: i64,
    request: Option<String>,
    response: Option<String>,
}

impl CachedTurn {
    fn ended_at_ms(&self) -> i64 {
        self.started_at_ms.saturating_add(self.duration_ms.unwrap_or(0))
    }
}

pub fn parse_local_with_messages(options: LocalParseOptions) -> Result<Vec<UnifiedMessage>, String> {
    let path = database_path(&options)?;
    if !path.is_file() {
        return Ok(Vec::new());
    }
    let path_text = path.to_string_lossy().into_owned();
    let mut seen = HashSet::new();
    let mut messages = Vec::new();
    for turn in read_turns(&path)? {
        if !seen.insert(turn.message_id.clone()) {
            continue;
        }
        let tokens = TokenBreakdown {
            input: turn.prompt_tokens.max(0),
            output: turn.completion_tokens.max(0),
            ..TokenBreakdown::default()
        };
        if tokens.total() == 0 {
            continue;
        }
        let mut message = UnifiedMessage::new_with_agent(
            PLATFORM,
            turn.model.clone(),
            "knot",
            turn.session_id.clone(),
            turn.ended_at_ms(),
            tokens,
            0.0,
            None,
        );
        message.physical_session_id = Some(turn.session_id.clone());
        message.session_path = Some(path_text.clone());
        message.reasoning_effort = turn.reasoning_effort.clone();
        message.cost_source = CostSource::Unknown;
        message.duration_ms = turn.duration_ms;
        message.is_turn_start = true;
        // Zero marks the prompt size unknown; see the module note.
        message.prompt_tokens = Some(0);
        message.set_content_preview(turn.request.as_deref().and_then(content_preview_from_str));
        message.set_output_preview(turn.response.as_deref().and_then(content_preview_from_str));
        message.dedup_key = Some(format!("{PLATFORM}:{}", turn.message_id));
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

/// Returns the prompt and reply of the cached turn that ended in `[start_ms, end_ms]`.
pub fn extract_request_detail(database: &Path, start_ms: i64, end_ms: i64) -> Result<RequestDetail, String> {
    if start_ms > end_ms {
        return Err("request start must not be after request end".to_string());
    }
    Ok(read_turns(database)?
        .into_iter()
        .find(|turn| (start_ms..=end_ms).contains(&turn.ended_at_ms()))
        .map(|turn| RequestDetail {
            prompt: turn.request,
            output: turn.response,
        })
        .unwrap_or_default())
}

fn database_path(options: &LocalParseOptions) -> Result<PathBuf, String> {
    if options.home_dir.is_none() && options.use_env_roots {
        if let Some(root) = std::env::var_os("WITH_DATA_DIR").filter(|value| !value.is_empty()) {
            return Ok(PathBuf::from(root).join("qa_detail.db"));
        }
    }
    let home = options
        .home_dir
        .as_deref()
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
        .ok_or("could not resolve the home directory")?;
    Ok(home
        .join("Library/Application Support/com.tencent.with")
        .join("qa_detail.db"))
}

fn read_turns(path: &Path) -> Result<Vec<CachedTurn>, String> {
    let connection = open_readonly(path)?;
    let mut statement = connection
        .prepare("SELECT message_id, session_id, payload_json FROM qa_message_detail")
        .map_err(|error| format!("could not read With cache {}: {error}", path.display()))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })
        .map_err(|error| format!("could not read With cache {}: {error}", path.display()))?;
    Ok(rows
        .filter_map(Result::ok)
        .filter_map(|(message_id, session_id, payload)| decode_turn(message_id, session_id, &payload))
        .collect())
}

fn decode_turn(message_id: String, session_id: String, payload: &str) -> Option<CachedTurn> {
    let payload = serde_json::from_str::<Value>(payload).ok()?;
    let status = payload.get("status").and_then(Value::as_str).unwrap_or("done");
    if status != "done" {
        return None;
    }
    let events = payload
        .get("response")
        .and_then(Value::as_str)
        .map(response_events)
        .unwrap_or_default();
    let started_at_ms = events
        .iter()
        .find(|event| event.get("type").and_then(Value::as_str) == Some("RUN_STARTED"))
        .and_then(|event| event.get("timestamp"))
        .and_then(epoch_ms)
        .or_else(|| local_datetime_ms(payload.get("request_at")?.as_str()?))
        .or_else(|| local_datetime_ms(payload.get("created_at")?.as_str()?))?;
    let snapshot = payload
        .pointer("/custom_data/model_extra_snapshot")
        .and_then(Value::as_str)
        .and_then(|text| serde_json::from_str::<Value>(text).ok());
    let model = nonempty(payload.get("model_name"))
        .or_else(|| snapshot.as_ref().and_then(|value| nonempty(value.get("effectiveModel"))))
        .map(|model| model.to_ascii_lowercase())
        .unwrap_or_else(|| PLATFORM.to_string());
    let reasoning_effort = snapshot
        .as_ref()
        .and_then(|value| value.get("reasoningEffort"))
        .and_then(Value::as_str)
        .and_then(normalize_reasoning_effort);
    let reply = events
        .iter()
        .filter(|event| event.get("type").and_then(Value::as_str) == Some("TEXT_MESSAGE_CONTENT"))
        .filter_map(|event| {
            event
                .pointer("/rawEvent/content")
                .or_else(|| event.get("delta"))
                .and_then(Value::as_str)
        })
        .collect::<String>();
    Some(CachedTurn {
        message_id,
        session_id: nonempty(payload.get("session_id")).unwrap_or(session_id),
        model,
        reasoning_effort,
        started_at_ms,
        duration_ms: integer(payload.get("cost_time")).filter(|duration| *duration > 0),
        prompt_tokens: integer(payload.get("prompt_tokens")).unwrap_or_default(),
        completion_tokens: integer(payload.get("completion_tokens")).unwrap_or_default(),
        request: nonempty(payload.get("request")),
        response: (!reply.trim().is_empty()).then_some(reply),
    })
}

/// The reply is stored as the raw ag_ui stream: JSON events separated by blank lines.
fn response_events(stream: &str) -> Vec<Value> {
    stream
        .split("\n\n")
        .filter_map(|chunk| serde_json::from_str::<Value>(chunk.trim()).ok())
        .collect()
}

fn open_readonly(path: &Path) -> Result<Connection, String> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|error| format!("could not open With cache {}: {error}", path.display()))?;
    let _ = connection.busy_timeout(Duration::from_millis(1000));
    Ok(connection)
}

fn epoch_ms(value: &Value) -> Option<i64> {
    let number = value.as_i64()?;
    Some(if number < 10_000_000_000 { number.saturating_mul(1000) } else { number })
}

/// `request_at` is wall-clock local time, `YYYY-MM-DD HH:MM:SS`.
fn local_datetime_ms(text: &str) -> Option<i64> {
    let naive = NaiveDateTime::parse_from_str(text.trim(), "%Y-%m-%d %H:%M:%S").ok()?;
    Local.from_local_datetime(&naive).earliest().map(|time| time.timestamp_millis())
}

fn integer(value: Option<&Value>) -> Option<i64> {
    let value = value?;
    value
        .as_i64()
        .or_else(|| value.as_u64().map(|number| number.min(i64::MAX as u64) as i64))
        .or_else(|| value.as_str()?.trim().parse().ok())
}

fn nonempty(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn payload(status: &str, prompt: i64) -> String {
        serde_json::json!({
            "session_id": "s1",
            "status": status,
            "model_name": "Claude-Opus-5.5",
            "prompt_tokens": prompt,
            "completion_tokens": 20,
            "cost_time": 3000,
            "request": "hello",
            "request_at": "2026-11-12 14:38:01",
            "custom_data": {"model_extra_snapshot": "{\"reasoningEffort\":\"xhigh\"}"},
            "response": "{\"type\":\"RUN_STARTED\",\"timestamp\":1794465481}\n\n{\"type\":\"TEXT_MESSAGE_CONTENT\",\"rawEvent\":{\"content\":\"hi \"}}\n\n{\"type\":\"TEXT_MESSAGE_CONTENT\",\"rawEvent\":{\"content\":\"there\"}}"
        })
        .to_string()
    }

    #[test]
    fn parses_cached_turns_without_cost_or_occupancy() {
        let directory = std::env::temp_dir().join(format!("tokenbar-with-{}", std::process::id()));
        let support = directory.join("Library/Application Support/com.tencent.with");
        std::fs::create_dir_all(&support).unwrap();
        let database = support.join("qa_detail.db");
        let _ = std::fs::remove_file(&database);
        let connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE qa_message_detail (message_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL, last_accessed_at INTEGER NOT NULL DEFAULT 0);",
            )
            .unwrap();
        for (id, status, prompt) in [("m1", "done", 1000), ("m2", "streaming", 500), ("m3", "done", 0)] {
            connection
                .execute(
                    "INSERT INTO qa_message_detail VALUES (?1, 's1', ?2, 0, 0)",
                    rusqlite::params![id, payload(status, prompt)],
                )
                .unwrap();
        }
        drop(connection);

        let messages = parse_local_with_messages(LocalParseOptions {
            home_dir: Some(directory.to_string_lossy().into_owned()),
            ..LocalParseOptions::default()
        })
        .unwrap();
        assert_eq!(messages.len(), 2, "streaming turns are skipped");
        let first = messages.iter().find(|message| message.dedup_key.as_deref() == Some("with:m1")).unwrap();
        assert_eq!(first.model_id, "claude-opus-5.5");
        assert_eq!(first.reasoning_effort.as_deref(), Some("xhigh"));
        assert_eq!(first.tokens.input, 1000);
        assert_eq!(first.tokens.output, 20);
        assert_eq!(first.timestamp, 1_794_465_481_000 + 3000);
        assert_eq!(first.cost, 0.0);
        assert_eq!(first.cost_source, CostSource::Unknown);
        assert_eq!(first.resolved_prompt_tokens(), 0);
        assert_eq!(first.output_preview.as_deref(), Some("hi there"));

        let detail = extract_request_detail(&database, 1_794_465_484_000, 1_794_465_484_000).unwrap();
        assert_eq!(detail.prompt.as_deref(), Some("hello"));
        let _ = std::fs::remove_dir_all(&directory);
    }
}
