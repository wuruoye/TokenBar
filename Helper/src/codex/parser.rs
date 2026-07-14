//! Codex JSONL parsing adapted from tokscale-core's MIT-licensed Codex parser.
//!
//! The implementation is owned by TokenBar and intentionally exposes only the
//! Codex behavior needed by the menu-bar app. It preserves the upstream parser's
//! cumulative-token, compaction, fork replay, turn-marker, and preview rules.

use std::collections::HashSet;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::time::UNIX_EPOCH;

use serde::Deserialize;
use serde_json::Value;

use crate::usage::{
    content_preview_from_str, content_preview_from_value, normalize_workspace_key,
    workspace_label_from_key, ServiceTier, TokenBreakdown, UnifiedMessage,
};

const CODEX_SYSTEM_INJECTED_PREFIXES: [&str; 3] = [
    "<environment_context>",
    "<system-reminder>",
    "<user_instructions>",
];

#[derive(Debug, Deserialize)]
struct CodexEntry {
    #[serde(rename = "type")]
    entry_type: String,
    timestamp: Option<String>,
    payload: Option<CodexPayload>,
}

#[derive(Debug, Deserialize)]
struct CodexPayload {
    id: Option<String>,
    forked_from_id: Option<String>,
    #[serde(rename = "type")]
    payload_type: Option<String>,
    model: Option<String>,
    model_name: Option<String>,
    model_info: Option<CodexModelInfo>,
    info: Option<CodexInfo>,
    turn_id: Option<String>,
    source: Option<Value>,
    thread_source: Option<String>,
    cwd: Option<String>,
    model_provider: Option<String>,
    agent_nickname: Option<String>,
    message: Option<String>,
    thread_settings: Option<CodexThreadSettings>,
}

