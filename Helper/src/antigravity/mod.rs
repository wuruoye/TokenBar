//! Antigravity conversation parsing.
//!
//! Antigravity keeps one SQLite database per conversation under
//! `~/.gemini/antigravity/conversations`. Steps, generation metadata, and the
//! workspace record are stored as protobuf blobs whose schema Google does not
//! publish, so every field number lives in this adapter and the rest of
//! TokenBar only sees disjoint token buckets.

mod proto;

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::NaiveDate;
use rayon::prelude::*;
use rusqlite::{Connection, OpenFlags};

use crate::pricing::{AnthropicPricing, GooglePricing};
use crate::usage::{
    content_preview_from_str, normalize_model_for_grouping, normalize_workspace_key,
    reasoning_effort_from_model, workspace_label_from_key, CostSource, TokenBreakdown,
    UnifiedMessage,
};
use crate::{RequestDetail, SessionTitleMap};

/// `step_type` values used by the conversation log.
const STEP_TYPE_USER_MESSAGE: i64 = 14;
const STEP_TYPE_CONVERSATION_START: i64 = 23;
const STEP_TYPE_MODEL_RESPONSE: i64 = 15;

/// `StepMetadata` field numbers.
const META_STARTED_AT: u32 = 1;
const META_FIRST_TOKEN_AT: u32 = 6;
const META_FINISHED_AT: u32 = 8;
const META_USAGE: u32 = 9;
const META_MODEL_KEY: u32 = 11;
const META_TITLE_USAGE: u32 = 28;

/// `Usage` field numbers.
const USAGE_MODEL_KEY: u32 = 1;
const USAGE_INPUT: u32 = 2;
const USAGE_OUTPUT_TOTAL: u32 = 3;
const USAGE_CACHE_READ: u32 = 5;
const USAGE_REASONING: u32 = 9;
const USAGE_OUTPUT_TEXT: u32 = 10;

/// `StepPayload` field numbers.
const PAYLOAD_USER_MESSAGE: u32 = 19;
const PAYLOAD_MODEL_RESPONSE: u32 = 20;
const PAYLOAD_CONVERSATION_START: u32 = 30;

