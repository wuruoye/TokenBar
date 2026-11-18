//! OpenCode session and token usage parsing.
//!
//! OpenCode stores sessions and messages in `~/.local/share/opencode/opencode.db`
//! (or `$OPENCODE_DATA_DIR/opencode.db` / `$XDG_DATA_HOME/opencode/opencode.db`).
//! Each assistant row in `session_message` carries `model`, `agent`, `time`,
//! `cost`, and `tokens` (`input`, `output`, `reasoning`, `cache.read`, `cache.write`).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, OpenFlags};
use serde_json::Value;

use crate::usage::{
    content_preview_from_str, normalize_reasoning_effort, CostSource, TokenBreakdown, UnifiedMessage,
};
use crate::{RequestDetail, SessionTitleMap};

pub const PLATFORM: &str = "opencode";

#[derive(Debug, Clone, Default)]
pub struct LocalParseOptions {
    pub home_dir: Option<String>,
    pub use_env_roots: bool,
    pub since: Option<String>,
    pub until: Option<String>,
}

pub fn parse_local_opencode_messages(
    options: LocalParseOptions,
) -> Result<Vec<UnifiedMessage>, String> {
    let path = database_path(&options)?;
    if !path.is_file() {
        return Ok(Vec::new());
    }
    let path_text = path.to_string_lossy().into_owned();
    let conn = open_readonly(&path)?;
    let mut stmt = conn
        .prepare(
            "SELECT id, session_id, time_created, data
             FROM session_message
             WHERE type = 'assistant'
             ORDER BY time_created ASC",
        )
        .map_err(|error| format!("failed to query OpenCode messages: {error}"))?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
            ))
        })
        .map_err(|error| format!("failed to read OpenCode messages: {error}"))?;

    let mut messages = Vec::new();
    for row in rows {
        let Ok((message_id, session_id, row_created_ms, raw_data)) = row else {
            continue;
        };
        let Ok(data) = serde_json::from_str::<Value>(&raw_data) else {
            continue;
        };
        let Some(tokens) = parse_tokens(&data) else {
            continue;
        };
        if tokens.total() == 0 {
            continue;
        }
        let model_id = data
            .pointer("/model/id")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .trim()
            .to_string();
        let agent = data
            .get("agent")
            .and_then(Value::as_str)
            .unwrap_or("opencode")
            .to_string();
        let reasoning_effort = data
            .pointer("/model/variant")
            .and_then(Value::as_str)
            .and_then(normalize_reasoning_effort);
        let time = data.get("time");
        let created_ms = time
            .and_then(|t| t.get("created"))
            .and_then(Value::as_i64)
            .unwrap_or(row_created_ms);
        let streamed_ms = time.and_then(|t| t.get("streamed")).and_then(Value::as_i64);
        let completed_ms = time
            .and_then(|t| t.get("completed"))
            .and_then(Value::as_i64);
        let timestamp_ms = completed_ms.unwrap_or(created_ms);
        let generation_duration_ms = match (streamed_ms.or(Some(created_ms)), completed_ms) {
            (Some(start), Some(end)) if end > start => Some(end - start),
            _ => None,
        };
        let reported_cost = data
            .get("cost")
            .and_then(Value::as_f64)
            .filter(|c| *c > 0.0);
        let cost = reported_cost.unwrap_or(0.0);
        let cost_source = if reported_cost.is_some() {
            CostSource::ProviderReported
        } else {
            CostSource::Unknown
        };
        let preview = assistant_preview(&data);

        let mut message = UnifiedMessage::new_with_agent(
            PLATFORM,
            model_id,
            agent,
            session_id,
            timestamp_ms,
            tokens,
            cost,
            Some(path_text.clone()),
        );
        message.reasoning_effort = reasoning_effort;
        message.cost_source = cost_source;
        message.model_duration_ms = generation_duration_ms;
        message.content_preview = preview;
        message.source_turn_id = Some(message_id);
        messages.push(message);
    }
    Ok(messages)
}

pub fn load_opencode_session_titles(options: &LocalParseOptions) -> SessionTitleMap {
    let Ok(path) = database_path(options) else {
        return HashMap::new();
    };
    if !path.is_file() {
        return HashMap::new();
    }
    let Ok(conn) = open_readonly(&path) else {
        return HashMap::new();
    };
    let Ok(mut stmt) = conn.prepare(
        "SELECT id, title
         FROM session_v2
         WHERE parent_id IS NULL AND title IS NOT NULL AND trim(title) != ''",
    ) else {
        return HashMap::new();
    };
    let Ok(rows) = stmt.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    }) else {
        return HashMap::new();
    };
    let mut titles = HashMap::new();
    for row in rows.flatten() {
        let title = row.1.trim();
        if !title.is_empty() {
            titles.insert(
                (PLATFORM.to_string(), row.0),
                title.to_string(),
            );
        }
    }
    titles
}