#[derive(Debug, Deserialize)]
struct CodexThreadSettings {
    service_tier: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CodexModelInfo {
    slug: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CodexInfo {
    model: Option<String>,
    model_name: Option<String>,
    last_token_usage: Option<CodexTokenUsage>,
    total_token_usage: Option<CodexTokenUsage>,
}

#[derive(Debug, Deserialize, Clone)]
struct CodexTokenUsage {
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
    cached_input_tokens: Option<i64>,
    cache_read_input_tokens: Option<i64>,
    reasoning_output_tokens: Option<i64>,
    total_tokens: Option<i64>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct CodexTotals {
    input: i64,
    output: i64,
    cached: i64,
    reasoning: i64,
}

impl CodexTotals {
    fn from_usage(usage: &CodexTokenUsage) -> Self {
        Self {
            input: usage.input_tokens.unwrap_or(0).max(0),
            output: usage.output_tokens.unwrap_or(0).max(0),
            cached: usage
                .cached_input_tokens
                .unwrap_or(0)
                .max(usage.cache_read_input_tokens.unwrap_or(0))
                .max(0),
            reasoning: usage.reasoning_output_tokens.unwrap_or(0).max(0),
        }
    }

    fn delta_from(self, previous: Self) -> Option<Self> {
        if self.input < previous.input
            || self.output < previous.output
            || self.cached < previous.cached
            || self.reasoning < previous.reasoning
        {
            return None;
        }
        Some(Self {
            input: self.input - previous.input,
            output: self.output - previous.output,
            cached: self.cached - previous.cached,
            reasoning: self.reasoning - previous.reasoning,
        })
    }

    fn saturating_add(self, other: Self) -> Self {
        Self {
            input: self.input.saturating_add(other.input),
            output: self.output.saturating_add(other.output),
            cached: self.cached.saturating_add(other.cached),
            reasoning: self.reasoning.saturating_add(other.reasoning),
        }
    }

    fn total(self) -> i64 {
        self.input
            .saturating_add(self.output)
            .saturating_add(self.cached)
            .saturating_add(self.reasoning)
    }

    fn is_within(self, baseline: Self) -> bool {
        self.input <= baseline.input
            && self.output <= baseline.output
            && self.cached <= baseline.cached
            && self.reasoning <= baseline.reasoning
    }

    fn looks_like_stale_regression(self, previous: Self, last: Self) -> bool {
        let previous_total = previous.total();
        let current_total = self.total();
        let last_total = last.total();
        if previous_total <= 0 || current_total <= 0 || last_total <= 0 {
            return false;
        }
        current_total.saturating_mul(100) >= previous_total.saturating_mul(98)
            || current_total.saturating_add(last_total.saturating_mul(2)) >= previous_total
    }

    fn into_tokens(self) -> TokenBreakdown {
        let clamped_cached = self.cached.min(self.input).max(0);
        TokenBreakdown {
            input: (self.input - clamped_cached).max(0),
            output: self.output.max(0),
            cache_read: clamped_cached,
            cache_write: 0,
            reasoning: self.reasoning.max(0),
        }
    }
}

#[derive(Debug, Clone, Default)]
struct CodexParseState {
    current_model: Option<String>,
    current_service_tier: ServiceTier,
    service_tier_consensus: Option<ServiceTier>,
    service_tier_conflicted: bool,
    current_turn_start_ms: Option<i64>,
    previous_totals: Option<CodexTotals>,
    session_is_headless: bool,
    session_id_from_meta: Option<String>,
    session_forked_from_id: Option<String>,
    forked_child_session_id: Option<String>,
    forked_child_replay_session_id: Option<String>,
    session_provider: Option<String>,
    session_agent: Option<String>,
    session_workspace_key: Option<String>,
    session_workspace_label: Option<String>,
    session_is_subagent: bool,
    forked_child_waiting_for_turn_context: bool,
    forked_child_inherited_baseline: Option<CodexTotals>,
    forked_child_inherited_reported_total: Option<i64>,
    pending_turn_start: bool,
    pending_content_preview: Option<String>,
    pending_output_preview: Option<String>,
    forked_child_task_started_turn_ids: HashSet<String>,
    forked_child_is_user_fork: bool,
}

pub fn parse_codex_file(path: &Path) -> Result<Vec<UnifiedMessage>, String> {
    let file = File::open(path)
        .map_err(|error| format!("could not open Codex session {}: {error}", path.display()))?;
    let session_id = session_id_from_path(path);
    let fallback_timestamp = file_modified_timestamp_ms(path);
    parse_codex_reader(
        BufReader::new(file),
        &session_id,
        fallback_timestamp,
        CodexParseState::default(),
    )
}

fn parse_codex_reader<R: BufRead>(
    mut reader: R,
    session_id: &str,
    fallback_timestamp: i64,
    mut state: CodexParseState,
) -> Result<Vec<UnifiedMessage>, String> {
    let mut messages = Vec::with_capacity(64);
    let mut pending_model_messages = Vec::new();
    let mut line = String::with_capacity(4096);

    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            // A rollout can be observed while Codex is partway through writing
            // a UTF-8 code point. Keep the valid prefix instead of dropping the
            // entire session for this refresh.
            Err(_) => break,
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let mut handled = false;
        if let Ok(entry) = serde_json::from_str::<CodexEntry>(trimmed) {
            let entry_type = entry.entry_type;
            let entry_timestamp = entry.timestamp;

            if let Some(payload) = entry.payload {
                let payload_model = extract_model(&payload);
                let is_token_count = entry_type == "event_msg"
                    && payload.payload_type.as_deref() == Some("token_count");
                let is_thread_settings_applied = entry_type == "event_msg"
                    && payload.payload_type.as_deref() == Some("thread_settings_applied");
                let service_tier_snapshot = is_thread_settings_applied
                    .then(|| {
                        payload
                            .thread_settings
                            .as_ref()
                            .and_then(|settings| settings.service_tier.as_deref())
                    })
                    .flatten();
                let info_model = is_token_count
                    .then(|| payload.info.as_ref().and_then(extract_model_from_info))
                    .flatten();
                let event_model = payload_model.clone().or(info_model.clone());

                if state.forked_child_waiting_for_turn_context {
                    if entry_type == "turn_context"
                        && forked_child_turn_starts_own_session(&state, payload.turn_id.as_deref())
                    {
                        state.forked_child_waiting_for_turn_context = false;
                        state.forked_child_replay_session_id = None;
                        state.forked_child_task_started_turn_ids.clear();
                        state.forked_child_is_user_fork = false;
                        begin_forked_child_service_tier_tracking(&mut state);
                        if let Some(id) = state.forked_child_session_id.as_ref() {
                            state.session_id_from_meta = Some(id.clone());
                        }
                        state.current_model = payload_model.clone();
                        handled = true;
                    } else {
                        if is_thread_settings_applied {
                            record_service_tier_snapshot(&mut state, service_tier_snapshot, false);
                        }
                        if entry_type == "event_msg"
                            && payload.payload_type.as_deref() == Some("task_started")
                        {
                            if let Some(turn_id) = payload.turn_id.as_ref() {
                                state
                                    .forked_child_task_started_turn_ids
                                    .insert(turn_id.clone());
                            }
                        }
                        if entry_type == "session_meta" {
                            if let Some(id) = payload.id.as_ref() {
                                if state
                                    .forked_child_session_id
                                    .as_deref()
                                    .is_some_and(|child_id| child_id != id)
                                {
                                    state.forked_child_replay_session_id = Some(id.clone());
                                }
                            }
                        }
                        if is_token_count {
                            if let Some(info) = payload.info.as_ref() {
                                remember_forked_child_inherited_baseline(&mut state, info);
                            }
                        }
                        continue;
                    }
                }

                if !pending_model_messages.is_empty()
                    && event_model.is_none()
                    && !is_token_count
                    && entry_type != "session_meta"
                {
                    flush_pending_model_messages(
                        &mut pending_model_messages,
                        &mut messages,
                        "unknown",
                    );
                }

                if entry_type == "session_meta" {
                    apply_session_meta(&mut state, &payload);
                }

                if is_thread_settings_applied {
                    record_service_tier_snapshot(&mut state, service_tier_snapshot, true);
                    handled = true;
                }

                if entry_type == "turn_context" {
                    state.current_model = payload_model.clone();
                    state.current_turn_start_ms =
                        parse_codex_entry_timestamp(entry_timestamp.as_deref());
                    if let Some(model) = state.current_model.as_ref() {
                        flush_pending_model_messages(
                            &mut pending_model_messages,
                            &mut messages,
                            model,
                        );
                    }
                    handled = true;
                }

                if entry_type == "event_msg"
                    && payload.payload_type.as_deref() == Some("user_message")
                {
                    if codex_message_is_human_turn(payload.message.as_deref()) {
                        state.pending_turn_start = true;
                        state.pending_content_preview = payload
                            .message
                            .as_deref()
                            .and_then(content_preview_from_str);
                    }
                    handled = true;
                }

                if entry_type == "event_msg"
                    && payload.payload_type.as_deref() == Some("agent_message")
                {
                    if state.session_is_subagent {
                        state.pending_output_preview = payload
                            .message
                            .as_deref()
                            .and_then(content_preview_from_str);
                    }
                    handled = true;
                }

                if is_token_count {
                    handled = true;
                    let Some(info) = payload.info else {
                        continue;
                    };
                    let model = payload_model
                        .or(info_model)
                        .or_else(|| state.current_model.clone());
                    if let Some(model) = model.as_ref() {
                        state.current_model = Some(model.clone());
                        flush_pending_model_messages(
                            &mut pending_model_messages,
                            &mut messages,
                            model,
                        );
                    }

                    let total_usage = info.total_token_usage.as_ref().map(CodexTotals::from_usage);
                    let last_usage = info.last_token_usage.as_ref().map(CodexTotals::from_usage);
                    if forked_child_should_skip_inherited_snapshot(
                        &state,
                        info.total_token_usage.as_ref(),
                        total_usage,
                    ) {
                        continue;
                    }
                    state.forked_child_inherited_baseline = None;
                    state.forked_child_inherited_reported_total = None;

                    let (tokens, next_totals) =
                        match (total_usage, last_usage, state.previous_totals) {
                            (Some(total), Some(last), Some(previous)) => {
                                if total == previous {
                                    continue;
                                }
                                if total.delta_from(previous).is_none()
                                    && total.looks_like_stale_regression(previous, last)
                                {
                                    continue;
                                }
                                (last.into_tokens(), Some(total))
                            }
                            (Some(total), Some(last), None) => (last.into_tokens(), Some(total)),
                            (Some(total), None, Some(previous)) => {
                                if total == previous {
                                    continue;
                                }
                                let Some(delta) = total.delta_from(previous) else {
                                    state.previous_totals = Some(total);
                                    continue;
                                };
                                (delta.into_tokens(), Some(total))
                            }
                            (Some(total), None, None) => (total.into_tokens(), Some(total)),
                            (None, Some(last), Some(previous)) => {
                                (last.into_tokens(), Some(previous.saturating_add(last)))
                            }
                            (None, Some(last), None) => (last.into_tokens(), None),
                            (None, None, _) => continue,
                        };

                    if tokens.total() == 0 {
                        continue;
                    }
                    state.previous_totals = next_totals;

                    let parsed_timestamp = parse_codex_entry_timestamp(entry_timestamp.as_deref());
                    let timestamp = parsed_timestamp.unwrap_or(fallback_timestamp);
                    let duration_ms =
                        duration_between_ms(state.current_turn_start_ms, parsed_timestamp);
                    let agent = if state.session_is_headless {
                        Some("headless".to_string())
                    } else {
                        state.session_agent.clone()
                    };
                    let provider = state
                        .session_provider
                        .as_deref()
                        .or_else(|| model.as_deref().and_then(inferred_provider_from_model))
                        .unwrap_or("openai");

                    let mut message = UnifiedMessage::new_with_agent(
                        "codex",
                        model.clone().unwrap_or_else(|| "unknown".to_string()),
                        provider,
                        session_id,
                        timestamp,
                        tokens,
                        0.0,
                        agent,
                    );
                    message.service_tier = state.current_service_tier;
                    message.duration_ms = duration_ms;
                    if state.pending_turn_start {
                        message.is_turn_start = true;
                        state.pending_turn_start = false;
                    }
                    message.set_content_preview(state.pending_content_preview.take());
                    message.set_output_preview(state.pending_output_preview.take());
                    if parsed_timestamp.is_some() || total_usage.is_some() {
                        let dedup_scope_id = state
                            .session_forked_from_id
                            .as_deref()
                            .or(state.session_id_from_meta.as_deref())
                            .unwrap_or(session_id);
                        set_codex_dedup_key(
                            &mut message,
                            model.as_deref().unwrap_or("unknown"),
                            dedup_scope_id,
                            total_usage,
                        );
                    }
                    message.set_workspace(
                        state.session_workspace_key.clone(),
                        state.session_workspace_label.clone(),
                    );
                    if model.is_some() {
                        messages.push(message);
                    } else {
                        pending_model_messages.push(message);
                    }
                }
            }

            if entry_type == "session_meta" {
                handled = true;
            }
        }

        if handled {
            continue;
        }

        if state.forked_child_waiting_for_turn_context
            && serde_json::from_str::<Value>(trimmed).is_ok()
        {
            continue;
        }

        let headless_message = parse_codex_headless_line(
            trimmed,
            session_id,
            &mut state.current_model,
            fallback_timestamp,
            state.session_provider.as_deref(),
            &state.session_agent,
            state.session_is_headless,
        );
        if !pending_model_messages.is_empty() {
            let model = state.current_model.as_deref().unwrap_or("unknown");
            flush_pending_model_messages(&mut pending_model_messages, &mut messages, model);
        }
        if let Some(mut message) = headless_message {
            message.service_tier = state.current_service_tier;
            message.set_workspace(
                state.session_workspace_key.clone(),
                state.session_workspace_label.clone(),
            );
            messages.push(message);
        }
    }

    flush_pending_model_messages(&mut pending_model_messages, &mut messages, "unknown");
    backfill_homogeneous_service_tier(&mut messages, &state);
    Ok(messages)
}

fn apply_session_meta(state: &mut CodexParseState, payload: &CodexPayload) {
    if codex_source_is_exec(payload.source.as_ref()) {
        state.session_is_headless = true;
    }
    if forked_from_id_from_source(payload.source.as_ref()).is_some()
        || (payload.thread_source.as_deref() == Some("subagent")
            && payload
                .forked_from_id
                .as_deref()
                .is_some_and(|id| !id.is_empty()))
    {
        state.session_is_subagent = true;
    }
    if let Some(id) = payload.id.as_ref() {
        state.session_id_from_meta = Some(id.clone());
    }
    let forked_from_id = payload
        .forked_from_id
        .as_deref()
        .filter(|id| !id.is_empty())
        .or_else(|| forked_from_id_from_source(payload.source.as_ref()));
    if let Some(forked_from_id) = forked_from_id {
        let repeated_active_child_meta = !state.forked_child_waiting_for_turn_context
            && payload.id.is_some()
            && state.forked_child_session_id.as_deref() == payload.id.as_deref();
        state.session_forked_from_id = Some(forked_from_id.to_string());
        state.forked_child_session_id = payload.id.clone();
        if !repeated_active_child_meta {
            state.forked_child_waiting_for_turn_context = true;
            state.forked_child_replay_session_id = None;
            state.forked_child_inherited_baseline = None;
            state.forked_child_inherited_reported_total = None;
            state.forked_child_task_started_turn_ids.clear();
            state.forked_child_is_user_fork = payload.thread_source.as_deref() == Some("user");
            state.current_service_tier = ServiceTier::Unknown;
            state.service_tier_consensus = None;
            state.service_tier_conflicted = false;
        }
    }
    if let Some(provider) = payload.model_provider.as_ref() {
        state.session_provider = Some(provider.clone());
    }
    if let Some(agent) = payload.agent_nickname.as_ref() {
        state.session_agent = Some(agent.clone());
    }
    if let Some(cwd) = payload.cwd.as_ref() {
        let (key, label) = codex_workspace_from_cwd(cwd);
        state.session_workspace_key = key;
        state.session_workspace_label = label;
    }
}

fn service_tier_from_raw(raw: Option<&str>) -> ServiceTier {
    match raw.map(str::trim).map(str::to_ascii_lowercase).as_deref() {
        Some("priority" | "fast") => ServiceTier::Fast,
        Some("default" | "standard") => ServiceTier::Standard,
        _ => ServiceTier::Unknown,
    }
}

fn record_service_tier_snapshot(
    state: &mut CodexParseState,
    raw: Option<&str>,
    contributes_to_consensus: bool,
) {
    let tier = service_tier_from_raw(raw);
    state.current_service_tier = tier;
    if !contributes_to_consensus {
        return;
    }

    if tier == ServiceTier::Unknown {
        state.service_tier_conflicted = true;
        return;
    }
    match state.service_tier_consensus {
        None => state.service_tier_consensus = Some(tier),
        Some(existing) if existing == tier => {}
        Some(_) => state.service_tier_conflicted = true,
    }
}

fn begin_forked_child_service_tier_tracking(state: &mut CodexParseState) {
    state.service_tier_consensus =
        (state.current_service_tier != ServiceTier::Unknown).then_some(state.current_service_tier);
    state.service_tier_conflicted = false;
}

fn backfill_homogeneous_service_tier(messages: &mut [UnifiedMessage], state: &CodexParseState) {
    if state.service_tier_conflicted {
        return;
    }
    let Some(tier) = state.service_tier_consensus else {
        return;
    };
    for message in messages {
        if message.service_tier == ServiceTier::Unknown {
            message.service_tier = tier;
        }
    }
}

fn session_id_from_path(path: &Path) -> String {
    path.file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("unknown")
        .to_string()
}

fn file_modified_timestamp_ms(path: &Path) -> i64 {
    path.metadata()
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}

fn codex_workspace_from_cwd(cwd: &str) -> (Option<String>, Option<String>) {
    let key = normalize_codex_workspace_key(cwd);
    let label = key.as_deref().and_then(workspace_label_from_key);
    if label.is_none() {
        return (None, None);
    }
    (key, label)
}

fn normalize_codex_workspace_key(raw: &str) -> Option<String> {
    let normalized = normalize_workspace_key(raw)?;
    if normalized.chars().any(char::is_control) || !looks_like_explicit_workspace_path(&normalized)
    {
        return None;
    }
    Some(normalized)
}

fn looks_like_explicit_workspace_path(path: &str) -> bool {
    if path.starts_with("//") || path.starts_with('/') {
        return true;
    }
    let bytes = path.as_bytes();
    bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && bytes[2] == b'/'
}

fn codex_source_is_exec(source: Option<&Value>) -> bool {
    source.and_then(Value::as_str) == Some("exec")
}

pub(super) fn forked_from_id_from_source(source: Option<&Value>) -> Option<&str> {
    source?
        .get("subagent")?
        .get("thread_spawn")?
        .get("parent_thread_id")?
        .as_str()
        .filter(|id| !id.is_empty())
}

fn forked_child_turn_starts_own_session(state: &CodexParseState, turn_id: Option<&str>) -> bool {
    if state.forked_child_replay_session_id.is_none() {
        return true;
    }
    let Some(child_session_id) = state.forked_child_session_id.as_deref() else {
        return true;
    };

    match (turn_id, codex_uuid_v7_order_key(child_session_id)) {
        (Some(turn_id), Some(child_key)) => {
            let Some(turn_key) = codex_uuid_v7_order_key(turn_id) else {
                return true;
            };
            match turn_key[..12].cmp(&child_key[..12]) {
                std::cmp::Ordering::Greater => true,
                std::cmp::Ordering::Less => false,
                std::cmp::Ordering::Equal => {
                    state.forked_child_is_user_fork
                        || state.forked_child_task_started_turn_ids.contains(turn_id)
                }
            }
        }
        _ => true,
    }
}

fn codex_uuid_v7_order_key(id: &str) -> Option<String> {
    let mut parts = id.split('-');
    let first = parts.next()?;
    let second = parts.next()?;
    let third = parts.next()?;
    let fourth = parts.next()?;
    let fifth = parts.next()?;
    if parts.next().is_some()
        || first.len() != 8
        || second.len() != 4
        || third.len() != 4
        || fourth.len() != 4
        || fifth.len() != 12
        || !third.starts_with('7')
    {
        return None;
    }
    let mut key = String::with_capacity(32);
    for part in [first, second, third, fourth, fifth] {
        if !part.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return None;
        }
        key.push_str(&part.to_ascii_lowercase());
    }
    Some(key)
}

fn parse_codex_entry_timestamp(timestamp: Option<&str>) -> Option<i64> {
    timestamp
        .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
        .map(|date_time| date_time.timestamp_millis())
}

fn duration_between_ms(start_ms: Option<i64>, end_ms: Option<i64>) -> Option<i64> {
    let duration = end_ms?.saturating_sub(start_ms?);
    (duration > 0).then_some(duration)
}

fn extract_model(payload: &CodexPayload) -> Option<String> {
    payload
        .model_info
        .as_ref()
        .and_then(|info| info.slug.clone())
        .filter(|model| !model.is_empty())
        .or(payload.model.clone().filter(|model| !model.is_empty()))
        .or(payload.model_name.clone().filter(|model| !model.is_empty()))
        .or(payload.info.as_ref().and_then(extract_model_from_info))
}

fn extract_model_from_info(info: &CodexInfo) -> Option<String> {
    info.model
        .clone()
        .filter(|model| !model.is_empty())
        .or(info.model_name.clone().filter(|model| !model.is_empty()))
}

fn codex_message_is_human_turn(message: Option<&str>) -> bool {
    message.is_some_and(|text| {
        let trimmed = text.trim_start();
        !CODEX_SYSTEM_INJECTED_PREFIXES
            .iter()
            .any(|prefix| trimmed.starts_with(prefix))
    })
}

fn reported_total_tokens(usage: &CodexTokenUsage) -> Option<i64> {
    usage.total_tokens.filter(|total| *total >= 0)
}

fn remember_forked_child_inherited_baseline(state: &mut CodexParseState, info: &CodexInfo) {
    let Some(total_usage) = info.total_token_usage.as_ref() else {
        return;
    };
    let totals = CodexTotals::from_usage(total_usage);
    state.previous_totals = Some(totals);
    state.forked_child_inherited_baseline = Some(totals);
    state.forked_child_inherited_reported_total = reported_total_tokens(total_usage);
}

fn forked_child_should_skip_inherited_snapshot(
    state: &CodexParseState,
    total_usage: Option<&CodexTokenUsage>,
    totals: Option<CodexTotals>,
) -> bool {
    if let (Some(usage), Some(baseline)) =
        (total_usage, state.forked_child_inherited_reported_total)
    {
        if reported_total_tokens(usage).is_some_and(|total| total <= baseline) {
            return true;
        }
    }
    if let (Some(totals), Some(baseline)) = (totals, state.forked_child_inherited_baseline) {
        return totals.is_within(baseline);
    }
    false
}

fn codex_token_count_dedup_key(
    message: &UnifiedMessage,
    model: &str,
    upstream_session_id: &str,
    total_usage: Option<CodexTotals>,
) -> String {
    if let Some(total) = total_usage {
        return format!(
            "codex:token_count-total:{}:{}:{}:{}:{}:{}:{}",
            upstream_session_id,
            message.provider_id,
            model,
            total.input,
            total.output,
            total.cached,
            total.reasoning
        );
    }
    format!(
        "codex:token_count:{}:{}:{}:{}:{}:{}:{}:{}",
        message.timestamp,
        message.provider_id,
        model,
        message.tokens.input,
        message.tokens.output,
        message.tokens.cache_read,
        message.tokens.cache_write,
        message.tokens.reasoning
    )
}

fn set_codex_dedup_key(
    message: &mut UnifiedMessage,
    model: &str,
    upstream_session_id: &str,
    total_usage: Option<CodexTotals>,
) {
    if message.dedup_key.is_none() {
        message.dedup_key = Some(codex_token_count_dedup_key(
            message,
            model,
            upstream_session_id,
            total_usage,
        ));
    }
}

fn flush_pending_model_messages(
    pending: &mut Vec<UnifiedMessage>,
    messages: &mut Vec<UnifiedMessage>,
    model: &str,
) {
    for mut message in pending.drain(..) {
        let upstream_session_id = message.session_id.clone();
        set_codex_dedup_key(&mut message, model, &upstream_session_id, None);
        message.model_id = model.to_string();
        messages.push(message);
    }
}

fn inferred_provider_from_model(model: &str) -> Option<&'static str> {
    let model = model.to_ascii_lowercase();
    if model.contains("gpt")
        || model.contains("openai")
        || model.starts_with("o1")
        || model.starts_with("o3")
        || model.starts_with("o4")
    {
        Some("openai")
    } else {
        None
    }
}