#[derive(Debug, Clone, Default)]
pub struct LocalParseOptions {
    pub home_dir: Option<String>,
    pub use_env_roots: bool,
    pub since: Option<String>,
    pub until: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct ConversationMetadata {
    conversation_id: String,
    root_conversation_id: String,
    is_subagent: bool,
    agent_name: Option<String>,
    workspace_key: Option<String>,
    workspace_label: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct SummaryRecord {
    title: Option<String>,
    parent_conversation_id: Option<String>,
    agent_name: Option<String>,
    workspace_key: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct StepRecord {
    index: i64,
    step_type: i64,
    started_at_ms: Option<i64>,
    first_token_at_ms: Option<i64>,
    finished_at_ms: Option<i64>,
    model_key: Option<u64>,
    usage: Option<TokenBreakdown>,
    is_model_response: bool,
    prompt: Option<String>,
    output: Option<String>,
}

pub fn parse_local_antigravity_messages(
    options: LocalParseOptions,
    anthropic_pricing: &AnthropicPricing,
    google_pricing: &GooglePricing,
) -> Result<Vec<UnifiedMessage>, String> {
    let summaries = antigravity_home(&options)
        .map(|root| load_summary_records(&root))
        .unwrap_or_default();
    let paths = discover_conversation_files(&options)?;
    let parsed = paths
        .par_iter()
        .map(|path| parse_conversation_file(path, &summaries))
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
            // Antigravity runs both Gemini and Claude models, so each request is
            // priced from the catalog that actually owns its model.
            let costs = if message.provider_id == "anthropic" {
                anthropic_pricing.calculate_token_costs(&message.model_id, &message.tokens)
            } else {
                google_pricing.calculate_token_costs(&message.model_id, &message.tokens)
            };
            if let Some(costs) = costs {
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

/// Reads the conversation titles Antigravity keeps in its summary index and
/// per-conversation annotation files.
pub fn load_antigravity_session_titles(options: &LocalParseOptions) -> SessionTitleMap {
    let mut titles = SessionTitleMap::new();
    let Some(root) = antigravity_home(options) else {
        return titles;
    };
    if let Ok(blob) = fs::read(root.join("agyhub_summaries_proto.pb")) {
        for (number, value) in proto::fields(&blob) {
            if number != 1 {
                continue;
            }
            let Some(entry) = value.as_bytes() else {
                continue;
            };
            let Some(conversation_id) = proto::string(entry, &[1]) else {
                continue;
            };
            let Some(title) = proto::string(entry, &[2, 1]).and_then(nonempty_trimmed) else {
                continue;
            };
            titles.insert(
                ("antigravity".to_string(), conversation_id.to_string()),
                title,
            );
        }
    }
    for (conversation_id, record) in load_summary_records(&root) {
        if let Some(title) = record.title {
            titles.insert(("antigravity".to_string(), conversation_id), title);
        }
    }
    load_annotation_titles(&root, &mut titles);
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
    let connection = open_readonly_or_sandbox_immutable(session_path)?;
    let steps = read_steps(&connection)?;

    let mut prompt: Option<String> = None;
    let mut output: Vec<String> = Vec::new();
    for step in &steps {
        let timestamp = step.finished_at_ms.or(step.started_at_ms);
        if let Some(text) = step.prompt.as_deref() {
            // A turn spans several steps, so keep the newest prompt that opened
            // at or before the request window.
            if timestamp.is_none_or(|value| value <= end_ms) && output.is_empty() {
                prompt = Some(text.to_string());
            }
            continue;
        }
        let Some(timestamp) = timestamp else {
            continue;
        };
        if !step.is_model_response || timestamp < start_ms || timestamp > end_ms {
            continue;
        }
        if let Some(text) = step.output.as_deref() {
            output.push(text.to_string());
        }
    }

    Ok(RequestDetail {
        prompt,
        output: (!output.is_empty()).then(|| output.join("\n\n")),
    })
}

fn antigravity_home(options: &LocalParseOptions) -> Option<PathBuf> {
    if let Some(home_dir) = options.home_dir.as_deref() {
        return Some(PathBuf::from(home_dir).join(".gemini").join("antigravity"));
    }
    if options.use_env_roots {
        if let Some(root) = std::env::var_os("ANTIGRAVITY_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
        {
            return Some(root);
        }
    }
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .map(|home| home.join(".gemini").join("antigravity"))
}

fn discover_conversation_files(
    options: &LocalParseOptions,
) -> Result<Vec<PathBuf>, String> {
    let root = antigravity_home(options).ok_or("could not resolve the home directory")?;
    let Ok(entries) = fs::read_dir(root.join("conversations")) else {
        return Ok(Vec::new());
    };
    let mut files = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_file()
                && path.extension().and_then(|value| value.to_str()) == Some("db")
        })
        .collect::<Vec<_>>();

    if let Some(since) = options
        .since
        .as_deref()
        .and_then(|value| NaiveDate::parse_from_str(value, "%Y-%m-%d").ok())
    {
        files.retain(|path| {
            newest_modified_date(path)
                .map(|date| date >= since)
                .unwrap_or(true)
        });
    }
    files.sort();
    files.dedup();
    Ok(files)
}

/// Antigravity writes through WAL, so a stale `.db` mtime can hide fresh turns.
fn newest_modified_date(path: &Path) -> Option<NaiveDate> {
    let mut newest = None;
    for candidate in [
        path.to_path_buf(),
        append_extension(path, "-wal"),
        append_extension(path, "-shm"),
    ] {
        let Some(modified) = candidate
            .metadata()
            .and_then(|metadata| metadata.modified())
            .ok()
            .map(chrono::DateTime::<chrono::Local>::from)
            .map(|timestamp| timestamp.date_naive())
        else {
            continue;
        };
        newest = Some(newest.map_or(modified, |current: NaiveDate| current.max(modified)));
    }
    newest
}

fn append_extension(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

/// Opens the conversation read-only so a running Antigravity keeps ownership of
/// the database.
fn open_readonly(path: &Path) -> Result<Connection, rusqlite::Error> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let _ = connection.busy_timeout(Duration::from_millis(1000));
    Ok(connection)
}

fn is_shm_access_error(error: &rusqlite::Error) -> bool {
    matches!(
        error.sqlite_error_code(),
        Some(rusqlite::ErrorCode::CannotOpen | rusqlite::ErrorCode::ReadOnly)
    )
}

fn open_readonly_or_sandbox_immutable(path: &Path) -> Result<Connection, String> {
    match open_readonly(path) {
        Ok(connection) => Ok(connection),
        Err(error) if is_shm_access_error(&error) => open_immutable(path),
        Err(error) => Err(format!(
            "could not open Antigravity conversation {}: {error}",
            path.display()
        )),
    }
}

fn open_immutable(path: &Path) -> Result<Connection, String> {
    let encoded = path
        .to_string_lossy()
        .replace('%', "%25")
        .replace('?', "%3f")
        .replace('#', "%23");
    let uri = format!("file:{encoded}?immutable=1");
    Connection::open_with_flags(
        uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|error| {
        format!(
            "could not open Antigravity database immutable {}: {error}",
            path.display()
        )
    })
}

fn table_columns(connection: &Connection, table: &str) -> HashSet<String> {
    connection
        .prepare(&format!("PRAGMA table_info({table})"))
        .ok()
        .and_then(|mut statement| {
            statement
                .query_map([], |row| row.get::<_, String>(1))
                .ok()
                .map(|rows| rows.filter_map(Result::ok).collect::<HashSet<_>>())
        })
        .unwrap_or_default()
}

fn load_summary_records(root: &Path) -> HashMap<String, SummaryRecord> {
    let mut records = HashMap::new();
    let db_path = root.join("conversation_summaries.db");
    if !db_path.is_file() {
        return records;
    }
    let mut connection = match open_readonly_or_sandbox_immutable(&db_path) {
        Ok(connection) => connection,
        Err(_) => return records,
    };
    let mut columns = table_columns(&connection, "conversation_summaries");
    if columns.is_empty() {
        let probe_err = connection
            .prepare("SELECT 1 FROM sqlite_master LIMIT 1")
            .err();
        if probe_err.as_ref().is_some_and(is_shm_access_error) {
            if let Ok(fallback) = open_immutable(&db_path) {
                columns = table_columns(&fallback, "conversation_summaries");
                connection = fallback;
            }
        }
    }
    if !columns.contains("conversation_id") {
        return records;
    }

    let select_col = |name: &str| {
        if columns.contains(name) {
            name.to_string()
        } else {
            format!("NULL AS {name}")
        }
    };
    let query = format!(
        "SELECT conversation_id, {}, {}, {}, {} FROM conversation_summaries",
        select_col("title"),
        select_col("parent_conversation_id"),
        select_col("agent_name"),
        select_col("workspace_uris"),
    );
    let Ok(mut statement) = connection.prepare(&query) else {
        return records;
    };
    let Ok(rows) = statement.query_map([], |row| {
        Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, Option<String>>(4)?,
        ))
    }) else {
        return records;
    };

    for row in rows.filter_map(Result::ok) {
        let (id, title, parent_id, agent_name, workspace_uris) = row;
        let Some(id) = id.as_deref().and_then(nonempty_trimmed) else {
            continue;
        };
        let workspace_key = workspace_uris
            .as_deref()
            .and_then(first_workspace_key_from_uris);
        records.insert(
            id,
            SummaryRecord {
                title: title.as_deref().and_then(nonempty_trimmed),
                parent_conversation_id: parent_id.as_deref().and_then(nonempty_trimmed),
                agent_name: agent_name.as_deref().and_then(nonempty_trimmed),
                workspace_key,
            },
        );
    }
    records
}

fn first_workspace_key_from_uris(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Ok(uris) = serde_json::from_str::<Vec<String>>(trimmed) {
        for uri in uris {
            if let Some(key) = strip_file_scheme(&uri).and_then(|value| normalize_workspace_key(&value))
            {
                return Some(key);
            }
        }
        return None;
    }
    strip_file_scheme(trimmed).and_then(|value| normalize_workspace_key(&value))
}

fn load_annotation_titles(root: &Path, titles: &mut SessionTitleMap) {
    let Ok(entries) = fs::read_dir(root.join("annotations")) else {
        return;
    };
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("pbtxt") {
            continue;
        }
        let Some(conversation_id) = path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .and_then(nonempty_trimmed)
        else {
            continue;
        };
        let Ok(contents) = fs::read_to_string(&path) else {
            continue;
        };
        if let Some(title) = parse_pbtxt_top_level_title(&contents) {
            titles.insert(("antigravity".to_string(), conversation_id), title);
        }
    }
}

fn parse_pbtxt_top_level_title(contents: &str) -> Option<String> {
    for line in contents.lines() {
        if line.starts_with(' ') || line.starts_with('\t') {
            continue;
        }
        let Some(rest) = line.strip_prefix("title:") else {
            continue;
        };
        let quoted = rest.trim();
        if quoted.len() < 2 || !quoted.starts_with('"') || !quoted.ends_with('"') {
            continue;
        }
        let decoded = decode_pbtxt_string(&quoted[1..quoted.len() - 1]);
        if let Some(title) = nonempty_trimmed(&decoded) {
            return Some(title);
        }
    }
    None
}

fn decode_pbtxt_string(escaped: &str) -> String {
    let bytes = escaped.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'\\' || index + 1 >= bytes.len() {
            out.push(bytes[index]);
            index += 1;
            continue;
        }
        index += 1;
        match bytes[index] {
            b'0'..=b'7' => {
                let mut value = (bytes[index] - b'0') as u16;
                index += 1;
                for _ in 0..2 {
                    if index < bytes.len() && (b'0'..=b'7').contains(&bytes[index]) {
                        value = value * 8 + (bytes[index] - b'0') as u16;
                        index += 1;
                    } else {
                        break;
                    }
                }
                out.push((value & 0xff) as u8);
            }
            b'n' => {
                out.push(b'\n');
                index += 1;
            }
            b'r' => {
                out.push(b'\r');
                index += 1;
            }
            b't' => {
                out.push(b'\t');
                index += 1;
            }
            b'"' => {
                out.push(b'"');
                index += 1;
            }
            b'\'' => {
                out.push(b'\'');
                index += 1;
            }
            b'\\' => {
                out.push(b'\\');
                index += 1;
            }
            other => {
                out.push(other);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn nonempty_trimmed(value: &str) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn resolve_lineage<'a>(
    conversation_id: &'a str,
    summaries: &'a HashMap<String, SummaryRecord>,
) -> (&'a str, Option<&'a SummaryRecord>, Option<&'a SummaryRecord>) {
    let own = summaries.get(conversation_id);
    let mut current = conversation_id;
    let mut visited = HashSet::new();
    visited.insert(current);
    for _ in 0..16 {
        let Some(parent) = summaries
            .get(current)
            .and_then(|record| record.parent_conversation_id.as_deref())
            .filter(|parent| !parent.is_empty() && *parent != current)
        else {
            break;
        };
        if !visited.insert(parent) {
            break;
        }
        current = parent;
    }
    let root = summaries.get(current);
    (current, own, root)
}

fn parse_conversation_file(
    path: &Path,
    summaries: &HashMap<String, SummaryRecord>,
) -> Vec<UnifiedMessage> {
    let mut connection = match open_readonly_or_sandbox_immutable(path) {
        Ok(connection) => connection,
        Err(_) => return Vec::new(),
    };
    let steps = match read_steps(&connection) {
        Ok(steps) => steps,
        Err(_) => {
            let probe_err = connection
                .prepare("SELECT 1 FROM sqlite_master LIMIT 1")
                .err();
            if !probe_err.as_ref().is_some_and(is_shm_access_error) {
                return Vec::new();
            }
            let Ok(fallback) = open_immutable(path) else {
                return Vec::new();
            };
            let Ok(steps) = read_steps(&fallback) else {
                return Vec::new();
            };
            connection = fallback;
            steps
        }
    };
    let metadata = read_conversation_metadata(&connection, path, summaries);
    let models = read_model_names(&connection);
    build_messages(&metadata, &steps, &models)
}

fn read_conversation_metadata(
    connection: &Connection,
    path: &Path,
    summaries: &HashMap<String, SummaryRecord>,
) -> ConversationMetadata {
    let conversation_id = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("unknown")
        .to_string();
    let (root_id, own_summary, root_summary) = resolve_lineage(&conversation_id, summaries);
    let is_subagent = root_id != conversation_id;
    let agent_name = if is_subagent {
        own_summary
            .and_then(|record| record.agent_name.clone())
            .or_else(|| Some("subagent".to_string()))
    } else {
        None
    };
    let blob = connection
        .prepare("SELECT data FROM trajectory_metadata_blob")
        .ok()
        .and_then(|mut statement| {
            statement
                .query_map([], |row| row.get::<_, Vec<u8>>(0))
                .ok()?
                .filter_map(Result::ok)
                .next()
        })
        .unwrap_or_default();
    let workspace_key = proto::string(&blob, &[7])
        .or_else(|| proto::string(&blob, &[1, 1]))
        .and_then(strip_file_scheme)
        .and_then(|value| normalize_workspace_key(&value))
        .or_else(|| own_summary.and_then(|record| record.workspace_key.clone()))
        .or_else(|| {
            is_subagent
                .then(|| root_summary.and_then(|record| record.workspace_key.clone()))
                .flatten()
        });
    let workspace_label = workspace_key.as_deref().and_then(workspace_label_from_key);
    ConversationMetadata {
        root_conversation_id: root_id.to_string(),
        conversation_id,
        is_subagent,
        agent_name,
        workspace_key,
        workspace_label,
    }
}

fn strip_file_scheme(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    let path = trimmed.strip_prefix("file://").unwrap_or(trimmed);
    (!path.is_empty()).then(|| path.to_string())
}

fn read_steps(connection: &Connection) -> Result<Vec<StepRecord>, String> {
    let mut statement = connection
        .prepare("SELECT idx, step_type, metadata, step_payload FROM steps ORDER BY idx")
        .map_err(|error| format!("could not read Antigravity steps: {error}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, Option<Vec<u8>>>(2)?,
                row.get::<_, Option<Vec<u8>>>(3)?,
            ))
        })
        .map_err(|error| format!("could not read Antigravity steps: {error}"))?;

    let mut steps = Vec::new();
    for row in rows.filter_map(Result::ok) {
        let (index, step_type, metadata, payload) = row;
        let metadata = metadata.unwrap_or_default();
        let payload = payload.unwrap_or_default();
        steps.push(StepRecord {
            index,
            step_type,
            started_at_ms: proto::timestamp_ms(&metadata, &[META_STARTED_AT]),
            first_token_at_ms: proto::timestamp_ms(&metadata, &[META_FIRST_TOKEN_AT]),
            finished_at_ms: proto::timestamp_ms(&metadata, &[META_FINISHED_AT]),
            model_key: proto::varint(&metadata, &[META_MODEL_KEY]).or_else(|| {
                proto::varint(&metadata, &[META_USAGE, USAGE_MODEL_KEY])
            }),
            usage: read_usage(&metadata),
            is_model_response: step_type == STEP_TYPE_MODEL_RESPONSE,
            prompt: read_prompt(step_type, &payload),
            output: read_output(step_type, &payload),
        });
    }
    Ok(steps)
}

fn read_usage(metadata: &[u8]) -> Option<TokenBreakdown> {
    let usage = proto::message(metadata, &[META_USAGE])
        .or_else(|| proto::message(metadata, &[META_TITLE_USAGE, 2]))?;
    let input = proto::integer(usage, &[USAGE_INPUT]).unwrap_or_default().max(0);
    let cache_read = proto::integer(usage, &[USAGE_CACHE_READ])
        .unwrap_or_default()
        .max(0);
    let reasoning = proto::integer(usage, &[USAGE_REASONING])
        .unwrap_or_default()
        .max(0);
    let output_total = proto::integer(usage, &[USAGE_OUTPUT_TOTAL])
        .unwrap_or_default()
        .max(0);
    // `USAGE_OUTPUT_TEXT` counts only the visible answer, so fall back to the
    // reported total minus reasoning when Antigravity omits it.
    let output = proto::integer(usage, &[USAGE_OUTPUT_TEXT])
        .filter(|value| *value >= 0)
        .unwrap_or_else(|| output_total.saturating_sub(reasoning))
        .max(0);
    let tokens = TokenBreakdown {
        input,
        output,
        cache_read,
        cache_write: 0,
        reasoning,
    };
    (tokens.total() > 0).then_some(tokens)
}

fn read_prompt(step_type: i64, payload: &[u8]) -> Option<String> {
    let text = match step_type {
        STEP_TYPE_USER_MESSAGE => proto::string(payload, &[PAYLOAD_USER_MESSAGE, 2])
            .or_else(|| proto::string(payload, &[PAYLOAD_USER_MESSAGE, 3, 1])),
        STEP_TYPE_CONVERSATION_START => {
            proto::string(payload, &[PAYLOAD_CONVERSATION_START, 19])
        }
        _ => None,
    }?;
    Some(text.to_string())
}

fn read_output(step_type: i64, payload: &[u8]) -> Option<String> {
    if step_type != STEP_TYPE_MODEL_RESPONSE {
        return None;
    }
    let response = proto::message(payload, &[PAYLOAD_MODEL_RESPONSE])?;
    let text = proto::string(response, &[8]).or_else(|| proto::string(response, &[3]))?;
    Some(text.to_string())
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct ModelDescriptor {
    model_id: String,
    reasoning_effort: Option<String>,
}

/// Maps Antigravity's numeric model key to the model name and reasoning effort
/// recorded alongside each generation.
fn read_model_names(connection: &Connection) -> HashMap<u64, ModelDescriptor> {
    let mut names = HashMap::new();
    let Ok(mut statement) = connection.prepare("SELECT data FROM gen_metadata") else {
        return names;
    };
    let Ok(rows) = statement.query_map([], |row| row.get::<_, Vec<u8>>(0)) else {
        return names;
    };
    for blob in rows.filter_map(Result::ok) {
        let Some(generation) = proto::message(&blob, &[1]) else {
            continue;
        };
        let Some(model) = proto::string(generation, &[19]) else {
            continue;
        };
        let display_name = proto::string(generation, &[21]);
        let key = proto::varint(generation, &[4, USAGE_MODEL_KEY])
            .or_else(|| proto::varint(generation, &[3]));
        if let Some(key) = key {
            names
                .entry(key)
                .or_insert_with(|| parse_generation_model(model, display_name));
        }
    }
    names
}

fn parse_generation_model(raw_model: &str, display_name: Option<&str>) -> ModelDescriptor {
    let reasoning_effort = display_name
        .and_then(reasoning_effort_from_model)
        .or_else(|| reasoning_effort_from_model(raw_model))
        .or_else(|| match raw_model.trim().to_ascii_lowercase().as_str() {
            "gemini-4-argon-d" | "gemini-3.8-flash-n" => Some("high".to_string()),
            _ => None,
        });
    let model_id = normalize_antigravity_model_id(raw_model, display_name);
    ModelDescriptor {
        model_id,
        reasoning_effort,
    }
}

fn normalize_antigravity_model_id(raw_model: &str, display_name: Option<&str>) -> String {
    let trimmed = raw_model.trim();
    let lower = trimmed.to_ascii_lowercase();
    match lower.as_str() {
        "gemini-4-argon-d" => return "gemini-4-argon".to_string(),
        "gemini-3.8-flash-n" => return "gemini-3.8-flash".to_string(),
        _ => {}
    }
    if let Some(display) = display_name {
        if reasoning_effort_from_model(display).is_some() {
            if let Some((base_label, _)) = display
                .trim()
                .strip_suffix(')')
                .and_then(|value| value.rsplit_once('('))
            {
                let slug = base_label
                    .split_whitespace()
                    .map(|word| word.to_ascii_lowercase())
                    .collect::<Vec<_>>()
                    .join("-");
                if !slug.is_empty() && lower.starts_with(&format!("{slug}-")) {
                    return slug;
                }
            }
        }
    }
    normalize_model_for_grouping(trimmed)
}

fn build_messages(
    metadata: &ConversationMetadata,
    steps: &[StepRecord],
    models: &HashMap<u64, ModelDescriptor>,
) -> Vec<UnifiedMessage> {
    let mut messages = Vec::new();
    let mut pending_prompt: Option<String> = None;
    let mut turn_started_at_ms: Option<i64> = None;
    let mut awaiting_turn_start = false;

    for step in steps {
        if let Some(prompt) = step.prompt.as_deref() {
            // A conversation opens with the same text on both the user step and
            // the title step; keep the first one so the turn is not restarted.
            if step.step_type == STEP_TYPE_USER_MESSAGE || pending_prompt.is_none() {
                pending_prompt = Some(prompt.to_string());
                turn_started_at_ms = step.started_at_ms;
                awaiting_turn_start = true;
            }
        }
        let Some(tokens) = step.usage.clone() else {
            continue;
        };
        let Some(timestamp) = step.finished_at_ms.or(step.started_at_ms) else {
            continue;
        };
        let descriptor = resolve_model(step, models);
        // Antigravity stores no context window, so only the prompt total is
        // known here; capacity is resolved from the pricing catalog.
        let prompt_tokens = tokens
            .input
            .max(0)
            .saturating_add(tokens.cache_read.max(0))
            .saturating_add(tokens.cache_write.max(0));
        let mut message = UnifiedMessage::new_with_agent(
            "antigravity",
            descriptor.model_id.clone(),
            provider_for_model(&descriptor.model_id),
            metadata.root_conversation_id.clone(),
            timestamp,
            tokens,
            0.0,
            metadata.agent_name.clone(),
        );
        message.reasoning_effort = descriptor.reasoning_effort;
        message.prompt_tokens = Some(prompt_tokens);
        message.physical_session_id = Some(metadata.conversation_id.clone());
        message.is_subagent = metadata.is_subagent;
        message.set_workspace(
            metadata.workspace_key.clone(),
            metadata.workspace_label.clone(),
        );
        message.model_duration_ms = step
            .started_at_ms
            .and_then(|started| step.finished_at_ms.map(|ended| ended - started))
            .filter(|duration| *duration > 0);
        message.time_to_first_token_ms = step
            .started_at_ms
            .and_then(|started| step.first_token_at_ms.map(|first| first - started))
            .filter(|duration| *duration >= 0);
        message.dedup_key = Some(format!(
            "antigravity:{}:{}",
            metadata.conversation_id, step.index
        ));
        message.set_output_preview(
            step.output
                .as_deref()
                .and_then(content_preview_from_str),
        );
        if awaiting_turn_start && step.is_model_response {
            message.is_turn_start = true;
            message.duration_ms = turn_started_at_ms
                .map(|started| timestamp - started)
                .filter(|duration| *duration > 0);
            message.set_content_preview(
                pending_prompt
                    .as_deref()
                    .and_then(content_preview_from_str),
            );
            awaiting_turn_start = false;
        }
        messages.push(message);
    }
    messages
}

/// Antigravity records no model key on its own title and summary requests. A
/// conversation is pinned to one model in practice, so fall back to that model
/// and only report `unknown` when the conversation used several.
fn resolve_model(step: &StepRecord, models: &HashMap<u64, ModelDescriptor>) -> ModelDescriptor {
    if let Some(model) = step.model_key.and_then(|key| models.get(&key)) {
        return model.clone();
    }
    let mut distinct_ids = models
        .values()
        .map(|entry| entry.model_id.as_str())
        .collect::<Vec<_>>();
    distinct_ids.sort();
    distinct_ids.dedup();
    match distinct_ids.as_slice() {
        [model_id] => {
            let mut distinct_efforts = models
                .values()
                .map(|entry| entry.reasoning_effort.as_deref())
                .collect::<Vec<_>>();
            distinct_efforts.sort();
            distinct_efforts.dedup();
            let reasoning_effort = match distinct_efforts.as_slice() {
                [Some(effort)] => Some((*effort).to_string()),
                _ => None,
            };
            ModelDescriptor {
                model_id: (*model_id).to_string(),
                reasoning_effort,
            }
        }
        _ => ModelDescriptor {
            model_id: "unknown".to_string(),
            reasoning_effort: None,
        },
    }
}

fn provider_for_model(model_id: &str) -> &'static str {
    if model_id.to_ascii_lowercase().starts_with("claude") {
        "anthropic"
    } else {
        "google"
    }
}