pub fn extract_request_detail(
    path: &Path,
    start_ms: i64,
    end_ms: i64,
) -> Result<RequestDetail, String> {
    if !path.is_file() {
        return Ok(RequestDetail::default());
    }
    let conn = open_readonly(path)?;
    let mut stmt = conn
        .prepare(
            "SELECT data
             FROM session_message
             WHERE type = 'assistant'
               AND time_created BETWEEN ?1 AND ?2
             ORDER BY time_created DESC
             LIMIT 1",
        )
        .map_err(|error| format!("failed to query OpenCode request detail: {error}"))?;
    let mut rows = stmt
        .query_map([start_ms.saturating_sub(60_000), end_ms], |row| {
            row.get::<_, String>(0)
        })
        .map_err(|error| format!("failed to read OpenCode request detail: {error}"))?;
    let Some(Ok(raw)) = rows.next() else {
        return Ok(RequestDetail::default());
    };
    let Ok(data) = serde_json::from_str::<Value>(&raw) else {
        return Ok(RequestDetail::default());
    };
    let Some(text) = assistant_full_text(&data) else {
        return Ok(RequestDetail::default());
    };
    Ok(RequestDetail {
        prompt: None,
        output: Some(text),
    })
}

fn open_readonly(path: &Path) -> Result<Connection, String> {
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|error| format!("could not open OpenCode database {}: {error}", path.display()))?;
    let _ = conn.busy_timeout(Duration::from_millis(1000));
    Ok(conn)
}

fn database_path(options: &LocalParseOptions) -> Result<PathBuf, String> {
    if options.use_env_roots {
        if let Some(root) = std::env::var_os("OPENCODE_DATA_DIR").filter(|v| !v.is_empty()) {
            return Ok(PathBuf::from(root).join("opencode.db"));
        }
        if let Some(xdg) = std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()) {
            return Ok(PathBuf::from(xdg).join("opencode").join("opencode.db"));
        }
    }
    let home = options
        .home_dir
        .as_ref()
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").filter(|v| !v.is_empty()).map(PathBuf::from))
        .ok_or_else(|| "could not resolve home directory for OpenCode".to_string())?;
    Ok(home.join(".local/share/opencode/opencode.db"))
}

fn parse_tokens(data: &Value) -> Option<TokenBreakdown> {
    let tokens = data.get("tokens")?;
    let input = tokens.get("input").and_then(Value::as_i64).unwrap_or(0).max(0);
    let output = tokens.get("output").and_then(Value::as_i64).unwrap_or(0).max(0);
    let reasoning = tokens
        .get("reasoning")
        .and_then(Value::as_i64)
        .unwrap_or(0)
        .max(0);
    let cache = tokens.get("cache");
    let cache_read = cache
        .and_then(|c| c.get("read"))
        .and_then(Value::as_i64)
        .unwrap_or(0)
        .max(0);
    let cache_write = cache
        .and_then(|c| c.get("write"))
        .and_then(Value::as_i64)
        .unwrap_or(0)
        .max(0);
    Some(TokenBreakdown {
        input,
        output,
        cache_read,
        cache_write,
        reasoning,
    })
}

fn assistant_full_text(data: &Value) -> Option<String> {
    let parts = data.get("content")?.as_array()?;
    let texts: Vec<&str> = parts
        .iter()
        .filter(|part| part.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .filter(|text| !text.trim().is_empty())
        .collect();
    if texts.is_empty() {
        None
    } else {
        Some(texts.join("\n\n"))
    }
}

fn assistant_preview(data: &Value) -> Option<String> {
    let full = assistant_full_text(data)?;
    content_preview_from_str(&full)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn parses_opencode_sqlite_messages_and_titles() {
        let dir = std::env::temp_dir().join(format!("tokenbar-opencode-{}", std::process::id()));
        let db_dir = dir.join(".local/share/opencode");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&db_dir).unwrap();
        let db_path = db_dir.join("opencode.db");

        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "CREATE TABLE session_v2 (
                id TEXT PRIMARY KEY,
                parent_id TEXT,
                title TEXT
            );
            CREATE TABLE session_message (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                type TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                data TEXT NOT NULL
            );",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO session_v2 (id, parent_id, title) VALUES (?1, NULL, ?2)",
            ("ses_1", "OpenCode Demo Session"),
        )
        .unwrap();
        conn.execute(
            "INSERT INTO session_message (id, session_id, type, time_created, data)
             VALUES (?1, ?2, 'assistant', ?3, ?4)",
            rusqlite::params![
                "msg_1",
                "ses_1",
                1_794_475_998_374_i64,
                r#"{"time":{"created":1794475998374,"streamed":1794476000000,"completed":1794476002000},"agent":"build","model":{"id":"gemini-4-hydrogen","providerID":"google-vertex","variant":"medium"},"content":[{"type":"text","text":"Hello from OpenCode"}],"cost":0.12,"tokens":{"input":1000,"output":250,"reasoning":50,"cache":{"read":4000,"write":100}}}"#,
            ],
        )
        .unwrap();
        drop(conn);

        let options = LocalParseOptions {
            home_dir: Some(dir.to_string_lossy().into_owned()),
            use_env_roots: false,
            since: None,
            until: None,
        };
        let messages = parse_local_opencode_messages(options.clone()).unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].client, "opencode");
        assert_eq!(messages[0].model_id, "gemini-4-hydrogen");
        assert_eq!(messages[0].tokens.input, 1000);
        assert_eq!(messages[0].tokens.output, 250);
        assert_eq!(messages[0].tokens.reasoning, 50);
        assert_eq!(messages[0].tokens.cache_read, 4000);
        assert_eq!(messages[0].tokens.cache_write, 100);
        assert_eq!(messages[0].model_duration_ms, Some(2000));
        assert_eq!(messages[0].cost, 0.12);

        let titles = load_opencode_session_titles(&options);
        assert_eq!(
            titles.get(&("opencode".to_string(), "ses_1".to_string())),
            Some(&"OpenCode Demo Session".to_string())
        );

        let _ = fs::remove_dir_all(&dir);
    }
}
