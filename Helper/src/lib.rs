use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

use chrono::{Days, NaiveDate};
use serde::{Deserialize, Serialize};

use crate::usage::{
    normalize_model_for_grouping, CostSource, ServiceTier, TokenCostBreakdown, UnifiedMessage,
};

pub mod codex;
pub mod pricing;
pub mod usage;

pub const SCHEMA_VERSION: u32 = 3;

const CODEX_SYSTEM_INJECTED_PREFIXES: [&str; 3] = [
    "<environment_context>",
    "<system-reminder>",
    "<user_instructions>",
];

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestDetail {
    pub prompt: Option<String>,
    pub output: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenBreakdown {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub reasoning: i64,
}

impl TokenBreakdown {
    fn from_unified(tokens: &crate::usage::TokenBreakdown) -> Self {
        Self {
            input: tokens.input.max(0),
            output: tokens.output.max(0),
            cache_read: tokens.cache_read.max(0),
            cache_write: tokens.cache_write.max(0),
            reasoning: tokens.reasoning.max(0),
        }
    }

    fn total(&self) -> i64 {
        self.input
            .saturating_add(self.output)
            .saturating_add(self.cache_read)
            .saturating_add(self.cache_write)
            .saturating_add(self.reasoning)
    }

    fn add_assign(&mut self, other: &Self) {
        self.input = self.input.saturating_add(other.input);
        self.output = self.output.saturating_add(other.output);
        self.cache_read = self.cache_read.saturating_add(other.cache_read);
        self.cache_write = self.cache_write.saturating_add(other.cache_write);
        self.reasoning = self.reasoning.saturating_add(other.reasoning);
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActivityCostSource {
    #[default]
    Unknown,
    ProviderReported,
    Estimated,
}

impl From<CostSource> for ActivityCostSource {
    fn from(source: CostSource) -> Self {
        match source {
            CostSource::Unknown => Self::Unknown,
            CostSource::ProviderReported => Self::ProviderReported,
            CostSource::Estimated => Self::Estimated,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActivityServiceTier {
    #[default]
    Unknown,
    Standard,
    Fast,
    Mixed,
}

impl From<ServiceTier> for ActivityServiceTier {
    fn from(tier: ServiceTier) -> Self {
        match tier {
            ServiceTier::Unknown => Self::Unknown,
            ServiceTier::Standard => Self::Standard,
            ServiceTier::Fast => Self::Fast,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestSummary {
    pub id: String,
    pub session_id: String,
    pub physical_session_id: String,
    pub is_subagent: bool,
    pub agent: Option<String>,
    pub model: String,
    pub provider: String,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub duration_ms: Option<i64>,
    pub tokens: TokenBreakdown,
    pub cost_usd: f64,
    pub cost_source: ActivityCostSource,
    #[serde(default)]
    pub service_tier: ActivityServiceTier,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_path: Option<String>,
    pub prompt_preview: Option<String>,
    pub output_preview: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub contributions: Vec<RequestSummary>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub workspace_label: Option<String>,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub tokens: TokenBreakdown,
    pub cost_usd: f64,
    pub models: Vec<String>,
    pub requests: Vec<RequestSummary>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityTotals {
    pub tokens: TokenBreakdown,
    pub cost_usd: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_costs: Option<TokenCostBreakdown>,
    pub request_count: usize,
    pub session_count: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityRangeSummary {
    pub started_at_ms: i64,
    pub totals: ActivityTotals,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DailyModelSummary {
    pub model: String,
    pub provider: String,
    pub tokens: TokenBreakdown,
    pub cost_usd: f64,
    pub request_count: usize,
    pub session_count: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DailySummary {
    pub date: String,
    pub tokens: TokenBreakdown,
    pub cost_usd: f64,
    pub request_count: usize,
    pub session_count: usize,
    #[serde(default)]
    pub models: Vec<DailyModelSummary>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivitySnapshot {
    pub schema_version: u32,
    pub generated_at_ms: i64,
    pub timezone: String,
    pub today: ActivityTotals,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weekly_since_reset: Option<ActivityRangeSummary>,
    pub sessions: Vec<SessionSummary>,
    pub days: Vec<DailySummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct RequestKey {
    date: NaiveDate,
    source: String,
    provider: String,
    model: String,
    session_id: String,
    physical_session_id: String,
    agent: Option<String>,
}

#[derive(Debug, Clone)]
struct RequestRow {
    date: NaiveDate,
    timestamp: i64,
    source: String,
    provider: String,
    model: String,
    session_id: String,
    physical_session_id: String,
    is_subagent: bool,
    workspace_label: Option<String>,
    agent: Option<String>,
    session_path: Option<String>,
    prompt_preview: Option<String>,
    output_preview: Option<String>,
    tokens: TokenBreakdown,
    cost: f64,
    token_costs: Option<TokenCostBreakdown>,
    cost_source: ActivityCostSource,
    service_tier: ActivityServiceTier,
    duration_ms: Option<i64>,
    request_start_timestamp: Option<i64>,
    request_end_timestamp: i64,
    is_turn_start: bool,
}

#[derive(Debug, Clone)]
struct TurnRow {
    id: String,
    anchor: RequestRow,
    contributions: Vec<RequestRow>,
}

impl RequestRow {
    fn key(&self) -> RequestKey {
        RequestKey {
            date: self.date,
            source: self.source.clone(),
            provider: self.provider.clone(),
            model: self.model.clone(),
            session_id: self.session_id.clone(),
            physical_session_id: self.physical_session_id.clone(),
            agent: self.agent.clone(),
        }
    }

    fn started_at_ms(&self) -> i64 {
        self.request_start_timestamp.unwrap_or(self.timestamp)
    }
}

#[derive(Default)]
struct DailyAccumulator {
    tokens: TokenBreakdown,
    cost: f64,
    token_costs: OptionalTokenCostAccumulator,
    turn_ids: HashSet<String>,
    session_ids: HashSet<String>,
    models: BTreeMap<(String, String), DailyModelAccumulator>,
}

#[derive(Default)]
struct OptionalTokenCostAccumulator {
    costs: TokenCostBreakdown,
    saw_request: bool,
    is_complete: bool,
}

impl OptionalTokenCostAccumulator {
    fn add(&mut self, costs: Option<&TokenCostBreakdown>) {
        if !self.saw_request {
            self.saw_request = true;
            self.is_complete = true;
        }
        if let Some(costs) = costs {
            self.costs.add_assign(costs);
        } else {
            self.is_complete = false;
        }
    }

    fn complete_costs(&self) -> Option<TokenCostBreakdown> {
        (self.saw_request && self.is_complete).then_some(self.costs)
    }
}

#[derive(Default)]
struct DailyModelAccumulator {
    tokens: TokenBreakdown,
    cost: f64,
    turn_ids: HashSet<String>,
    session_ids: HashSet<String>,
}

/// Reads the unabridged prompt and assistant messages for one Codex request.
///
/// Entries outside the inclusive millisecond range are ignored. Assistant
/// messages are kept in transcript order and separated by one blank line. The
/// original message text is otherwise unchanged, including embedded newlines.
pub fn extract_request_detail(
    session_path: &Path,
    start_ms: i64,
    end_ms: i64,
) -> Result<RequestDetail, String> {
    if start_ms > end_ms {
        return Err("request start must not be after request end".to_string());
    }

    let file = File::open(session_path).map_err(|error| {
        format!(
            "could not open Codex session {}: {error}",
            session_path.display()
        )
    })?;
    extract_request_detail_from_reader(BufReader::new(file), start_ms, end_ms)
}

fn extract_request_detail_from_reader<R: BufRead>(
    reader: R,
    start_ms: i64,
    end_ms: i64,
) -> Result<RequestDetail, String> {
    let mut prompts = Vec::new();
    let mut outputs = Vec::new();

    for line in reader.lines() {
        let line = line.map_err(|error| format!("could not read Codex session: {error}"))?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let Ok(entry) = serde_json::from_str::<serde_json::Value>(trimmed) else {
            continue;
        };
        let Some(timestamp_ms) = codex_entry_timestamp_ms(&entry) else {
            continue;
        };
        if timestamp_ms > end_ms {
            break;
        }
        if timestamp_ms < start_ms {
            continue;
        }

        if let Some(message) = codex_event_message(&entry, "user_message") {
            if !message.trim().is_empty() && codex_message_is_human_turn(message) {
                prompts.push(message.to_string());
            }
        } else if let Some(message) = codex_event_message(&entry, "agent_message") {
            if !message.trim().is_empty() {
                outputs.push(message.to_string());
            }
        }
    }

    Ok(RequestDetail {
        prompt: (!prompts.is_empty()).then(|| prompts.join("\n\n")),
        output: (!outputs.is_empty()).then(|| outputs.join("\n\n")),
    })
}

fn codex_entry_timestamp_ms(entry: &serde_json::Value) -> Option<i64> {
    let timestamp = entry.get("timestamp")?;
    if let Some(value) = timestamp.as_i64() {
        return Some(value);
    }
    chrono::DateTime::parse_from_rfc3339(timestamp.as_str()?)
        .ok()
        .map(|value| value.timestamp_millis())
}

fn codex_event_message<'a>(entry: &'a serde_json::Value, expected_type: &str) -> Option<&'a str> {
    if entry.get("type")?.as_str()? != "event_msg" {
        return None;
    }
    let payload = entry.get("payload")?;
    if payload.get("type")?.as_str()? != expected_type {
        return None;
    }
    payload.get("message")?.as_str()
}

fn codex_message_is_human_turn(message: &str) -> bool {
    let trimmed = message.trim_start();
    !CODEX_SYSTEM_INJECTED_PREFIXES
        .iter()
        .any(|prefix| trimmed.starts_with(prefix))
}

/// Normalizes Codex's reasoning breakdown before TokenBar aggregates it.
///
/// Codex reports `reasoning_output_tokens` as a subset of `output_tokens`, while
/// Tokscale's generic pricing contract treats `output` and `reasoning` as
/// disjoint buckets. Repricing the corrected message keeps the shared parser
/// untouched while preventing TokenBar from counting reasoning twice.
pub fn normalize_codex_reasoning_usage(
    messages: &mut [UnifiedMessage],
    mut recalculate_estimated_cost: impl FnMut(&UnifiedMessage) -> Option<TokenCostBreakdown>,
) {
    for message in messages {
        if message.client != "codex" {
            continue;
        }

        let reasoning = message.tokens.reasoning.max(0);
        if reasoning == 0 {
            continue;
        }

        let original_output = message.tokens.output;
        if reasoning > original_output {
            // An inconsistent breakdown cannot be converted into disjoint
            // buckets without inventing token counts. Preserve it verbatim.
            continue;
        }
        message.tokens.output = original_output - reasoning;

        if message.cost_source != CostSource::Estimated {
            continue;
        }

        let Some(token_costs) = recalculate_estimated_cost(message).filter(|costs| {
            let total = costs.total();
            total.is_finite() && total >= 0.0 && (total > 0.0 || message.cost == 0.0)
        }) else {
            // Keep the previous cost and token contract together if the same
            // cached pricing dataset cannot reproduce an estimated cost.
            message.tokens.output = original_output;
            continue;
        };
        message.cost = token_costs.total();
        message.token_costs = Some(token_costs);
    }
}

/// Resolves Codex App/CLI thread names to TokenBar's logical session ids.
///
/// `session_index.jsonl` is keyed by the upstream UUID stored in each rollout's
/// `session_meta`, while Tokscale exposes the rollout file stem as the logical
/// root id. Only a root rollout can name the grouped session; subagent rollouts
/// keep their own upstream ids and must not replace the parent title.
pub fn load_codex_session_titles(
    messages: &[UnifiedMessage],
    session_index_path: &Path,
) -> HashMap<String, String> {
    let titles_by_upstream = read_codex_title_index(session_index_path);
    if titles_by_upstream.is_empty() {
        return HashMap::new();
    }

    let mut seen_paths = HashSet::new();
    let mut titles_by_session = HashMap::new();
    for message in messages {
        if message.client != "codex" {
            continue;
        }

        let Some(path) = message.session_path.as_deref() else {
            continue;
        };
        if physical_session_id(message) != message.session_id || !seen_paths.insert(path) {
            continue;
        }

        let Some(upstream_id) = read_codex_upstream_session_id(Path::new(path)) else {
            continue;
        };
        if let Some(title) = titles_by_upstream.get(&upstream_id) {
            titles_by_session.insert(message.session_id.clone(), title.clone());
        }
    }

    titles_by_session
}

fn read_codex_title_index(path: &Path) -> HashMap<String, String> {
    let Some(reader) = File::open(path).ok().map(BufReader::new) else {
        return HashMap::new();
    };
    let mut titles = HashMap::new();
    for line in reader.lines().map_while(Result::ok) {
        let Ok(entry) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        let (Some(id), Some(title)) = (
            entry.get("id").and_then(serde_json::Value::as_str),
            entry.get("thread_name").and_then(serde_json::Value::as_str),
        ) else {
            continue;
        };
        let title = title.trim();
        if !id.is_empty() && !title.is_empty() {
            // The index is append-oriented; a later row represents a rename.
            titles.insert(id.to_string(), title.to_string());
        }
    }
    titles
}

fn read_codex_upstream_session_id(path: &Path) -> Option<String> {
    let reader = BufReader::new(File::open(path).ok()?);
    for line in reader.lines().map_while(Result::ok).take(64) {
        let Ok(entry) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        if entry.get("type").and_then(serde_json::Value::as_str) != Some("session_meta") {
            continue;
        }
        return entry
            .get("payload")?
            .get("id")?
            .as_str()
            .map(str::to_string)
            .filter(|id| !id.is_empty());
    }
    None
}

/// Builds the JSON contract consumed by TokenBar's Swift core.
///
/// `messages` may contain a wider range than requested; this function applies the
/// range again so callers and tests get the same deterministic boundary behavior.
pub fn build_snapshot(
    messages: Vec<UnifiedMessage>,
    today: NaiveDate,
    generated_at_ms: i64,
    timezone: String,
    day_count: usize,
) -> Result<ActivitySnapshot, String> {
    build_snapshot_with_session_titles(
        messages,
        today,
        generated_at_ms,
        timezone,
        day_count,
        &HashMap::new(),
        None,
    )
}

pub fn build_snapshot_with_session_titles(
    messages: Vec<UnifiedMessage>,
    today: NaiveDate,
    generated_at_ms: i64,
    timezone: String,
    day_count: usize,
    session_titles: &HashMap<String, String>,
    weekly_reset_at_ms: Option<i64>,
) -> Result<ActivitySnapshot, String> {
    if day_count == 0 {
        return Err("day count must be greater than zero".to_string());
    }

    let first_day = today
        .checked_sub_days(Days::new((day_count - 1) as u64))
        .ok_or_else(|| "day range is too large".to_string())?;

    let rows = messages
        .into_iter()
        .filter_map(request_row)
        .filter(|row| {
            row.timestamp <= generated_at_ms
                && row.date <= today
                && (row.date >= first_day
                    || weekly_reset_at_ms
                        .map(|started_at_ms| row.timestamp >= started_at_ms)
                        .unwrap_or(false))
        })
        .collect::<Vec<_>>();
    let weekly_since_reset = weekly_reset_at_ms
        .filter(|started_at_ms| *started_at_ms <= generated_at_ms)
        .map(|started_at_ms| {
            let weekly_turns = aggregate_requests(
                rows.iter()
                    .filter(|row| {
                        row.timestamp >= started_at_ms && row.timestamp <= generated_at_ms
                    })
                    .cloned()
                    .collect(),
            );
            ActivityRangeSummary {
                started_at_ms,
                totals: activity_totals(&weekly_turns, |_| true),
            }
        });
    let turns = aggregate_requests(rows);

    let mut daily: BTreeMap<NaiveDate, DailyAccumulator> = BTreeMap::new();
    for turn in &turns {
        for request in &turn.contributions {
            let entry = daily.entry(request.date).or_default();
            entry.tokens.add_assign(&request.tokens);
            entry.cost = add_cost(entry.cost, request.cost);
            entry.token_costs.add(request.token_costs.as_ref());
            entry.turn_ids.insert(turn.id.clone());
            entry.session_ids.insert(request.session_id.clone());

            let model = entry
                .models
                .entry((request.provider.clone(), request.model.clone()))
                .or_default();
            model.tokens.add_assign(&request.tokens);
            model.cost = add_cost(model.cost, request.cost);
            model.turn_ids.insert(turn.id.clone());
            model.session_ids.insert(request.session_id.clone());
        }
    }

    let today_totals = daily
        .get(&today)
        .map(|entry| ActivityTotals {
            tokens: entry.tokens.clone(),
            cost_usd: entry.cost,
            token_costs: entry.token_costs.complete_costs(),
            request_count: entry.turn_ids.len(),
            session_count: entry.session_ids.len(),
        })
        .unwrap_or_default();

    let mut days = Vec::with_capacity(day_count);
    for offset in 0..day_count {
        let date = first_day
            .checked_add_days(Days::new(offset as u64))
            .ok_or_else(|| "day range is too large".to_string())?;
        let entry = daily.get(&date);
        let mut models = entry
            .map(|value| {
                value
                    .models
                    .iter()
                    .map(|((provider, model), usage)| DailyModelSummary {
                        model: model.clone(),
                        provider: provider.clone(),
                        tokens: usage.tokens.clone(),
                        cost_usd: usage.cost,
                        request_count: usage.turn_ids.len(),
                        session_count: usage.session_ids.len(),
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        models.sort_by(|left, right| {
            right
                .tokens
                .total()
                .cmp(&left.tokens.total())
                .then_with(|| right.cost_usd.total_cmp(&left.cost_usd))
                .then_with(|| left.provider.cmp(&right.provider))
                .then_with(|| left.model.cmp(&right.model))
        });
        days.push(DailySummary {
            date: date.format("%Y-%m-%d").to_string(),
            tokens: entry.map(|value| value.tokens.clone()).unwrap_or_default(),
            cost_usd: entry.map(|value| value.cost).unwrap_or(0.0),
            request_count: entry.map(|value| value.turn_ids.len()).unwrap_or(0),
            session_count: entry.map(|value| value.session_ids.len()).unwrap_or(0),
            models,
        });
    }

    let sessions = build_today_sessions(turns, today, session_titles);

    Ok(ActivitySnapshot {
        schema_version: SCHEMA_VERSION,
        generated_at_ms,
        timezone,
        today: today_totals,
        weekly_since_reset,
        sessions,
        days,
    })
}

fn activity_totals(turns: &[TurnRow], include: impl Fn(&RequestRow) -> bool) -> ActivityTotals {
    let mut tokens = TokenBreakdown::default();
    let mut cost_usd = 0.0;
    let mut token_costs = OptionalTokenCostAccumulator::default();
    let mut session_ids = HashSet::new();
    let mut turn_count = 0_usize;
    for turn in turns {
        let mut included_turn = false;
        for request in turn.contributions.iter().filter(|request| include(request)) {
            tokens.add_assign(&request.tokens);
            cost_usd = add_cost(cost_usd, request.cost);
            token_costs.add(request.token_costs.as_ref());
            session_ids.insert(request.session_id.clone());
            included_turn = true;
        }
        if included_turn {
            turn_count = turn_count.saturating_add(1);
        }
    }
    ActivityTotals {
        tokens,
        cost_usd,
        token_costs: token_costs.complete_costs(),
        request_count: turn_count,
        session_count: session_ids.len(),
    }
}

fn request_row(message: UnifiedMessage) -> Option<RequestRow> {
    let date = NaiveDate::parse_from_str(&message.date, "%Y-%m-%d").ok()?;
    let tokens = TokenBreakdown::from_unified(&message.tokens);
    let cost = valid_cost(message.cost);
    if tokens.total() == 0 && cost == 0.0 {
        return None;
    }

    let model = normalize_model_for_grouping(&message.model_id);
    let physical_session_id = physical_session_id(&message);
    let is_subagent = message.client == "codex" && physical_session_id != message.session_id;
    let request_start_timestamp = message
        .duration_ms
        .filter(|duration| *duration > 0)
        .map(|duration| message.timestamp.saturating_sub(duration));

    Some(RequestRow {
        date,
        timestamp: message.timestamp,
        source: message.client,
        provider: message.provider_id,
        model,
        session_id: message.session_id,
        physical_session_id,
        is_subagent,
        workspace_label: nonempty(message.workspace_label),
        agent: nonempty(message.agent),
        session_path: nonempty(message.session_path),
        prompt_preview: message.content_preview,
        output_preview: message.output_preview,
        tokens,
        cost,
        token_costs: message.token_costs,
        cost_source: message.cost_source.into(),
        service_tier: message.service_tier.into(),
        duration_ms: message.duration_ms,
        request_start_timestamp,
        request_end_timestamp: message.timestamp,
        is_turn_start: message.is_turn_start,
    })
}

fn physical_session_id(message: &UnifiedMessage) -> String {
    if message.client != "codex" {
        return message.session_id.clone();
    }

    message
        .session_path
        .as_deref()
        .and_then(|path| Path::new(path).file_stem())
        .and_then(|stem| stem.to_str())
        .unwrap_or(&message.session_id)
        .to_string()
}

fn aggregate_requests(mut rows: Vec<RequestRow>) -> Vec<TurnRow> {
    rows.sort_by(|left, right| {
        left.source
            .cmp(&right.source)
            .then_with(|| left.session_id.cmp(&right.session_id))
            .then_with(|| left.timestamp.cmp(&right.timestamp))
            .then_with(|| left.is_subagent.cmp(&right.is_subagent))
            .then_with(|| {
                let left_starts = left.prompt_preview.is_some() || left.is_turn_start;
                let right_starts = right.prompt_preview.is_some() || right.is_turn_start;
                right_starts.cmp(&left_starts)
            })
            .then_with(|| left.physical_session_id.cmp(&right.physical_session_id))
            .then_with(|| left.provider.cmp(&right.provider))
            .then_with(|| left.model.cmp(&right.model))
            .then_with(|| left.agent.cmp(&right.agent))
            .then_with(|| left.date.cmp(&right.date))
    });

    let mut turns = Vec::with_capacity(rows.len());
    let mut active_request: HashMap<RequestKey, (usize, usize)> = HashMap::new();
    let mut current_group: Option<(String, String)> = None;
    let mut current_root_turn = None;
    let mut turn_occurrences: HashMap<String, usize> = HashMap::new();

    for row in rows {
        let group = (row.source.clone(), row.session_id.clone());
        if current_group.as_ref() != Some(&group) {
            current_group = Some(group);
            current_root_turn = None;
            active_request.clear();
        }

        let key = row.key();
        let starts_request = row.prompt_preview.is_some() || row.is_turn_start;
        let starts_root_turn = !row.is_subagent && starts_request;

        if starts_root_turn {
            // A new root prompt cuts every active main-thread stream, including
            // streams using a different model. Existing child requests stay
            // attached to the turn in which they started even if their final
            // token event lands after this boundary.
            active_request.retain(|_, (turn_index, contribution_index)| {
                turns
                    .get(*turn_index)
                    .and_then(|turn: &TurnRow| turn.contributions.get(*contribution_index))
                    .is_some_and(|request| request.is_subagent)
            });

            let turn_index = push_turn(&mut turns, &mut turn_occurrences, row.clone());
            turns[turn_index].contributions.push(row);
            active_request.insert(key, (turn_index, 0));
            current_root_turn = Some(turn_index);
            continue;
        }

        if !starts_request {
            if let Some((turn_index, contribution_index)) = active_request.get(&key).copied() {
                merge_request(
                    &mut turns[turn_index].contributions[contribution_index],
                    row,
                );
                continue;
            }
        }

        let turn_index = current_root_turn.unwrap_or_else(|| {
            let index = push_turn(&mut turns, &mut turn_occurrences, row.clone());
            if !row.is_subagent {
                current_root_turn = Some(index);
            }
            index
        });
        let contribution_index = turns[turn_index].contributions.len();
        turns[turn_index].contributions.push(row);
        active_request.insert(key, (turn_index, contribution_index));
    }

    turns
}

fn push_turn(
    turns: &mut Vec<TurnRow>,
    occurrences: &mut HashMap<String, usize>,
    anchor: RequestRow,
) -> usize {
    let base_id = turn_base_id(&anchor);
    let occurrence = occurrences.entry(base_id.clone()).or_default();
    let id = format!("{base_id}|{occurrence}");
    *occurrence = occurrence.saturating_add(1);
    let index = turns.len();
    turns.push(TurnRow {
        id,
        anchor,
        contributions: Vec::new(),
    });
    index
}

fn merge_request(target: &mut RequestRow, row: RequestRow) {
    target.tokens.add_assign(&row.tokens);
    target.cost = add_cost(target.cost, row.cost);
    target.token_costs = merge_token_costs(target.token_costs, row.token_costs);
    target.cost_source = merge_cost_source(target.cost_source, row.cost_source);
    target.service_tier = merge_service_tier(target.service_tier, row.service_tier);
    target.duration_ms = match (target.duration_ms, row.duration_ms) {
        (Some(left), Some(right)) => Some(left.max(right)),
        (Some(left), None) => Some(left),
        (None, Some(right)) => Some(right),
        (None, None) => None,
    };
    target.request_start_timestamp =
        match (target.request_start_timestamp, row.request_start_timestamp) {
            (Some(left), Some(right)) => Some(left.min(right)),
            (Some(left), None) => Some(left),
            (None, Some(right)) => Some(right),
            (None, None) => None,
        };
    target.request_end_timestamp = target
        .request_end_timestamp
        .max(row.request_end_timestamp)
        .max(row.timestamp);
    target.duration_ms =
        request_wall_duration(target.request_start_timestamp, target.request_end_timestamp)
            .or(target.duration_ms);
    target.is_turn_start |= row.is_turn_start;
    if target.prompt_preview.is_none() {
        target.prompt_preview = row.prompt_preview;
    }
    if row.output_preview.is_some() {
        target.output_preview = row.output_preview;
    }
    if target.workspace_label.is_none() {
        target.workspace_label = row.workspace_label;
    }
    if target.session_path.is_none() {
        target.session_path = row.session_path;
    }
}

fn merge_token_costs(
    left: Option<TokenCostBreakdown>,
    right: Option<TokenCostBreakdown>,
) -> Option<TokenCostBreakdown> {
    match (left, right) {
        (Some(mut left), Some(right)) => {
            left.add_assign(&right);
            Some(left)
        }
        _ => None,
    }
}

fn build_today_sessions(
    turns: Vec<TurnRow>,
    today: NaiveDate,
    session_titles: &HashMap<String, String>,
) -> Vec<SessionSummary> {
    let mut grouped: HashMap<String, Vec<TurnRow>> = HashMap::new();
    for mut turn in turns {
        turn.contributions.retain(|row| row.date == today);
        if turn.contributions.is_empty() {
            continue;
        }
        grouped
            .entry(turn.anchor.session_id.clone())
            .or_default()
            .push(turn);
    }

    let mut sessions = Vec::with_capacity(grouped.len());
    for (session_id, session_turns) in grouped {
        let rows = session_turns
            .iter()
            .flat_map(|turn| turn.contributions.iter())
            .collect::<Vec<_>>();

        let workspace_label = rows
            .iter()
            .filter(|row| !row.is_subagent)
            .find_map(|row| row.workspace_label.clone())
            .or_else(|| rows.iter().find_map(|row| row.workspace_label.clone()));
        let started_at_ms = rows
            .iter()
            .map(|row| row.started_at_ms())
            .min()
            .unwrap_or(0);
        let ended_at_ms = rows
            .iter()
            .map(|row| row.request_end_timestamp)
            .max()
            .unwrap_or(0);
        let mut tokens = TokenBreakdown::default();
        let mut cost_usd = 0.0;
        let mut models = BTreeSet::new();
        for row in &rows {
            tokens.add_assign(&row.tokens);
            cost_usd = add_cost(cost_usd, row.cost);
            models.insert(row.model.clone());
        }

        let mut occurrences: HashMap<String, usize> = HashMap::new();
        let mut request_summaries = session_turns
            .into_iter()
            .map(|turn| turn_summary(turn, &mut occurrences))
            .collect::<Vec<_>>();
        request_summaries.sort_by(|left, right| {
            right
                .ended_at_ms
                .cmp(&left.ended_at_ms)
                .then_with(|| right.started_at_ms.cmp(&left.started_at_ms))
        });

        sessions.push(SessionSummary {
            title: session_titles.get(&session_id).cloned(),
            id: session_id,
            workspace_label,
            started_at_ms,
            ended_at_ms,
            tokens,
            cost_usd,
            models: models.into_iter().collect(),
            requests: request_summaries,
        });
    }

    sessions.sort_by(|left, right| {
        right
            .ended_at_ms
            .cmp(&left.ended_at_ms)
            .then_with(|| left.id.cmp(&right.id))
    });
    sessions
}

fn turn_summary(turn: TurnRow, occurrences: &mut HashMap<String, usize>) -> RequestSummary {
    let mut rows = turn.contributions;
    rows.sort_by(|left, right| {
        left.is_subagent
            .cmp(&right.is_subagent)
            .then_with(|| left.started_at_ms().cmp(&right.started_at_ms()))
            .then_with(|| left.request_end_timestamp.cmp(&right.request_end_timestamp))
            .then_with(|| left.physical_session_id.cmp(&right.physical_session_id))
    });

    let root_output = rows
        .iter()
        .filter(|row| !row.is_subagent)
        .filter_map(|row| {
            row.output_preview
                .as_ref()
                .map(|output| (row.request_end_timestamp, output.clone()))
        })
        .max_by_key(|(timestamp, _)| *timestamp)
        .map(|(_, output)| output);
    let fallback_output = rows
        .iter()
        .filter_map(|row| {
            row.output_preview
                .as_ref()
                .map(|output| (row.request_end_timestamp, output.clone()))
        })
        .max_by_key(|(timestamp, _)| *timestamp)
        .map(|(_, output)| output);
    let root_workspace = rows
        .iter()
        .filter(|row| !row.is_subagent)
        .find_map(|row| row.workspace_label.clone());
    let root_session_path = rows
        .iter()
        .filter(|row| !row.is_subagent)
        .find_map(|row| row.session_path.clone());

    let mut aggregate = rows[0].clone();
    for row in rows.iter().skip(1).cloned() {
        merge_request(&mut aggregate, row);
    }
    aggregate.session_id.clone_from(&turn.anchor.session_id);
    aggregate
        .physical_session_id
        .clone_from(&turn.anchor.physical_session_id);
    aggregate.is_subagent = false;
    aggregate.agent = None;
    aggregate.model.clone_from(&turn.anchor.model);
    aggregate.provider.clone_from(&turn.anchor.provider);
    aggregate.workspace_label = turn.anchor.workspace_label.clone().or(root_workspace);
    aggregate.session_path = turn.anchor.session_path.clone().or(root_session_path);
    aggregate
        .prompt_preview
        .clone_from(&turn.anchor.prompt_preview);
    aggregate.output_preview = if turn.anchor.is_subagent {
        root_output.or(fallback_output)
    } else {
        root_output
    };

    let contributions = rows
        .into_iter()
        .map(|row| request_summary(row, occurrences, Vec::new()))
        .collect();
    request_summary_with_id(aggregate, turn.id, contributions)
}

fn request_summary(
    row: RequestRow,
    occurrences: &mut HashMap<String, usize>,
    contributions: Vec<RequestSummary>,
) -> RequestSummary {
    let base_id = request_base_id(&row);
    let occurrence = occurrences.entry(base_id.clone()).or_default();
    let id = format!("{base_id}|{occurrence}");
    *occurrence = occurrence.saturating_add(1);
    request_summary_with_id(row, id, contributions)
}

fn request_summary_with_id(
    row: RequestRow,
    id: String,
    contributions: Vec<RequestSummary>,
) -> RequestSummary {
    let started_at_ms = row.started_at_ms();
    RequestSummary {
        id,
        session_id: row.session_id,
        physical_session_id: row.physical_session_id,
        is_subagent: row.is_subagent,
        agent: row.agent,
        model: row.model,
        provider: row.provider,
        started_at_ms,
        ended_at_ms: row.request_end_timestamp,
        duration_ms: row.duration_ms,
        tokens: row.tokens,
        cost_usd: row.cost,
        cost_source: row.cost_source,
        service_tier: row.service_tier,
        session_path: row.session_path,
        prompt_preview: row.prompt_preview,
        output_preview: row.output_preview,
        contributions,
    }
}

fn request_base_id(row: &RequestRow) -> String {
    let mut id = String::from("request");
    for component in [
        row.date.format("%Y-%m-%d").to_string(),
        row.session_id.clone(),
        row.physical_session_id.clone(),
        row.provider.clone(),
        row.model.clone(),
        row.agent.clone().unwrap_or_default(),
        row.timestamp.to_string(),
    ] {
        id.push('|');
        id.push_str(&component.len().to_string());
        id.push(':');
        id.push_str(&component);
    }
    id
}

fn turn_base_id(row: &RequestRow) -> String {
    let mut id = String::from("turn");
    for component in [
        row.date.format("%Y-%m-%d").to_string(),
        row.source.clone(),
        row.session_id.clone(),
        row.physical_session_id.clone(),
        row.timestamp.to_string(),
    ] {
        id.push('|');
        id.push_str(&component.len().to_string());
        id.push(':');
        id.push_str(&component);
    }
    id
}

fn request_wall_duration(start_timestamp: Option<i64>, end_timestamp: i64) -> Option<i64> {
    let duration = end_timestamp.saturating_sub(start_timestamp?);
    (duration > 0).then_some(duration)
}

fn merge_cost_source(left: ActivityCostSource, right: ActivityCostSource) -> ActivityCostSource {
    if left == right {
        return left;
    }
    match (left, right) {
        (ActivityCostSource::Unknown, value) | (value, ActivityCostSource::Unknown) => value,
        _ => ActivityCostSource::Unknown,
    }
}

fn merge_service_tier(
    left: ActivityServiceTier,
    right: ActivityServiceTier,
) -> ActivityServiceTier {
    match (left, right) {
        (ActivityServiceTier::Mixed, _) | (_, ActivityServiceTier::Mixed) => {
            ActivityServiceTier::Mixed
        }
        (ActivityServiceTier::Unknown, tier) | (tier, ActivityServiceTier::Unknown) => tier,
        (left, right) if left == right => left,
        _ => ActivityServiceTier::Mixed,
    }
}

fn valid_cost(cost: f64) -> f64 {
    if cost.is_finite() && cost >= 0.0 {
        cost
    } else {
        0.0
    }
}

fn add_cost(left: f64, right: f64) -> f64 {
    let sum = left + right;
    if sum.is_finite() {
        sum
    } else {
        f64::MAX
    }
}

fn nonempty(value: Option<String>) -> Option<String> {
    value.filter(|text| !text.trim().is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pricing::CodexPricing;
    use crate::usage::TokenBreakdown as UnifiedTokens;
    use serde_json::Value;
    use std::fs;
    use std::io::Cursor;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temporary_test_directory(label: &str) -> std::path::PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("tokenbar-{label}-{}-{nonce}", std::process::id()));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn message(
        date: &str,
        timestamp: i64,
        session_id: &str,
        path: &str,
        input: i64,
        output: i64,
    ) -> UnifiedMessage {
        UnifiedMessage {
            client: "codex".to_string(),
            model_id: "gpt-5.4(high)".to_string(),
            provider_id: "openai".to_string(),
            session_id: session_id.to_string(),
            workspace_key: Some("/tmp/project".to_string()),
            workspace_label: Some("project".to_string()),
            session_path: Some(path.to_string()),
            timestamp,
            date: date.to_string(),
            tokens: UnifiedTokens {
                input,
                output,
                cache_read: 0,
                cache_write: 0,
                reasoning: 0,
            },
            cost: 0.25,
            token_costs: None,
            cost_source: CostSource::Estimated,
            service_tier: ServiceTier::Unknown,
            duration_ms: Some(2_000),
            message_count: 1,
            agent: None,
            dedup_key: None,
            content_preview: None,
            output_preview: None,
            is_turn_start: false,
        }
    }

    #[test]
    fn aggregates_requests_and_keeps_subagents_under_the_logical_session() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        let mut first = message(
            "2026-07-13",
            600_000,
            "root-session",
            "/tmp/root-session.jsonl",
            100,
            0,
        );
        first.content_preview = Some("First prompt".to_string());
        first.is_turn_start = true;
        first.session_path = None;

        let mut tail = message(
            "2026-07-13",
            610_000,
            "root-session",
            "/tmp/root-session.jsonl",
            0,
            20,
        );
        tail.duration_ms = Some(1_000);
        tail.output_preview = Some("First answer".to_string());

        let mut second = message(
            "2026-07-13",
            700_000,
            "root-session",
            "/tmp/root-session.jsonl",
            50,
            10,
        );
        second.content_preview = Some("Second prompt".to_string());
        second.is_turn_start = true;

        let mut child = message(
            "2026-07-13",
            800_000,
            "root-session",
            "/tmp/child-a.jsonl",
            40,
            5,
        );
        child.agent = Some("Faraday".to_string());
        child.is_turn_start = true;

        let snapshot = build_snapshot(
            vec![first, tail, second, child],
            today,
            900_000,
            "Asia/Shanghai".to_string(),
            30,
        )
        .unwrap();

        assert_eq!(snapshot.today.session_count, 1);
        assert_eq!(snapshot.today.request_count, 2);
        assert_eq!(snapshot.sessions.len(), 1);
        assert_eq!(snapshot.sessions[0].id, "root-session");
        assert_eq!(snapshot.sessions[0].requests.len(), 2);

        let merged = snapshot.sessions[0]
            .requests
            .iter()
            .find(|request| request.prompt_preview.as_deref() == Some("First prompt"))
            .unwrap();
        assert_eq!(merged.tokens.input, 100);
        assert_eq!(merged.tokens.output, 20);
        assert_eq!(merged.started_at_ms, 598_000);
        assert_eq!(merged.ended_at_ms, 610_000);
        assert_eq!(merged.duration_ms, Some(12_000));
        assert_eq!(merged.output_preview.as_deref(), Some("First answer"));
        assert_eq!(
            merged.session_path.as_deref(),
            Some("/tmp/root-session.jsonl")
        );

        let second_turn = snapshot.sessions[0]
            .requests
            .iter()
            .find(|request| request.prompt_preview.as_deref() == Some("Second prompt"))
            .unwrap();
        assert_eq!(second_turn.tokens.input, 90);
        assert_eq!(second_turn.tokens.output, 15);
        assert_eq!(second_turn.contributions.len(), 2);

        let child = second_turn
            .contributions
            .iter()
            .find(|request| request.physical_session_id == "child-a")
            .unwrap();
        assert!(child.is_subagent);
        assert_eq!(child.session_id, "root-session");
        assert_eq!(child.agent.as_deref(), Some("Faraday"));
        assert_eq!(child.session_path.as_deref(), Some("/tmp/child-a.jsonl"));
    }

    #[test]
    fn aggregates_fast_and_standard_physical_requests_as_a_mixed_turn() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        let mut root = message(
            "2026-07-13",
            100_000,
            "root-session",
            "/tmp/root-session.jsonl",
            10,
            1,
        );
        root.content_preview = Some("Prompt".to_string());
        root.is_turn_start = true;
        root.service_tier = ServiceTier::Fast;

        let mut child = message(
            "2026-07-13",
            110_000,
            "root-session",
            "/tmp/child-session.jsonl",
            20,
            2,
        );
        child.agent = Some("worker".to_string());
        child.is_turn_start = true;
        child.service_tier = ServiceTier::Standard;

        let snapshot =
            build_snapshot(vec![root, child], today, 120_000, "UTC".to_string(), 1).unwrap();
        let turn = &snapshot.sessions[0].requests[0];

        assert_eq!(turn.service_tier, ActivityServiceTier::Mixed);
        assert_eq!(
            turn.contributions[0].service_tier,
            ActivityServiceTier::Fast
        );
        assert_eq!(
            turn.contributions[1].service_tier,
            ActivityServiceTier::Standard
        );
        let value = serde_json::to_value(turn).unwrap();
        assert_eq!(value["serviceTier"], "mixed");
    }

    #[test]
    fn keeps_a_running_subagent_with_the_root_turn_where_it_started() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        let mut first = message(
            "2026-07-13",
            100_000,
            "root-session",
            "/tmp/root-session.jsonl",
            10,
            1,
        );
        first.content_preview = Some("First prompt".to_string());
        first.is_turn_start = true;

        let mut child_start = message(
            "2026-07-13",
            150_000,
            "root-session",
            "/tmp/child-a.jsonl",
            20,
            2,
        );
        child_start.agent = Some("Faraday".to_string());
        child_start.is_turn_start = true;

        let mut second = message(
            "2026-07-13",
            200_000,
            "root-session",
            "/tmp/root-session.jsonl",
            30,
            3,
        );
        second.content_preview = Some("Second prompt".to_string());
        second.is_turn_start = true;

        let mut child_tail = message(
            "2026-07-13",
            250_000,
            "root-session",
            "/tmp/child-a.jsonl",
            0,
            4,
        );
        child_tail.agent = Some("Faraday".to_string());
        child_tail.output_preview = Some("Child finished after the next boundary".to_string());

        let snapshot = build_snapshot(
            vec![first, child_start, second, child_tail],
            today,
            300_000,
            "UTC".to_string(),
            1,
        )
        .unwrap();
        let session = &snapshot.sessions[0];

        assert_eq!(session.requests.len(), 2);
        let first_turn = session
            .requests
            .iter()
            .find(|turn| turn.prompt_preview.as_deref() == Some("First prompt"))
            .unwrap();
        let second_turn = session
            .requests
            .iter()
            .find(|turn| turn.prompt_preview.as_deref() == Some("Second prompt"))
            .unwrap();
        assert_eq!(first_turn.contributions.len(), 2);
        assert_eq!(first_turn.tokens.input, 30);
        assert_eq!(first_turn.tokens.output, 7);
        assert_eq!(first_turn.output_preview, None);
        let child = first_turn
            .contributions
            .iter()
            .find(|request| request.is_subagent)
            .unwrap();
        assert_eq!(child.ended_at_ms, 250_000);
        assert_eq!(child.tokens.output, 6);
        assert_eq!(second_turn.contributions.len(), 1);
        assert_eq!(second_turn.tokens.input, 30);
    }

    #[test]
    fn root_turn_boundary_cuts_an_active_main_stream_using_another_model() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        let mut first = message(
            "2026-07-13",
            100_000,
            "root-session",
            "/tmp/root-session.jsonl",
            10,
            1,
        );
        first.model_id = "gpt-alpha".to_string();
        first.content_preview = Some("First prompt".to_string());
        first.is_turn_start = true;

        let mut second = message(
            "2026-07-13",
            200_000,
            "root-session",
            "/tmp/root-session.jsonl",
            20,
            2,
        );
        second.model_id = "gpt-beta".to_string();
        second.content_preview = Some("Second prompt".to_string());
        second.is_turn_start = true;

        let mut alpha_tail = message(
            "2026-07-13",
            210_000,
            "root-session",
            "/tmp/root-session.jsonl",
            5,
            1,
        );
        alpha_tail.model_id = "gpt-alpha".to_string();

        let snapshot = build_snapshot(
            vec![first, second, alpha_tail],
            today,
            300_000,
            "UTC".to_string(),
            1,
        )
        .unwrap();
        let session = &snapshot.sessions[0];
        let first_turn = session
            .requests
            .iter()
            .find(|turn| turn.prompt_preview.as_deref() == Some("First prompt"))
            .unwrap();
        let second_turn = session
            .requests
            .iter()
            .find(|turn| turn.prompt_preview.as_deref() == Some("Second prompt"))
            .unwrap();

        assert_eq!(first_turn.tokens.input, 10);
        assert_eq!(first_turn.contributions.len(), 1);
        assert_eq!(second_turn.tokens.input, 25);
        assert_eq!(second_turn.contributions.len(), 2);
        assert_eq!(snapshot.today.request_count, 2);
    }

    #[test]
    fn preserves_an_orphan_subagent_as_a_synthetic_turn() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        let mut child = message(
            "2026-07-13",
            100_000,
            "missing-root",
            "/tmp/child-a.jsonl",
            10,
            1,
        );
        child.agent = Some("Faraday".to_string());
        child.is_turn_start = true;
        let mut root = message(
            "2026-07-13",
            200_000,
            "missing-root",
            "/tmp/missing-root.jsonl",
            20,
            2,
        );
        root.content_preview = Some("Available root prompt".to_string());
        root.is_turn_start = true;

        let snapshot =
            build_snapshot(vec![child, root], today, 300_000, "UTC".to_string(), 1).unwrap();
        let session = &snapshot.sessions[0];

        assert_eq!(session.requests.len(), 2);
        assert!(session
            .requests
            .iter()
            .any(|turn| turn.contributions.len() == 1 && turn.contributions[0].is_subagent));
    }

    #[test]
    fn extracts_full_request_content_and_preserves_message_formatting() {
        let long_prompt = format!("first line\n{}\nlast line", "x".repeat(220));
        let commentary = "Checking files\nStill working";
        let final_answer = "Implemented.\n\nTests passed.";
        let lines = [
            serde_json::json!({
                "timestamp": "2026-07-13T10:00:00.000Z",
                "type": "event_msg",
                "payload": {"type": "agent_message", "message": "outside before"}
            }),
            serde_json::json!({
                "timestamp": "2026-07-13T10:00:01.000Z",
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": "<environment_context>secret context</environment_context>"
                }
            }),
            serde_json::json!({
                "timestamp": "2026-07-13T10:00:01.100Z",
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": "  <system-reminder>hidden reminder</system-reminder>"
                }
            }),
            serde_json::json!({
                "timestamp": "2026-07-13T10:00:01.200Z",
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": "<user_instructions>hidden instructions</user_instructions>"
                }
            }),
            serde_json::json!({
                "timestamp": "2026-07-13T10:00:02.000Z",
                "type": "event_msg",
                "payload": {"type": "user_message", "message": long_prompt}
            }),
            serde_json::json!({
                "timestamp": "2026-07-13T10:00:03.000Z",
                "type": "event_msg",
                "payload": {
                    "type": "agent_message",
                    "phase": "commentary",
                    "message": commentary
                }
            }),
            serde_json::json!({
                "timestamp": "2026-07-13T10:00:04.000Z",
                "type": "event_msg",
                "payload": {
                    "type": "agent_message",
                    "phase": "final_answer",
                    "message": final_answer
                }
            }),
            serde_json::json!({
                "timestamp": "2026-07-13T10:00:06.000Z",
                "type": "event_msg",
                "payload": {"type": "agent_message", "message": "outside after"}
            }),
        ]
        .into_iter()
        .map(|value| value.to_string())
        .collect::<Vec<_>>()
        .join("\n");

        let start = chrono::DateTime::parse_from_rfc3339("2026-07-13T10:00:01.000Z")
            .unwrap()
            .timestamp_millis();
        let end = chrono::DateTime::parse_from_rfc3339("2026-07-13T10:00:05.000Z")
            .unwrap()
            .timestamp_millis();
        let detail = extract_request_detail_from_reader(Cursor::new(lines), start, end).unwrap();

        assert_eq!(detail.prompt.as_deref(), Some(long_prompt.as_str()));
        assert_eq!(
            detail.output.as_deref(),
            Some(format!("{commentary}\n\n{final_answer}").as_str())
        );
        assert!(detail.prompt.unwrap().chars().count() > 160);
    }

    #[test]
    fn request_detail_range_is_inclusive_and_skips_malformed_rows() {
        let lines = [
            "not-json".to_string(),
            serde_json::json!({
                "timestamp": 1000,
                "type": "event_msg",
                "payload": {"type": "user_message", "message": "at start"}
            })
            .to_string(),
            serde_json::json!({
                "timestamp": 2000,
                "type": "event_msg",
                "payload": {"type": "agent_message", "message": "at end"}
            })
            .to_string(),
        ]
        .join("\n");

        let detail = extract_request_detail_from_reader(Cursor::new(lines), 1000, 2000).unwrap();

        assert_eq!(detail.prompt.as_deref(), Some("at start"));
        assert_eq!(detail.output.as_deref(), Some("at end"));
    }

    #[test]
    fn request_detail_keeps_multiple_user_messages_in_transcript_order() {
        let lines = [
            serde_json::json!({
                "timestamp": 1000,
                "type": "event_msg",
                "payload": {"type": "user_message", "message": "initial prompt"}
            }),
            serde_json::json!({
                "timestamp": 1100,
                "type": "event_msg",
                "payload": {"type": "agent_message", "message": "first response"}
            }),
            serde_json::json!({
                "timestamp": 1200,
                "type": "event_msg",
                "payload": {"type": "user_message", "message": "steering follow-up"}
            }),
            serde_json::json!({
                "timestamp": 1300,
                "type": "event_msg",
                "payload": {"type": "agent_message", "message": "second response"}
            }),
        ]
        .into_iter()
        .map(|value| value.to_string())
        .collect::<Vec<_>>()
        .join("\n");

        let detail = extract_request_detail_from_reader(Cursor::new(lines), 1000, 1300).unwrap();

        assert_eq!(
            detail.prompt.as_deref(),
            Some("initial prompt\n\nsteering follow-up")
        );
        assert_eq!(
            detail.output.as_deref(),
            Some("first response\n\nsecond response")
        );
    }

    #[test]
    fn request_detail_rejects_a_reversed_range_before_opening_the_file() {
        let error =
            extract_request_detail(Path::new("/definitely/missing.jsonl"), 2, 1).unwrap_err();

        assert_eq!(error, "request start must not be after request end");
    }

    #[test]
    fn loads_latest_codex_title_and_attaches_it_to_the_root_session() {
        let directory = temporary_test_directory("session-title");
        let rollout = directory.join("root-session.jsonl");
        let index = directory.join("session_index.jsonl");
        fs::write(
            &rollout,
            concat!(
                "not json\n",
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"upstream-root\"}}\n"
            ),
        )
        .unwrap();
        fs::write(
            &index,
            concat!(
                "not json\n",
                "{\"id\":\"upstream-root\",\"thread_name\":\"   \"}\n",
                "{\"id\":\"upstream-root\",\"thread_name\":\"Old title\"}\n",
                "{\"id\":\"upstream-root\",\"thread_name\":\" Latest title \"}\n",
                "{\"id\":\"upstream-child\",\"thread_name\":\"Child title\"}\n"
            ),
        )
        .unwrap();

        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        let root_path = rollout.to_string_lossy().into_owned();
        let root = message("2026-07-13", 1_000, "root-session", &root_path, 100, 30);
        let child = message(
            "2026-07-13",
            1_500,
            "root-session",
            "/tmp/child-session.jsonl",
            50,
            10,
        );
        let messages = vec![root, child];

        let titles = load_codex_session_titles(&messages, &index);
        assert_eq!(
            titles.get("root-session").map(String::as_str),
            Some("Latest title")
        );
        assert_eq!(titles.len(), 1);
        assert!(load_codex_session_titles(&messages, &directory.join("missing.jsonl")).is_empty());

        let snapshot = build_snapshot_with_session_titles(
            messages,
            today,
            3_000,
            "UTC".to_string(),
            1,
            &titles,
            None,
        )
        .unwrap();
        assert_eq!(snapshot.sessions[0].title.as_deref(), Some("Latest title"));

        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn aggregates_activity_after_the_exact_weekly_reset_timestamp() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        let before = message(
            "2026-07-13",
            1_000,
            "root-session",
            "/tmp/root-session.jsonl",
            100,
            30,
        );
        let after = message(
            "2026-07-13",
            1_500,
            "root-session",
            "/tmp/root-session.jsonl",
            50,
            10,
        );
        let second_session = message(
            "2026-07-13",
            2_500,
            "second-session",
            "/tmp/second-session.jsonl",
            20,
            5,
        );

        let snapshot = build_snapshot_with_session_titles(
            vec![before, after, second_session],
            today,
            3_000,
            "UTC".to_string(),
            1,
            &HashMap::new(),
            Some(1_500),
        )
        .unwrap();
        let weekly = snapshot.weekly_since_reset.unwrap();

        assert_eq!(weekly.started_at_ms, 1_500);
        assert_eq!(weekly.totals.tokens.input, 70);
        assert_eq!(weekly.totals.tokens.output, 15);
        assert_eq!(weekly.totals.request_count, 2);
        assert_eq!(weekly.totals.session_count, 2);
        assert_eq!(weekly.totals.cost_usd, 0.5);
        assert_eq!(snapshot.today.tokens.input, 170);
        assert_eq!(snapshot.today.tokens.output, 45);
    }

    #[test]
    fn weekly_reset_activity_can_extend_before_the_visible_day_range() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        let older = message(
            "2026-07-08",
            1_500,
            "older-session",
            "/tmp/older-session.jsonl",
            40,
            10,
        );
        let current = message(
            "2026-07-13",
            2_500,
            "current-session",
            "/tmp/current-session.jsonl",
            20,
            5,
        );

        let snapshot = build_snapshot_with_session_titles(
            vec![older, current],
            today,
            3_000,
            "UTC".to_string(),
            1,
            &HashMap::new(),
            Some(1_000),
        )
        .unwrap();
        let weekly = snapshot.weekly_since_reset.unwrap();

        assert_eq!(snapshot.days.len(), 1);
        assert_eq!(snapshot.days[0].date, "2026-07-13");
        assert_eq!(snapshot.today.tokens.input, 20);
        assert_eq!(weekly.totals.tokens.input, 60);
        assert_eq!(weekly.totals.tokens.output, 15);
        assert_eq!(weekly.totals.session_count, 2);
    }

    #[test]
    fn normalizes_codex_reasoning_and_reprices_estimated_cost_once() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        let mut codex = message(
            "2026-07-13",
            1_000,
            "codex-session",
            "/tmp/codex.jsonl",
            100,
            30,
        );
        codex.tokens.reasoning = 10;
        codex.cost = 2.0;
        codex.cost_source = CostSource::Estimated;
        let mut messages = vec![codex];

        normalize_codex_reasoning_usage(&mut messages, |message| {
            assert_eq!(message.tokens.output, 20);
            assert_eq!(message.tokens.reasoning, 10);
            Some(TokenCostBreakdown {
                input: 0.25,
                output: 0.5,
                cache_read: 0.0,
                cache_write: 0.0,
                reasoning: 0.5,
            })
        });

        let snapshot = build_snapshot(messages, today, 2_000, "UTC".to_string(), 1).unwrap();
        assert_eq!(snapshot.today.tokens.output, 20);
        assert_eq!(snapshot.today.tokens.reasoning, 10);
        assert_eq!(snapshot.today.tokens.total(), 130);
        assert_eq!(snapshot.today.cost_usd, 1.25);
        assert_eq!(snapshot.today.token_costs.unwrap().reasoning, 0.5);
    }

    #[test]
    fn reprices_normalized_reasoning_with_the_bundled_pricing_service() {
        let pricing = CodexPricing::bundled();
        let mut codex = message("2026-07-13", 1_000, "codex", "/tmp/codex.jsonl", 100, 30);
        codex.model_id = "gpt-5.4-mini".to_string();
        codex.tokens.reasoning = 10;
        codex.cost_source = CostSource::Estimated;
        codex.cost = pricing
            .calculate_cost_with_provider(&codex.model_id, Some(&codex.provider_id), &codex.tokens)
            .unwrap();
        assert!((codex.cost - 0.000_255).abs() < 1e-12);

        normalize_codex_reasoning_usage(std::slice::from_mut(&mut codex), |message| {
            pricing.calculate_token_costs_with_provider(
                &message.model_id,
                Some(&message.provider_id),
                &message.tokens,
            )
        });

        assert_eq!(codex.tokens.output, 20);
        assert_eq!(codex.tokens.reasoning, 10);
        assert!((codex.cost - 0.000_21).abs() < 1e-12);
    }

    #[test]
    fn reasoning_normalization_preserves_fast_pricing() {
        let pricing = CodexPricing::bundled();
        let mut codex = message("2026-07-13", 1_000, "codex", "/tmp/codex.jsonl", 100, 30);
        codex.model_id = "gpt-5.6-sol".to_string();
        codex.service_tier = ServiceTier::Fast;
        codex.tokens.reasoning = 10;
        codex.cost_source = CostSource::Estimated;
        codex.cost = pricing
            .calculate_cost_with_service_tier(
                &codex.model_id,
                Some(&codex.provider_id),
                &codex.tokens,
                codex.service_tier,
            )
            .unwrap();

        normalize_codex_reasoning_usage(std::slice::from_mut(&mut codex), |message| {
            pricing.calculate_token_costs_with_service_tier(
                &message.model_id,
                Some(&message.provider_id),
                &message.tokens,
                message.service_tier,
            )
        });

        let standard = pricing
            .calculate_cost_with_provider(&codex.model_id, Some(&codex.provider_id), &codex.tokens)
            .unwrap();
        assert_eq!(codex.tokens.output, 20);
        assert!((codex.cost - standard * 2.0).abs() < 1e-12);
    }

    #[test]
    fn leaves_an_inconsistent_reasoning_breakdown_unchanged() {
        let mut codex = message("2026-07-13", 1_000, "codex", "/tmp/codex.jsonl", 100, 5);
        codex.tokens.reasoning = 10;
        codex.cost = 2.0;
        codex.cost_source = CostSource::Estimated;
        let mut recalculated = false;

        normalize_codex_reasoning_usage(std::slice::from_mut(&mut codex), |_| {
            recalculated = true;
            Some(TokenCostBreakdown {
                input: 1.0,
                ..Default::default()
            })
        });

        assert_eq!(codex.tokens.output, 5);
        assert_eq!(codex.tokens.reasoning, 10);
        assert_eq!(codex.cost, 2.0);
        assert!(!recalculated);
    }

    #[test]
    fn preserves_authoritative_costs_and_reverts_when_repricing_is_unavailable() {
        let mut authoritative = message(
            "2026-07-13",
            1_000,
            "reported",
            "/tmp/reported.jsonl",
            100,
            30,
        );
        authoritative.tokens.reasoning = 10;
        authoritative.cost = 9.0;
        authoritative.cost_source = CostSource::ProviderReported;

        let mut unavailable = message(
            "2026-07-13",
            2_000,
            "estimated",
            "/tmp/estimated.jsonl",
            100,
            30,
        );
        unavailable.tokens.reasoning = 10;
        unavailable.cost = 2.0;
        unavailable.cost_source = CostSource::Estimated;

        let mut non_codex = message("2026-07-13", 3_000, "claude", "/tmp/claude.jsonl", 100, 30);
        non_codex.client = "claude".to_string();
        non_codex.tokens.reasoning = 10;

        let mut messages = vec![authoritative, unavailable, non_codex];
        normalize_codex_reasoning_usage(&mut messages, |_| None);

        assert_eq!(messages[0].tokens.output, 20);
        assert_eq!(messages[0].cost, 9.0);
        assert_eq!(messages[1].tokens.output, 30);
        assert_eq!(messages[1].cost, 2.0);
        assert_eq!(messages[2].tokens.output, 30);
    }

    #[test]
    fn fills_zero_days_and_excludes_activity_before_the_window() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        let today_message = message("2026-07-13", 2_000, "today", "/tmp/today.jsonl", 10, 5);
        let old_message = message("2026-06-13", 1_000, "old", "/tmp/old.jsonl", 1_000, 1_000);

        let snapshot = build_snapshot(
            vec![old_message, today_message],
            today,
            3_000,
            "UTC".to_string(),
            30,
        )
        .unwrap();

        assert_eq!(snapshot.days.len(), 30);
        assert_eq!(snapshot.days.first().unwrap().date, "2026-06-14");
        assert_eq!(snapshot.days.last().unwrap().date, "2026-07-13");
        assert_eq!(snapshot.days[0].tokens, TokenBreakdown::default());
        assert_eq!(snapshot.today.tokens.input, 10);
        assert_eq!(snapshot.today.tokens.output, 5);
        assert_eq!(snapshot.today.request_count, 1);
        assert_eq!(snapshot.today.session_count, 1);
    }

    #[test]
    fn daily_models_aggregate_requests_by_provider_and_model() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        let mut messages = vec![
            message("2026-07-13", 100_000, "one", "/tmp/one.jsonl", 100, 10),
            message("2026-07-13", 200_000, "one", "/tmp/one.jsonl", 50, 5),
            message("2026-07-13", 300_000, "two", "/tmp/two.jsonl", 25, 5),
            message("2026-07-13", 400_000, "three", "/tmp/three.jsonl", 20, 2),
            message("2026-07-13", 500_000, "four", "/tmp/four.jsonl", 50, 0),
        ];

        for (index, message) in messages.iter_mut().enumerate() {
            message.content_preview = Some(format!("prompt {index}"));
            message.is_turn_start = true;
        }
        messages[0].tokens.cache_read = 80;
        messages[1].tokens.cache_read = 20;
        messages[3].provider_id = "azure-openai".to_string();
        messages[4].model_id = "gpt-4.1".to_string();

        let snapshot = build_snapshot(messages, today, 600_000, "UTC".to_string(), 1).unwrap();
        let day = &snapshot.days[0];

        assert_eq!(day.models.len(), 3);
        assert_eq!(day.models[0].provider, "openai");
        assert_eq!(day.models[0].model, "gpt-5.4");
        assert_eq!(day.models[0].tokens.input, 175);
        assert_eq!(day.models[0].tokens.output, 20);
        assert_eq!(day.models[0].tokens.cache_read, 100);
        assert_eq!(day.models[0].cost_usd, 0.75);
        assert_eq!(day.models[0].request_count, 3);
        assert_eq!(day.models[0].session_count, 2);

        // Remaining entries are also deterministic: descending total tokens,
        // then cost, provider, and model.
        assert_eq!(day.models[1].model, "gpt-4.1");
        assert_eq!(day.models[2].provider, "azure-openai");
        assert_eq!(day.models[2].model, "gpt-5.4");
        assert_eq!(day.models[2].request_count, 1);
        assert_eq!(day.models[2].session_count, 1);

        let value = serde_json::to_value(snapshot).unwrap();
        assert_eq!(value["days"][0]["models"][0]["costUsd"], 0.75);
        assert_eq!(value["days"][0]["models"][0]["requestCount"], 3);
        assert_eq!(value["days"][0]["models"][0]["sessionCount"], 2);
        assert!(value["days"][0]["models"][0].get("cost_usd").is_none());
    }

    #[test]
    fn daily_summary_accepts_legacy_json_without_models() {
        let legacy = serde_json::json!({
            "date": "2026-07-13",
            "tokens": {
                "input": 10,
                "output": 2,
                "cacheRead": 5,
                "cacheWrite": 0,
                "reasoning": 0
            },
            "costUsd": 0.25,
            "requestCount": 1,
            "sessionCount": 1
        });

        let day: DailySummary = serde_json::from_value(legacy).unwrap();

        assert!(day.models.is_empty());
    }

    #[test]
    fn serializes_the_swift_contract_with_camel_case_keys() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        let snapshot = build_snapshot(vec![], today, 123, "UTC".to_string(), 1).unwrap();
        let value: Value = serde_json::to_value(snapshot).unwrap();

        assert_eq!(value["schemaVersion"], 3);
        assert_eq!(value["generatedAtMs"], 123);
        assert_eq!(value["today"]["requestCount"], 0);
        assert_eq!(value["today"]["tokens"]["cacheRead"], 0);
        assert_eq!(value["days"][0]["sessionCount"], 0);
        assert_eq!(value["days"][0]["models"], serde_json::json!([]));
        assert!(value.get("schema_version").is_none());
    }

    #[test]
    fn rejects_an_empty_day_range() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 13).unwrap();
        assert!(build_snapshot(vec![], today, 0, "UTC".to_string(), 0).is_err());
    }
}