fn parse_codex_headless_line(
    line: &str,
    session_id: &str,
    current_model: &mut Option<String>,
    fallback_timestamp: i64,
    session_provider: Option<&str>,
    session_agent: &Option<String>,
    session_is_headless: bool,
) -> Option<UnifiedMessage> {
    let value: Value = serde_json::from_str(line).ok()?;
    if let Some(model) = extract_model_from_value(&value) {
        *current_model = Some(model);
    }
    let usage = value
        .get("usage")
        .or_else(|| value.get("data").and_then(|data| data.get("usage")))
        .or_else(|| value.get("result").and_then(|data| data.get("usage")))
        .or_else(|| value.get("response").and_then(|data| data.get("usage")))?;
    let cached = extract_i64(usage.get("cached_input_tokens"))
        .or_else(|| extract_i64(usage.get("cache_read_input_tokens")))
        .or_else(|| extract_i64(usage.get("cached_tokens")))
        .unwrap_or(0)
        .max(0);
    let input = extract_i64(usage.get("input_tokens"))
        .or_else(|| extract_i64(usage.get("prompt_tokens")))
        .or_else(|| extract_i64(usage.get("input")))
        .unwrap_or(0)
        .max(0);
    let output = extract_i64(usage.get("output_tokens"))
        .or_else(|| extract_i64(usage.get("completion_tokens")))
        .or_else(|| extract_i64(usage.get("output")))
        .unwrap_or(0)
        .max(0);
    if input == 0 && output == 0 && cached == 0 {
        return None;
    }
    let model = extract_model_from_value(&value)
        .or_else(|| current_model.clone())
        .unwrap_or_else(|| "unknown".to_string());
    let timestamp = value
        .get("timestamp")
        .or_else(|| value.get("time"))
        .or_else(|| value.get("created_at"))
        .or_else(|| value.get("data").and_then(|data| data.get("timestamp")))
        .and_then(parse_timestamp_value)
        .unwrap_or(fallback_timestamp);
    let provider = session_provider
        .or_else(|| inferred_provider_from_model(&model))
        .unwrap_or("openai");
    let agent = if session_is_headless {
        Some("headless".to_string())
    } else {
        session_agent.clone()
    };
    let mut message = UnifiedMessage::new_with_agent(
        "codex",
        &model,
        provider,
        session_id,
        timestamp,
        TokenBreakdown {
            input: input.saturating_sub(cached),
            output,
            cache_read: cached,
            cache_write: 0,
            reasoning: 0,
        },
        0.0,
        agent,
    );
    message.set_content_preview(
        value
            .get("input")
            .or_else(|| value.get("prompt"))
            .or_else(|| value.get("message"))
            .or_else(|| value.get("data").and_then(|data| data.get("input")))
            .and_then(content_preview_from_value),
    );
    Some(message)
}

