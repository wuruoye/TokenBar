//! Independent context workbench: the same nine cards as dsh-context,
//! filled from dsh's own projection when present and reconstructed from
//! other agents' local logs otherwise.

use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

const CHARS_PER_TOKEN: i64 = 4;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WorkbenchListItem {
    pub platform: String,
    pub id: String,
    pub title: Option<String>,
    pub cwd: Option<String>,
    pub last_prompt_at: Option<i64>,
    pub prompt_tokens: i64,
    pub context_window: Option<i64>,
    pub percent: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WorkbenchIndex {
    pub sessions: Vec<WorkbenchListItem>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Composition {
    pub system: i64,
    pub tools: i64,
    pub user: i64,
    pub inject: i64,
    pub assistant: i64,
    pub tool: i64,
    pub prompt_tokens: i64,
    pub context_window: Option<i64>,
    pub percent: Option<f64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WorkbenchStats {
    pub turns: i64,
    pub steps: i64,
    pub human_inputs: i64,
    pub tool_calls: i64,
    pub cache_hit: Option<f64>,
    pub cost_usd: Option<f64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WorkbenchTokens {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub reasoning: i64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WorkbenchTiming {
    pub wall_ms: i64,
    pub ttft_ms: i64,
    pub gen_ms: i64,
    pub tools_ms: i64,
    pub other_ms: i64,
    pub calls: i64,
    pub tool_calls: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TrendBar {
    pub time: i64,
    pub turn: i64,
    pub step: i64,
    pub system: i64,
    pub tools: i64,
    pub user: i64,
    pub inject: i64,
    pub assistant: i64,
    pub tool: i64,
    pub total: i64,
    pub prompt: i64,
    pub output: i64,
    pub cache_read: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BrowserRow {
    pub seq: i64,
    pub time: i64,
    pub cat: String,
    pub tokens: i64,
    pub text: Option<String>,
    pub tool: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct EventRow {
    pub seq: i64,
    pub time: i64,
    pub kind: String,
    pub tokens: i64,
    pub name: Option<String>,
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FileRow {
    pub path: String,
    pub reads: i64,
    pub writes: i64,
    pub searches: i64,
    pub added: i64,
    pub removed: i64,
    pub last_time: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AgentRow {
    pub id: String,
    pub name: String,
    pub role: String,
    pub prompt_tokens: i64,
    pub context_window: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WorkbenchDocument {
    pub session: WorkbenchListItem,
    pub current: Composition,
    pub stats: WorkbenchStats,
    pub tokens: WorkbenchTokens,
    pub timing: WorkbenchTiming,
    pub trend: Vec<TrendBar>,
    pub browser: Vec<BrowserRow>,
    pub events: Vec<EventRow>,
    pub files: Vec<FileRow>,
    pub agents: Vec<AgentRow>,
    pub source: String,
}

pub fn list_sessions() -> Result<WorkbenchIndex, String> {
    let mut sessions = Vec::new();
    sessions.extend(list_dsh_sessions()?);
    sessions.extend(list_grok_sessions()?);
    sessions.sort_by(|a, b| b.last_prompt_at.cmp(&a.last_prompt_at));
    Ok(WorkbenchIndex { sessions })
}

pub fn show_session(platform: &str, id: &str) -> Result<WorkbenchDocument, String> {
    match platform {
        "dsh" => show_dsh(id),
        "grok" => show_grok(id),
        other => Err(format!("workbench does not load platform {other} yet")),
    }
}

fn home_dir() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn dsh_cache_dir() -> PathBuf {
    home_dir().join(".dsh/storages/session_projcache/sessions")
}

fn grok_root() -> PathBuf {
    std::env::var_os("GROK_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home_dir().join(".grok"))
}

fn list_dsh_sessions() -> Result<Vec<WorkbenchListItem>, String> {
    let dir = dsh_cache_dir();
    let entries = match fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(_) => return Ok(Vec::new()),
    };
    let mut sessions = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        let Ok(root) = serde_json::from_str::<Value>(&text) else {
            continue;
        };
        if let Some(item) = dsh_list_item(&root, path.file_stem().and_then(|s| s.to_str()).unwrap_or("")) {
            if item.prompt_tokens > 0 || item.title.as_deref().is_some_and(|title| !title.is_empty()) {
                sessions.push(item);
            }
        }
    }
    Ok(sessions)
}

fn row<'a>(root: &'a Value, name: &str) -> Option<&'a Value> {
    root.get("record")?.get("rows")?.get(name)?.get("val")
}

fn dsh_list_item(root: &Value, fallback_id: &str) -> Option<WorkbenchListItem> {
    let identity = root.get("record")?.get("identity")?;
    let cwd = identity.get("cwd").and_then(Value::as_str).map(str::to_string);
    let created = identity.get("createdAt").and_then(Value::as_i64);
    let title = row(root, "title").and_then(Value::as_str).map(str::to_string);
    let last = row(root, "sessionListMetadata")
        .and_then(|v| v.get("lastPromptAt"))
        .and_then(Value::as_i64)
        .or(created);
    let pressure = row(root, "contextPressure");
    let prompt_tokens = pressure
        .and_then(|v| v.get("surfaceTokens").or_else(|| v.get("pressureTokens")))
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let context_window = pressure
        .and_then(|v| v.get("contextWindow"))
        .and_then(Value::as_i64)
        .filter(|v| *v > 0);
    let percent = context_window.map(|window| {
        (prompt_tokens as f64 / window as f64 * 100.0).clamp(0.0, 100.0)
    });
    Some(WorkbenchListItem {
        platform: "dsh".into(),
        id: fallback_id.to_string(),
        title,
        cwd,
        last_prompt_at: last,
        prompt_tokens,
        context_window,
        percent,
    })
}

fn show_dsh(id: &str) -> Result<WorkbenchDocument, String> {
    let path = dsh_cache_dir().join(format!("{id}.json"));
    let text = fs::read_to_string(&path).map_err(|e| format!("could not read {id}: {e}"))?;
    let root: Value = serde_json::from_str(&text).map_err(|e| format!("invalid dsh cache: {e}"))?;
    let session = dsh_list_item(&root, id).ok_or("dsh session is missing identity")?;
    let timeline = row(&root, "contextTimeline").cloned().unwrap_or(Value::Null);
    let stats_row = row(&root, "sessionStats").cloned().unwrap_or(Value::Null);
    let cost = row(&root, "costUsage").cloned().unwrap_or(Value::Null);
    let current = composition_from_timeline(&timeline, session.context_window);
    let stats = WorkbenchStats {
        turns: int(&stats_row, "turns"),
        steps: int(&stats_row, "steps"),
        human_inputs: int(&timeline, "humanInputs"),
        tool_calls: timeline
            .get("timing")
            .and_then(|t| t.get("toolCalls"))
            .and_then(Value::as_i64)
            .unwrap_or(0),
        cache_hit: cache_hit_from_tokens(&tokens_from_cost(&cost)),
        cost_usd: cost
            .get("totals")
            .and_then(|t| t.get("cost"))
            .and_then(Value::as_f64),
    };
    let tokens = tokens_from_cost(&cost);
    let timing = timing_from_timeline(&timeline);
    let trend = trend_from_timeline(&timeline);
    let browser = browser_from_timeline(&timeline);
    let events = events_from_timeline(&timeline);
    let files = files_from_timeline(&timeline);
    let agents = agents_from_dsh(&session, &events);
    Ok(WorkbenchDocument {
        session,
        current,
        stats,
        tokens,
        timing,
        trend,
        browser,
        events,
        files,
        agents,
        source: "dsh-projection".into(),
    })
}

fn composition_from_timeline(timeline: &Value, window: Option<i64>) -> Composition {
    let last = timeline
        .get("requests")
        .and_then(Value::as_array)
        .and_then(|rows| rows.last());
    let sums = timeline.get("sums");
    let system = last
        .and_then(|v| v.get("system"))
        .and_then(Value::as_i64)
        .or_else(|| timeline.get("systemTokens").and_then(Value::as_i64))
        .unwrap_or(0);
    let tools = last
        .and_then(|v| v.get("tools"))
        .and_then(Value::as_i64)
        .or_else(|| timeline.get("toolsTokens").and_then(Value::as_i64))
        .unwrap_or(0);
    let user = last
        .and_then(|v| v.get("user"))
        .and_then(Value::as_i64)
        .or_else(|| sums.and_then(|s| s.get("user")).and_then(Value::as_i64))
        .unwrap_or(0);
    let inject = last
        .and_then(|v| v.get("inject"))
        .and_then(Value::as_i64)
        .or_else(|| sums.and_then(|s| s.get("inject")).and_then(Value::as_i64))
        .unwrap_or(0);
    let assistant = last
        .and_then(|v| v.get("assistant"))
        .and_then(Value::as_i64)
        .or_else(|| sums.and_then(|s| s.get("assistant")).and_then(Value::as_i64))
        .unwrap_or(0);
    let tool = last
        .and_then(|v| v.get("tool"))
        .and_then(Value::as_i64)
        .or_else(|| sums.and_then(|s| s.get("tool")).and_then(Value::as_i64))
        .unwrap_or(0);
    let prompt_tokens = last
        .and_then(|v| v.get("total").or_else(|| v.get("prompt")))
        .and_then(Value::as_i64)
        .unwrap_or(system + tools + user + inject + assistant + tool);
    let window = timeline
        .get("contextWindow")
        .and_then(Value::as_i64)
        .filter(|v| *v > 0)
        .or(window);
    Composition {
        system,
        tools,
        user,
        inject,
        assistant,
        tool,
        prompt_tokens,
        context_window: window,
        percent: window.map(|w| (prompt_tokens as f64 / w as f64 * 100.0).clamp(0.0, 100.0)),
    }
}

fn trend_from_timeline(timeline: &Value) -> Vec<TrendBar> {
    timeline
        .get("requests")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .map(|row| TrendBar {
                    time: int(row, "time"),
                    turn: int(row, "turn"),
                    step: int(row, "step"),
                    system: int(row, "system"),
                    tools: int(row, "tools"),
                    user: int(row, "user"),
                    inject: int(row, "inject"),
                    assistant: int(row, "assistant"),
                    tool: int(row, "tool"),
                    total: int(row, "total"),
                    prompt: int(row, "prompt"),
                    output: int(row, "output"),
                    cache_read: int(row, "cacheRead"),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn browser_from_timeline(timeline: &Value) -> Vec<BrowserRow> {
    timeline
        .get("surface")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .map(|row| BrowserRow {
                    seq: int(row, "seq"),
                    time: int(row, "time"),
                    cat: row
                        .get("cat")
                        .and_then(Value::as_str)
                        .unwrap_or("assistant")
                        .to_string(),
                    tokens: int(row, "tokens"),
                    text: row.get("text").and_then(Value::as_str).map(str::to_string),
                    tool: row.get("tool").and_then(Value::as_str).map(str::to_string),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn events_from_timeline(timeline: &Value) -> Vec<EventRow> {
    timeline
        .get("events")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .map(|row| EventRow {
                    seq: int(row, "seq"),
                    time: int(row, "time"),
                    kind: row
                        .get("kind")
                        .and_then(Value::as_str)
                        .unwrap_or("inject")
                        .to_string(),
                    tokens: int(row, "tokens"),
                    name: row.get("name").and_then(Value::as_str).map(str::to_string),
                    detail: row.get("detail").and_then(Value::as_str).map(str::to_string),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn files_from_timeline(timeline: &Value) -> Vec<FileRow> {
    let mut by_path: BTreeMap<String, FileRow> = BTreeMap::new();
    let Some(ops) = timeline.get("fileOps").and_then(Value::as_array) else {
        return Vec::new();
    };
    for op in ops {
        let path = op
            .get("path")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if path.is_empty() {
            continue;
        }
        let entry = by_path.entry(path.clone()).or_insert(FileRow {
            path,
            reads: 0,
            writes: 0,
            searches: 0,
            added: 0,
            removed: 0,
            last_time: 0,
        });
        match op.get("kind").and_then(Value::as_str) {
            Some("read") => entry.reads += 1,
            Some("write") => entry.writes += 1,
            Some("search") => entry.searches += 1,
            _ => {}
        }
        entry.added += int(op, "added");
        entry.removed += int(op, "removed");
        entry.last_time = entry.last_time.max(int(op, "time"));
    }
    let mut rows: Vec<_> = by_path.into_values().collect();
    rows.sort_by(|a, b| {
        (b.reads + b.writes + b.searches)
            .cmp(&(a.reads + a.writes + a.searches))
            .then_with(|| b.last_time.cmp(&a.last_time))
    });
    rows
}

fn timing_from_timeline(timeline: &Value) -> WorkbenchTiming {
    let timing = timeline.get("timing").cloned().unwrap_or(Value::Null);
    let wall = int(&timing, "wallMs");
    let ttft = int(&timing, "ttftMs");
    let gen = int(&timing, "genMs");
    let tools = int(&timing, "toolsMs");
    WorkbenchTiming {
        wall_ms: wall,
        ttft_ms: ttft,
        gen_ms: gen,
        tools_ms: tools,
        other_ms: (wall - ttft - gen - tools).max(0),
        calls: int(&timing, "calls"),
        tool_calls: int(&timing, "toolCalls"),
    }
}

fn tokens_from_cost(cost: &Value) -> WorkbenchTokens {
    let totals = cost.get("totals").cloned().unwrap_or(Value::Null);
    WorkbenchTokens {
        input: int(&totals, "input"),
        output: int(&totals, "output"),
        cache_read: int(&totals, "cacheRead"),
        cache_write: int(&totals, "cacheWrite"),
        reasoning: int(&totals, "reasoning"),
    }
}

fn cache_hit_from_tokens(tokens: &WorkbenchTokens) -> Option<f64> {
    let prompt = tokens.input + tokens.cache_read + tokens.cache_write;
    (prompt > 0).then_some(tokens.cache_read as f64 / prompt as f64 * 100.0)
}

fn agents_from_dsh(session: &WorkbenchListItem, events: &[EventRow]) -> Vec<AgentRow> {
    let mut agents = vec![AgentRow {
        id: session.id.clone(),
        name: session.title.clone().unwrap_or_else(|| session.id.clone()),
        role: "current".into(),
        prompt_tokens: session.prompt_tokens,
        context_window: session.context_window,
    }];
    let mut seen = std::collections::HashSet::new();
    for event in events {
        if event.name.as_deref() != Some("subagent-settled") {
            continue;
        }
        let Some(detail) = event.detail.as_deref() else {
            continue;
        };
        if let Some(id) = detail.split_whitespace().find(|word| {
            word.len() >= 8 && word.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
        }) {
            if seen.insert(id.to_string()) {
                agents.push(AgentRow {
                    id: id.to_string(),
                    name: id.to_string(),
                    role: "subagent".into(),
                    prompt_tokens: 0,
                    context_window: None,
                });
            }
        }
    }
    agents
}

fn list_grok_sessions() -> Result<Vec<WorkbenchListItem>, String> {
    let root = grok_root().join("sessions");
    let groups = match fs::read_dir(&root) {
        Ok(entries) => entries,
        Err(_) => return Ok(Vec::new()),
    };
    let mut sessions = Vec::new();
    for group in groups.flatten() {
        let group_path = group.path();
        if !group_path.is_dir() {
            continue;
        }
        let children = match fs::read_dir(&group_path) {
            Ok(entries) => entries,
            Err(_) => continue,
        };
        for child in children.flatten() {
            let path = child.path();
            if !path.is_dir() {
                continue;
            }
            let id = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string();
            if id.is_empty() {
                continue;
            }
            let summary = read_json(&path.join("summary.json")).unwrap_or(Value::Null);
            let signals = read_json(&path.join("signals.json")).unwrap_or(Value::Null);
            let title = summary
                .get("generated_title")
                .or_else(|| summary.get("session_summary"))
                .and_then(Value::as_str)
                .map(str::to_string);
            let cwd = summary
                .get("info")
                .and_then(|i| i.get("cwd"))
                .and_then(Value::as_str)
                .map(str::to_string);
            let last = summary
                .get("last_active_at")
                .and_then(Value::as_str)
                .and_then(parse_rfc3339_ms)
                .or_else(|| signals.get("sessionDurationSeconds").and_then(Value::as_i64));
            let prompt_tokens = int(&signals, "contextTokensUsed");
            let context_window = Some(int(&signals, "contextWindowTokens")).filter(|v| *v > 0);
            if prompt_tokens == 0 && title.as_deref().unwrap_or("").is_empty() {
                continue;
            }
            sessions.push(WorkbenchListItem {
                platform: "grok".into(),
                id,
                title,
                cwd,
                last_prompt_at: last,
                prompt_tokens,
                context_window,
                percent: context_window
                    .map(|w| (prompt_tokens as f64 / w as f64 * 100.0).clamp(0.0, 100.0)),
            });
        }
    }
    Ok(sessions)
}

fn show_grok(id: &str) -> Result<WorkbenchDocument, String> {
    let mut session_dir = None;
    let root = grok_root().join("sessions");
    if let Ok(groups) = fs::read_dir(root) {
        for group in groups.flatten() {
            let candidate = group.path().join(id);
            if candidate.is_dir() {
                session_dir = Some(candidate);
                break;
            }
        }
    }
    let dir = session_dir.ok_or_else(|| format!("grok session {id} not found"))?;
    let summary = read_json(&dir.join("summary.json")).unwrap_or(Value::Null);
    let signals = read_json(&dir.join("signals.json")).unwrap_or(Value::Null);
    let list = list_grok_sessions()?
        .into_iter()
        .find(|item| item.id == id)
        .ok_or("grok session missing from index")?;
    let used = int(&signals, "contextTokensUsed");
    let window = Some(int(&signals, "contextWindowTokens")).filter(|v| *v > 0);
    let mut current = Composition {
        prompt_tokens: used,
        context_window: window,
        percent: window.map(|w| (used as f64 / w as f64 * 100.0).clamp(0.0, 100.0)),
        ..Composition::default()
    };
    let (trend, browser, files) = grok_stream(&dir.join("updates.jsonl"), &mut current);
    current.assistant = current.assistant.max(estimate_tokens(
        summary
            .get("last_turn_summary")
            .and_then(Value::as_str)
            .unwrap_or(""),
    ));
    let tokens = WorkbenchTokens {
        input: int(&signals, "contextTokensUsed"),
        output: 0,
        cache_read: 0,
        cache_write: 0,
        reasoning: 0,
    };
    let stats = WorkbenchStats {
        turns: int(&signals, "turnCount"),
        steps: int(&signals, "toolCallCount") + int(&signals, "turnCount"),
        human_inputs: int(&signals, "userMessageCount"),
        tool_calls: int(&signals, "toolCallCount"),
        cache_hit: None,
        cost_usd: None,
    };
    let ttft = int(&signals, "avgTimeToFirstTokenMs") * int(&signals, "latencySampleCount").max(1);
    let wall = int(&signals, "sessionDurationSeconds") * 1000;
    Ok(WorkbenchDocument {
        session: list,
        current,
        stats,
        tokens,
        timing: WorkbenchTiming {
            wall_ms: wall,
            ttft_ms: ttft,
            gen_ms: int(&signals, "avgResponseTimeMs") * int(&signals, "latencySampleCount").max(1),
            tools_ms: 0,
            other_ms: 0,
            calls: int(&signals, "latencySampleCount"),
            tool_calls: int(&signals, "toolCallCount"),
        },
        trend,
        browser,
        events: Vec::new(),
        files,
        agents: vec![AgentRow {
            id: id.to_string(),
            name: summary
                .get("generated_title")
                .and_then(Value::as_str)
                .unwrap_or(id)
                .to_string(),
            role: "current".into(),
            prompt_tokens: used,
            context_window: window,
        }],
        source: "reconstructed".into(),
    })
}

fn grok_stream(path: &Path, current: &mut Composition) -> (Vec<TrendBar>, Vec<BrowserRow>, Vec<FileRow>) {
    let Ok(file) = fs::File::open(path) else {
        return (Vec::new(), Vec::new(), Vec::new());
    };
    let mut trend = Vec::new();
    let mut browser = Vec::new();
    let mut files: BTreeMap<String, FileRow> = BTreeMap::new();
    let mut seq = 0i64;
    let mut turn = 0i64;
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(entry) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let Some(update) = entry
            .pointer("/params/update")
            .or_else(|| entry.get("update"))
        else {
            continue;
        };
        let kind = update
            .get("sessionUpdate")
            .or_else(|| update.get("session_update"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let time = entry
            .get("timestamp")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        if kind == "agent_message_chunk" || kind == "user_message_chunk" {
            if let Some(text) = update
                .pointer("/content/text")
                .and_then(Value::as_str)
                .or_else(|| update.get("content").and_then(Value::as_str))
            {
                let cat = if kind.starts_with("user") {
                    "user"
                } else {
                    "assistant"
                };
                let tokens = estimate_tokens(text);
                match cat {
                    "user" => current.user += tokens,
                    _ => current.assistant += tokens,
                }
                seq += 1;
                browser.push(BrowserRow {
                    seq,
                    time,
                    cat: cat.into(),
                    tokens,
                    text: Some(text.chars().take(4000).collect()),
                    tool: None,
                });
            }
        }
        if kind == "tool_call" || kind == "tool_call_update" {
            let tool = update
                .get("title")
                .or_else(|| update.get("kind"))
                .and_then(Value::as_str)
                .unwrap_or("tool")
                .to_string();
            let path = update
                .pointer("/rawInput/target_file")
                .or_else(|| update.pointer("/rawInput/path"))
                .or_else(|| update.pointer("/rawOutput/path"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            seq += 1;
            let tokens = 40;
            current.tool += tokens;
            browser.push(BrowserRow {
                seq,
                time,
                cat: "tool".into(),
                tokens,
                text: Some(tool.clone()),
                tool: Some(tool.clone()),
            });
            if !path.is_empty() {
                let entry = files.entry(path.clone()).or_insert(FileRow {
                    path,
                    reads: 0,
                    writes: 0,
                    searches: 0,
                    added: 0,
                    removed: 0,
                    last_time: 0,
                });
                if tool.contains("read") {
                    entry.reads += 1;
                } else if tool.contains("write") || tool.contains("edit") || tool.contains("replace") {
                    entry.writes += 1;
                } else if tool.contains("grep") || tool.contains("search") {
                    entry.searches += 1;
                }
                entry.last_time = entry.last_time.max(time);
            }
        }
        if kind == "turn_completed" {
            turn += 1;
            let usage = update.get("usage").cloned().unwrap_or(Value::Null);
            let input = usage
                .pointer("/modelUsage")
                .and_then(Value::as_object)
                .map(|models| {
                    models
                        .values()
                        .map(|row| {
                            int(row, "inputTokens")
                                + int(row, "cachedReadTokens")
                                + int(row, "cacheCreationTokens")
                        })
                        .sum::<i64>()
                })
                .unwrap_or(0);
            trend.push(TrendBar {
                time,
                turn,
                step: turn,
                system: 0,
                tools: 0,
                user: current.user,
                inject: 0,
                assistant: current.assistant,
                tool: current.tool,
                total: input.max(current.user + current.assistant + current.tool),
                prompt: input,
                output: 0,
                cache_read: 0,
            });
        }
    }
    let mut file_rows: Vec<_> = files.into_values().collect();
    file_rows.sort_by(|a, b| (b.reads + b.writes + b.searches).cmp(&(a.reads + a.writes + a.searches)));
    (trend, browser, file_rows)
}

fn estimate_tokens(text: &str) -> i64 {
    let chars = text.chars().count() as i64;
    (chars + CHARS_PER_TOKEN - 1) / CHARS_PER_TOKEN
}

fn int(value: &Value, key: &str) -> i64 {
    value.get(key).and_then(Value::as_i64).unwrap_or(0)
}

fn read_json(path: &Path) -> Option<Value> {
    fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
}

fn parse_rfc3339_ms(value: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|dt| dt.timestamp_millis())
}
