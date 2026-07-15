use chrono::TimeZone;
use serde::{Deserialize, Serialize};

const CONTENT_PREVIEW_MAX_CHARS: usize = 160;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenBreakdown {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub reasoning: i64,
}

impl TokenBreakdown {
    pub fn total(&self) -> i64 {
        self.input
            .saturating_add(self.output)
            .saturating_add(self.cache_read)
            .saturating_add(self.cache_write)
            .saturating_add(self.reasoning)
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenCostBreakdown {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_write: f64,
    pub reasoning: f64,
}

impl TokenCostBreakdown {
    pub fn total(&self) -> f64 {
        self.input + self.output + self.cache_read + self.cache_write + self.reasoning
    }

    pub fn scaled(self, multiplier: f64) -> Option<Self> {
        let scaled = Self {
            input: self.input * multiplier,
            output: self.output * multiplier,
            cache_read: self.cache_read * multiplier,
            cache_write: self.cache_write * multiplier,
            reasoning: self.reasoning * multiplier,
        };
        scaled.is_valid().then_some(scaled)
    }

    pub fn add_assign(&mut self, other: &Self) {
        self.input = add_cost(self.input, other.input);
        self.output = add_cost(self.output, other.output);
        self.cache_read = add_cost(self.cache_read, other.cache_read);
        self.cache_write = add_cost(self.cache_write, other.cache_write);
        self.reasoning = add_cost(self.reasoning, other.reasoning);
    }

    fn is_valid(&self) -> bool {
        [
            self.input,
            self.output,
            self.cache_read,
            self.cache_write,
            self.reasoning,
        ]
        .into_iter()
        .all(|cost| cost.is_finite() && cost >= 0.0)
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

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CostSource {
    #[default]
    Unknown,
    ProviderReported,
    Estimated,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ServiceTier {
    #[default]
    Unknown,
    Standard,
    Fast,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UnifiedMessage {
    pub client: String,
    pub model_id: String,
    pub provider_id: String,
    pub session_id: String,
    pub workspace_key: Option<String>,
    pub workspace_label: Option<String>,
    #[serde(default)]
    pub session_path: Option<String>,
    pub timestamp: i64,
    pub date: String,
    pub tokens: TokenBreakdown,
    pub cost: f64,
    #[serde(default)]
    pub token_costs: Option<TokenCostBreakdown>,
    #[serde(default)]
    pub cost_source: CostSource,
    #[serde(default)]
    pub service_tier: ServiceTier,
    #[serde(default)]
    pub duration_ms: Option<i64>,
    #[serde(default = "default_message_count")]
    pub message_count: i32,
    pub agent: Option<String>,
    pub dedup_key: Option<String>,
    #[serde(default)]
    pub content_preview: Option<String>,
    #[serde(default)]
    pub output_preview: Option<String>,
    #[serde(default)]
    pub is_turn_start: bool,
}

const fn default_message_count() -> i32 {
    1
}

impl UnifiedMessage {
    #[allow(clippy::too_many_arguments)]
    pub fn new_with_agent(
        client: impl Into<String>,
        model_id: impl Into<String>,
        provider_id: impl Into<String>,
        session_id: impl Into<String>,
        timestamp: i64,
        tokens: TokenBreakdown,
        cost: f64,
        agent: Option<String>,
    ) -> Self {
        Self {
            client: client.into(),
            model_id: model_id.into(),
            provider_id: provider_id.into(),
            session_id: session_id.into(),
            workspace_key: None,
            workspace_label: None,
            session_path: None,
            timestamp,
            date: timestamp_to_date(timestamp),
            tokens,
            cost,
            token_costs: None,
            cost_source: CostSource::Unknown,
            service_tier: ServiceTier::Unknown,
            duration_ms: None,
            message_count: 1,
            agent,
            dedup_key: None,
            content_preview: None,
            output_preview: None,
            is_turn_start: false,
        }
    }

    pub fn set_workspace(
        &mut self,
        workspace_key: Option<String>,
        workspace_label: Option<String>,
    ) {
        self.workspace_key = workspace_key;
        self.workspace_label = workspace_label;
    }

    pub fn refresh_derived_fields(&mut self) {
        self.date = timestamp_to_date(self.timestamp);
    }

    pub fn set_content_preview(&mut self, preview: Option<String>) {
        self.content_preview = preview;
    }

    pub fn set_output_preview(&mut self, preview: Option<String>) {
        self.output_preview = preview;
    }
}

pub fn content_preview_from_str(text: &str) -> Option<String> {
    let mut out = String::new();
    let mut previous_was_space = false;
    let mut truncated = false;

    for ch in text.chars() {
        if ch.is_control() && ch != '\n' && ch != '\t' && ch != '\r' {
            continue;
        }

        if ch.is_whitespace() {
            if !previous_was_space && !out.is_empty() {
                out.push(' ');
                previous_was_space = true;
            }
            continue;
        }

        if out.chars().count() >= CONTENT_PREVIEW_MAX_CHARS {
            truncated = true;
            break;
        }

        out.push(ch);
        previous_was_space = false;
    }

    let trimmed = out.trim();
    if trimmed.is_empty() {
        return None;
    }

    if truncated {
        Some(format!("{trimmed}..."))
    } else {
        Some(trimmed.to_string())
    }
}

pub fn content_preview_from_value(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(text) => content_preview_from_str(text),
        serde_json::Value::Array(items) => items.iter().find_map(content_preview_from_value),
        serde_json::Value::Object(map) => {
            for key in ["text", "content", "message", "input"] {
                if let Some(preview) = map.get(key).and_then(content_preview_from_value) {
                    return Some(preview);
                }
            }
            None
        }
        _ => None,
    }
}

pub fn normalize_workspace_key(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    let preserve_unc_prefix = trimmed.starts_with("\\\\") || trimmed.starts_with("//");
    let mut normalized = trimmed.replace('\\', "/");

    if preserve_unc_prefix {
        let body = normalized.trim_start_matches('/');
        let mut collapsed = body.to_string();
        while collapsed.contains("//") {
            collapsed = collapsed.replace("//", "/");
        }
        normalized = format!("//{collapsed}");
    } else {
        while normalized.contains("//") {
            normalized = normalized.replace("//", "/");
        }
    }

    let minimum_len = if preserve_unc_prefix { 2 } else { 1 };
    if normalized.len() > minimum_len {
        normalized = normalized.trim_end_matches('/').to_string();
    }

    (!normalized.is_empty()).then_some(normalized)
}

pub fn workspace_label_from_key(key: &str) -> Option<String> {
    key.rsplit('/')
        .find(|segment| !segment.is_empty())
        .map(str::to_string)
}

pub fn normalize_model_for_grouping(model_id: &str) -> String {
    let mut name = model_id.trim().to_ascii_lowercase();
    for prefix in ["openai/", "openai_codex/"] {
        if let Some(model) = name.strip_prefix(prefix) {
            name = model.to_string();
            break;
        }
    }
    if let Some(base) = strip_reasoning_tier(&name) {
        name = base.to_string();
    }

    for suffix in [
        "-minimal", "-medium", "-xhigh", "-high", "-auto", "-none", "-low", "-fast",
    ] {
        if name.ends_with(suffix) {
            name.truncate(name.len() - suffix.len());
            break;
        }
    }

    if let Some(base) = strip_date_snapshot(&name) {
        name = base.to_string();
    }
    name
}

fn strip_reasoning_tier(model_id: &str) -> Option<&str> {
    let without_closing_paren = model_id.strip_suffix(')')?;
    let (base_model, tier) = without_closing_paren.rsplit_once('(')?;
    if base_model.is_empty() || base_model.trim() != base_model {
        return None;
    }
    matches!(
        tier,
        "minimal" | "low" | "medium" | "high" | "xhigh" | "auto" | "none" | "fast"
    )
    .then_some(base_model)
}

fn strip_date_snapshot(model_id: &str) -> Option<&str> {
    if let Some((base, compact_date)) = model_id.rsplit_once('-') {
        if compact_date.len() == 8 && compact_date.bytes().all(|byte| byte.is_ascii_digit()) {
            return Some(base);
        }
    }

    if let Some(date_start) = model_id.len().checked_sub(10) {
        let date = model_id.get(date_start..)?;
        let base = model_id.get(..date_start)?.strip_suffix('-')?;
        let bytes = date.as_bytes();
        if date.is_ascii()
            && bytes[4] == b'-'
            && bytes[7] == b'-'
            && bytes
                .iter()
                .enumerate()
                .all(|(index, byte)| matches!(index, 4 | 7) || byte.is_ascii_digit())
        {
            return Some(base);
        }
    }
    None
}

fn timestamp_to_date(timestamp_ms: i64) -> String {
    match chrono::Local.timestamp_millis_opt(timestamp_ms) {
        chrono::LocalResult::Single(date_time) => date_time.format("%Y-%m-%d").to_string(),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_total_saturates() {
        let tokens = TokenBreakdown {
            input: i64::MAX,
            output: 1,
            ..Default::default()
        };
        assert_eq!(tokens.total(), i64::MAX);
    }

    #[test]
    fn model_grouping_strips_reasoning_tier() {
        assert_eq!(
            normalize_model_for_grouping("fictional-1(high)"),
            "fictional-1"
        );
        assert_eq!(
            normalize_model_for_grouping("fictional-1(unknown)"),
            "fictional-1(unknown)"
        );
    }

    #[test]
    fn model_grouping_normalizes_codex_prefix_modes_and_snapshots() {
        assert_eq!(
            normalize_model_for_grouping("openai/gpt-5.2-codex-fast"),
            "gpt-5.2-codex"
        );
        assert_eq!(
            normalize_model_for_grouping("openai_codex/gpt-5.4-2026-03-05(high)"),
            "gpt-5.4"
        );
        assert_eq!(
            normalize_model_for_grouping("gpt-5.1-codex-max"),
            "gpt-5.1-codex-max"
        );
    }

    #[test]
    fn model_grouping_handles_unicode_without_invalid_string_slices() {
        assert_eq!(normalize_model_for_grouping("xé1234567"), "xé1234567");
        assert_eq!(normalize_model_for_grouping("模型-20260714"), "模型");
        assert_eq!(normalize_model_for_grouping("模型-2026-07-14"), "模型");
    }

    #[test]
    fn preview_collapses_whitespace_and_truncates() {
        assert_eq!(
            content_preview_from_str("  hello\n\tworld  ").as_deref(),
            Some("hello world")
        );
        let long = "a".repeat(CONTENT_PREVIEW_MAX_CHARS + 1);
        assert!(content_preview_from_str(&long).unwrap().ends_with("..."));
    }
}