fn extract_model_from_value(value: &Value) -> Option<String> {
    extract_string(value.get("model"))
        .or_else(|| extract_string(value.get("model_name")))
        .or_else(|| {
            value
                .get("data")
                .and_then(|data| extract_string(data.get("model")))
        })
        .or_else(|| {
            value
                .get("data")
                .and_then(|data| extract_string(data.get("model_name")))
        })
        .or_else(|| {
            value
                .get("response")
                .and_then(|response| extract_string(response.get("model")))
        })
}

fn extract_i64(value: Option<&Value>) -> Option<i64> {
    value.and_then(|value| {
        value
            .as_i64()
            .or_else(|| value.as_u64().and_then(|number| i64::try_from(number).ok()))
            .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
    })
}

fn extract_string(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
        .map(str::to_string)
}

fn parse_timestamp_value(value: &Value) -> Option<i64> {
    extract_i64(Some(value)).or_else(|| {
        value
            .as_str()
            .and_then(|text| chrono::DateTime::parse_from_rfc3339(text).ok())
            .map(|date_time| date_time.timestamp_millis())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn parse(lines: &str) -> Vec<UnifiedMessage> {
        parse_codex_reader(
            Cursor::new(lines.as_bytes()),
            "physical-session",
            1_700_000_000_000,
            CodexParseState::default(),
        )
        .unwrap()
    }

    fn token_line(
        timestamp: &str,
        total: (i64, i64, i64, i64),
        last: (i64, i64, i64, i64),
    ) -> String {
        serde_json::json!({
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": total.0,
                        "output_tokens": total.1,
                        "cached_input_tokens": total.2,
                        "reasoning_output_tokens": total.3
                    },
                    "last_token_usage": {
                        "input_tokens": last.0,
                        "output_tokens": last.1,
                        "cached_input_tokens": last.2,
                        "reasoning_output_tokens": last.3
                    }
                }
            }
        })
        .to_string()
    }

    fn service_tier_line(service_tier: &str) -> String {
        serde_json::json!({
            "type": "event_msg",
            "payload": {
                "type": "thread_settings_applied",
                "thread_settings": {"service_tier": service_tier}
            }
        })
        .to_string()
    }

    #[test]
    fn homogeneous_fast_tier_backfills_usage_before_the_first_snapshot() {
        let lines = format!(
            "{}\n{}\n{}\n{}\n{}\n",
            r#"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            token_line("2026-01-01T00:00:01Z", (10, 2, 0, 0), (10, 2, 0, 0)),
            service_tier_line("priority"),
            token_line("2026-01-01T00:00:02Z", (20, 4, 0, 0), (10, 2, 0, 0)),
            service_tier_line("fast")
        );

        let messages = parse(&lines);

        assert_eq!(messages.len(), 2);
        assert!(messages
            .iter()
            .all(|message| message.service_tier == ServiceTier::Fast));
    }

    #[test]
    fn homogeneous_standard_tier_backfills_usage_before_the_first_snapshot() {
        let lines = format!(
            "{}\n{}\n{}\n{}\n",
            r#"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            token_line("2026-01-01T00:00:01Z", (10, 2, 0, 0), (10, 2, 0, 0)),
            service_tier_line("default"),
            service_tier_line("standard")
        );

        assert_eq!(parse(&lines)[0].service_tier, ServiceTier::Standard);
    }

    #[test]
    fn tier_switches_follow_the_timeline_without_backfilling_the_prefix() {
        let lines = format!(
            "{}\n{}\n{}\n{}\n{}\n{}\n",
            r#"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            token_line("2026-01-01T00:00:01Z", (10, 2, 0, 0), (10, 2, 0, 0)),
            service_tier_line("priority"),
            token_line("2026-01-01T00:00:02Z", (20, 4, 0, 0), (10, 2, 0, 0)),
            service_tier_line("default"),
            token_line("2026-01-01T00:00:03Z", (30, 6, 0, 0), (10, 2, 0, 0))
        );

        let tiers = parse(&lines)
            .into_iter()
            .map(|message| message.service_tier)
            .collect::<Vec<_>>();

        assert_eq!(
            tiers,
            vec![
                ServiceTier::Unknown,
                ServiceTier::Fast,
                ServiceTier::Standard
            ]
        );
    }

    #[test]
    fn forked_child_inherits_the_last_tier_from_parent_replay() {
        let lines = format!(
            "{}\n{}\n{}\n{}\n{}\n{}\n{}\n",
            r#"{"type":"session_meta","payload":{"id":"019e5c03-1e99-7000-8000-0000000000ff","forked_from_id":"019e5b00-0000-7000-8000-000000000001","source":{"subagent":{"thread_spawn":{"parent_thread_id":"019e5b00-0000-7000-8000-000000000001","depth":1}}},"model_provider":"openai"}}"#,
            r#"{"type":"session_meta","payload":{"id":"019e5b00-0000-7000-8000-000000000001","source":"vscode"}}"#,
            service_tier_line("default"),
            service_tier_line("priority"),
            r#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"019e5c03-6425-7000-8000-000000000001"}}"#,
            r#"{"type":"turn_context","payload":{"turn_id":"019e5c03-6425-7000-8000-000000000001","model":"gpt-5.6-sol"}}"#,
            token_line("2026-01-01T00:00:02Z", (10, 2, 0, 0), (10, 2, 0, 0))
        );

        let messages = parse(&lines);

        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].service_tier, ServiceTier::Fast);
    }

    #[test]
    fn parses_legacy_headless_usage_and_nested_aliases() {
        let lines = concat!(
            r#"{"type":"session_meta","payload":{"source":"exec","model_provider":"custom"}}"#,
            "\n",
            r#"{"data":{"model_name":"gpt-5.4-mini","timestamp":"2026-01-01T00:00:02Z","usage":{"input":100,"output":20,"cached_tokens":60},"input":"legacy prompt"}}"#,
            "\n"
        );

        let messages = parse(lines);

        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].model_id, "gpt-5.4-mini");
        assert_eq!(messages[0].provider_id, "custom");
        assert_eq!(messages[0].agent.as_deref(), Some("headless"));
        assert_eq!(messages[0].tokens.input, 40);
        assert_eq!(messages[0].tokens.cache_read, 60);
        assert_eq!(messages[0].tokens.output, 20);
        assert_eq!(
            messages[0].content_preview.as_deref(),
            Some("legacy prompt")
        );
    }

    #[test]
    fn read_error_keeps_messages_from_the_valid_prefix() {
        let valid = format!(
            "{}\n{}\n",
            r#"{"type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            token_line("2026-01-01T00:00:02Z", (10, 2, 0, 0), (10, 2, 0, 0))
        );
        let mut bytes = valid.into_bytes();
        bytes.extend_from_slice(&[0xff, b'\n']);

        let messages = parse_codex_reader(
            Cursor::new(bytes),
            "physical-session",
            1_700_000_000_000,
            CodexParseState::default(),
        )
        .unwrap();

        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].tokens.input, 10);
        assert_eq!(messages[0].tokens.output, 2);
    }

    #[test]
    fn parses_turn_preview_and_disjoint_input_cache() {
        let lines = format!(
            "{}\n{}\n{}\n{}\n",
            r#"{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"root","model_provider":"openai","cwd":"/tmp/project"}}"#,
            r#"{"timestamp":"2026-01-01T00:00:01Z","type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            r#"{"timestamp":"2026-01-01T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"  Build this\nnow "}}"#,
            token_line("2026-01-01T00:00:02Z", (100, 20, 60, 5), (100, 20, 60, 5))
        );
        let messages = parse(&lines);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].tokens.input, 40);
        assert_eq!(messages[0].tokens.cache_read, 60);
        assert_eq!(messages[0].tokens.output, 20);
        assert_eq!(messages[0].tokens.reasoning, 5);
        assert!(messages[0].is_turn_start);
        assert_eq!(
            messages[0].content_preview.as_deref(),
            Some("Build this now")
        );
        assert_eq!(messages[0].workspace_label.as_deref(), Some("project"));
    }

    #[test]
    fn system_context_does_not_start_a_turn() {
        let lines = format!(
            "{}\n{}\n{}\n",
            r#"{"type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            r#"{"type":"event_msg","payload":{"type":"user_message","message":"<environment_context>internal</environment_context>"}}"#,
            token_line("2026-01-01T00:00:02Z", (10, 2, 0, 0), (10, 2, 0, 0))
        );
        assert!(!parse(&lines)[0].is_turn_start);
    }

    #[test]
    fn first_resumed_snapshot_uses_last_not_total() {
        let lines = format!(
            "{}\n{}\n",
            r#"{"type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            token_line(
                "2026-01-01T00:00:02Z",
                (1_000, 200, 500, 40),
                (100, 20, 50, 4)
            )
        );
        let message = &parse(&lines)[0];
        assert_eq!(message.tokens.input, 50);
        assert_eq!(message.tokens.cache_read, 50);
        assert_eq!(message.tokens.output, 20);
    }

    #[test]
    fn repeated_cumulative_total_is_not_counted_twice() {
        let lines = format!(
            "{}\n{}\n{}\n",
            r#"{"type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            token_line("2026-01-01T00:00:01Z", (100, 30, 20, 5), (100, 30, 20, 5)),
            token_line("2026-01-01T00:00:02Z", (100, 30, 20, 5), (100, 30, 20, 5))
        );
        let messages = parse(&lines);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].tokens.total(), 135);
    }

    #[test]
    fn stale_cumulative_regression_is_skipped_before_recovery() {
        let lines = format!(
            "{}\n{}\n{}\n{}\n{}\n",
            r#"{"type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            token_line("2026-01-01T00:00:01Z", (100, 30, 20, 5), (100, 30, 20, 5)),
            token_line("2026-01-01T00:00:02Z", (110, 33, 22, 6), (10, 3, 2, 1)),
            token_line("2026-01-01T00:00:03Z", (109, 32, 21, 6), (9, 2, 1, 0)),
            token_line("2026-01-01T00:00:04Z", (119, 35, 23, 6), (10, 3, 2, 0))
        );
        let messages = parse(&lines);
        assert_eq!(messages.len(), 3);
        assert_eq!(messages[2].tokens.input, 8);
        assert_eq!(messages[2].tokens.cache_read, 2);
        assert_eq!(messages[2].tokens.output, 3);
    }

    #[test]
    fn zero_snapshot_does_not_reset_the_cumulative_baseline() {
        let lines = format!(
            "{}\n{}\n{}\n{}\n",
            r#"{"type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            token_line("2026-01-01T00:00:01Z", (500, 80, 50, 10), (500, 80, 50, 10)),
            token_line("2026-01-01T00:00:02Z", (0, 0, 0, 0), (0, 0, 0, 0)),
            token_line("2026-01-01T00:00:03Z", (510, 83, 52, 11), (10, 3, 2, 1))
        );
        let messages = parse(&lines);
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[1].tokens.input, 8);
        assert_eq!(messages[1].tokens.cache_read, 2);
        assert_eq!(messages[1].tokens.output, 3);
        assert_eq!(messages[1].tokens.reasoning, 1);
    }

    #[test]
    fn compaction_reset_uses_last_increment() {
        let lines = format!(
            "{}\n{}\n{}\n",
            r#"{"type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            token_line(
                "2026-01-01T00:00:01Z",
                (1_000, 200, 500, 40),
                (100, 20, 50, 4)
            ),
            token_line("2026-01-01T00:00:02Z", (100, 20, 50, 4), (10, 2, 5, 1))
        );
        let messages = parse(&lines);
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[1].tokens.input, 5);
        assert_eq!(messages[1].tokens.cache_read, 5);
    }

    #[test]
    fn subagent_captures_output_preview() {
        let lines = format!(
            "{}\n{}\n{}\n{}\n",
            r#"{"type":"session_meta","payload":{"id":"child","forked_from_id":"root","thread_source":"subagent","source":"vscode","agent_nickname":"worker"}}"#,
            r#"{"type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            r#"{"type":"event_msg","payload":{"type":"agent_message","message":"finished work"}}"#,
            token_line("2026-01-01T00:00:02Z", (10, 2, 0, 0), (10, 2, 0, 0))
        );
        let message = &parse(&lines)[0];
        assert_eq!(message.agent.as_deref(), Some("worker"));
        assert_eq!(message.output_preview.as_deref(), Some("finished work"));
    }

    #[test]
    fn forked_child_skips_parent_replay_and_counts_its_own_turn() {
        let lines = concat!(
            r#"{"timestamp":"2026-05-05T21:52:10.000Z","type":"session_meta","payload":{"id":"019e5c03-1e99-7000-8000-0000000000ff","forked_from_id":"019e5b00-0000-7000-8000-000000000001","source":{"subagent":{"thread_spawn":{"parent_thread_id":"019e5b00-0000-7000-8000-000000000001","depth":1}}},"model_provider":"openai","agent_nickname":"worker"}}"#,
            "\n",
            r#"{"timestamp":"2026-05-05T21:52:10.001Z","type":"session_meta","payload":{"id":"019e5b00-0000-7000-8000-000000000001","source":"vscode","model_provider":"openai"}}"#,
            "\n",
            r#"{"timestamp":"2026-05-05T21:52:10.100Z","type":"turn_context","payload":{"turn_id":"019e5b00-0001-7000-8000-000000000001","model":"gpt-5.5"}}"#,
            "\n",
            r#"{"timestamp":"2026-05-05T21:52:10.200Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"output_tokens":50,"total_tokens":550},"last_token_usage":{"input_tokens":500,"output_tokens":50,"total_tokens":550}}}}"#,
            "\n",
            r#"{"timestamp":"2026-05-05T21:52:20.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"019e5c03-6425-7000-8000-000000000001"}}"#,
            "\n",
            r#"{"timestamp":"2026-05-05T21:52:20.100Z","type":"turn_context","payload":{"turn_id":"019e5c03-6425-7000-8000-000000000001","model":"gpt-5.5"}}"#,
            "\n",
            r#"{"timestamp":"2026-05-05T21:52:20.200Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":520,"output_tokens":52,"total_tokens":572},"last_token_usage":{"input_tokens":20,"output_tokens":2,"total_tokens":22}}}}"#,
            "\n"
        );
        let messages = parse(lines);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].tokens.input, 20);
        assert_eq!(messages[0].tokens.output, 2);
        assert_eq!(messages[0].agent.as_deref(), Some("worker"));
    }
}
