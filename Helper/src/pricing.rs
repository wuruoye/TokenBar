use crate::openrouter::Catalog;
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::Arc;

use chrono::{Local, NaiveDate};

use crate::usage::{CacheWriteBreakdown, ServiceTier, TokenBreakdown, TokenCostBreakdown};

const TOKENS_PER_MILLION: f64 = 1_000_000.0;
const LONG_CONTEXT_INPUT_THRESHOLD: i64 = 272_000;
const LONG_CONTEXT_INPUT_MULTIPLIER: f64 = 2.0;
const LONG_CONTEXT_OUTPUT_MULTIPLIER: f64 = 1.5;

#[derive(Debug, Clone, Copy, PartialEq)]
struct ModelRate {
    input_per_million: f64,
    cached_input_per_million: f64,
    output_per_million: f64,
    cache_write_per_million: Option<f64>,
    long_context_pricing: bool,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct AnthropicModelRate {
    input_per_million: f64,
    cache_write_5m_per_million: f64,
    cache_write_1h_per_million: f64,
    cached_input_per_million: f64,
    output_per_million: f64,
}

/// TokenBar's bundled Codex pricing catalog.
///
/// Rates are standard API text-token prices in USD per million tokens, last
/// reviewed 2026-09-05 against the official OpenAI model pages. A validated
/// OpenRouter catalog supplies current token quotes when available; bundled
/// official rates remain the offline fallback. A model without a rate returns
/// `None`; callers must keep
/// that request's cost source unknown instead of presenting a fabricated $0.
/// These values are compatibility estimates for activity comparison, not an
/// OpenAI invoice. In particular, the Codex research-preview
/// `gpt-5.3-codex-spark` id has no public per-token API rate, so it uses
/// GPT-5.3-Codex's public rate. Recognized OpenAI model ids keep their estimate
/// even when a local Codex gateway records a custom provider name.
///
/// GPT-5.4, GPT-5.5, GPT-5.6, and GPT-6 Astra apply long-context pricing to each request
/// whose raw input exceeds 272K tokens: 2x for uncached input, cached input,
/// and cache writes, plus 1.5x for output and reasoning output.
///
/// Sources:
/// - https://developers.openai.com/api/docs/models/gpt-6-astra
/// - https://developers.openai.com/api/docs/pricing
/// - https://openrouter.ai/docs/guides/overview/models
/// - https://openai.com/index/introducing-gpt-5-3-codex-spark/
/// - https://developers.openai.com/api/docs/models/codex-mini-latest
/// - https://developers.openai.com/api/docs/models/gpt-5
/// - https://developers.openai.com/api/docs/models/gpt-5-codex
/// - https://developers.openai.com/api/docs/models/gpt-5.1
/// - https://developers.openai.com/api/docs/models/gpt-5.1-codex
/// - https://developers.openai.com/api/docs/models/gpt-5.1-codex-max
/// - https://developers.openai.com/api/docs/models/gpt-5.1-codex-mini
/// - https://developers.openai.com/api/docs/models/gpt-5.2
/// - https://developers.openai.com/api/docs/models/gpt-5.2-codex
/// - https://developers.openai.com/api/docs/models/gpt-5.3-codex
/// - https://developers.openai.com/api/docs/models/gpt-5.4
/// - https://developers.openai.com/api/docs/models/gpt-5.4-mini
/// - https://developers.openai.com/api/docs/models/gpt-5.5
/// - https://developers.openai.com/api/docs/models/gpt-5.6-sol
/// - https://developers.openai.com/api/docs/models/gpt-5.6-terra
/// - https://developers.openai.com/api/docs/models/gpt-5.6-luna
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum FastPricingBasis {
    ChatGptSubscription,
    #[default]
    ApiPriority,
}

#[derive(Debug, Clone, Default)]
pub struct CodexPricing {
    fast_pricing_basis: FastPricingBasis,
    openrouter: Option<Arc<Catalog>>,
}

impl CodexPricing {
    pub const fn bundled() -> Self {
        Self::with_fast_pricing(FastPricingBasis::ApiPriority)
    }

    pub const fn with_fast_pricing(fast_pricing_basis: FastPricingBasis) -> Self {
        Self {
            fast_pricing_basis,
            openrouter: None,
        }
    }

    pub fn with_openrouter_catalog(mut self, catalog: Option<Arc<Catalog>>) -> Self {
        self.openrouter = catalog;
        self
    }

    pub fn calculate_cost_with_provider(
        &self,
        model_id: &str,
        provider_id: Option<&str>,
        usage: &TokenBreakdown,
    ) -> Option<f64> {
        self.calculate_token_costs_with_provider(model_id, provider_id, usage)
            .map(|costs| costs.total())
    }

    pub fn calculate_token_costs_with_provider(
        &self,
        model_id: &str,
        _provider_id: Option<&str>,
        usage: &TokenBreakdown,
    ) -> Option<TokenCostBreakdown> {
        let bundled = rate_for_model(model_id);
        if let Some(costs) = self.openrouter.as_ref().and_then(|catalog| {
            catalog.costs(
                "openai",
                model_id,
                usage,
                None,
                bundled.is_some_and(|r| r.long_context_pricing),
            )
        }) {
            return Some(costs);
        }
        let rate = bundled?;
        if usage.cache_write > 0 && rate.cache_write_per_million.is_none() {
            return None;
        }

        let raw_input_tokens = usage
            .input
            .max(0)
            .saturating_add(usage.cache_read.max(0))
            .saturating_add(usage.cache_write.max(0));
        let long_context =
            rate.long_context_pricing && raw_input_tokens > LONG_CONTEXT_INPUT_THRESHOLD;
        let input_multiplier = if long_context {
            LONG_CONTEXT_INPUT_MULTIPLIER
        } else {
            1.0
        };
        let output_multiplier = if long_context {
            LONG_CONTEXT_OUTPUT_MULTIPLIER
        } else {
            1.0
        };

        let costs = TokenCostBreakdown {
            input: usage.input.max(0) as f64 * rate.input_per_million * input_multiplier
                / TOKENS_PER_MILLION,
            output: usage.output.max(0) as f64 * rate.output_per_million * output_multiplier
                / TOKENS_PER_MILLION,
            cache_read: usage.cache_read.max(0) as f64
                * rate.cached_input_per_million
                * input_multiplier
                / TOKENS_PER_MILLION,
            cache_write: usage.cache_write.max(0) as f64
                * rate.cache_write_per_million.unwrap_or_default()
                * input_multiplier
                / TOKENS_PER_MILLION,
            reasoning: usage.reasoning.max(0) as f64 * rate.output_per_million * output_multiplier
                / TOKENS_PER_MILLION,
        };
        costs.total().is_finite().then_some(costs)
    }

    /// Applies the Fast multiplier for the active Codex login type to the
    /// standard API-equivalent estimate. The tier changes cost only; token and
    /// cache counts stay raw. Models without an explicitly verified multiplier
    /// keep their standard estimate instead of receiving a guessed multiplier.
    pub fn calculate_cost_with_service_tier(
        &self,
        model_id: &str,
        provider_id: Option<&str>,
        usage: &TokenBreakdown,
        service_tier: ServiceTier,
    ) -> Option<f64> {
        self.calculate_token_costs_with_service_tier(model_id, provider_id, usage, service_tier)
            .map(|costs| costs.total())
    }

    pub fn calculate_token_costs_with_service_tier(
        &self,
        model_id: &str,
        provider_id: Option<&str>,
        usage: &TokenBreakdown,
        service_tier: ServiceTier,
    ) -> Option<TokenCostBreakdown> {
        let base = self.calculate_token_costs_with_provider(model_id, provider_id, usage)?;
        let multiplier = if service_tier == ServiceTier::Fast {
            fast_cost_multiplier(model_id, self.fast_pricing_basis).unwrap_or(1.0)
        } else {
            1.0
        };
        base.scaled(multiplier)
    }
}

/// Anthropic pricing used for Claude Code compatibility estimates.
///
/// TokenBar ships a reviewed fallback catalog and can overlay a strictly
/// validated copy of Anthropic's official pricing Markdown. Unknown or future
/// model versions remain unpriced instead of silently inheriting a nearby
/// model's rate.
///
/// Source: https://platform.claude.com/docs/en/about-claude/pricing.md
#[derive(Debug, Clone)]
pub struct AnthropicPricing {
    effective_date: NaiveDate,
    official_rates: HashMap<String, AnthropicModelRate>,
    openrouter: Option<Arc<Catalog>>,
}

impl Default for AnthropicPricing {
    fn default() -> Self {
        Self::bundled_for_date(Local::now().date_naive())
    }
}

impl AnthropicPricing {
    pub fn bundled_for_date(effective_date: NaiveDate) -> Self {
        Self {
            effective_date,
            official_rates: HashMap::new(),
            openrouter: None,
        }
    }

    pub fn from_official_markdown(
        markdown: &str,
        effective_date: NaiveDate,
    ) -> Result<Self, String> {
        Ok(Self {
            effective_date,
            official_rates: parse_official_anthropic_rates(markdown, effective_date)?,
            openrouter: None,
        })
    }

    pub fn from_official_markdown_file(
        path: &Path,
        effective_date: NaiveDate,
    ) -> Result<Self, String> {
        let markdown = fs::read_to_string(path)
            .map_err(|error| format!("could not read Anthropic pricing catalog: {error}"))?;
        Self::from_official_markdown(&markdown, effective_date)
    }

    pub fn calculate_token_costs(
        &self,
        model_id: &str,
        usage: &TokenBreakdown,
    ) -> Option<TokenCostBreakdown> {
        self.calculate_token_costs_with_cache_writes(model_id, usage, None)
    }

    pub fn with_openrouter_catalog(mut self, catalog: Option<Arc<Catalog>>) -> Self {
        self.openrouter = catalog;
        self
    }

    pub fn calculate_token_costs_with_cache_writes(
        &self,
        model_id: &str,
        usage: &TokenBreakdown,
        cache_writes: Option<&CacheWriteBreakdown>,
    ) -> Option<TokenCostBreakdown> {
        if let Some(costs) = self
            .openrouter
            .as_ref()
            .and_then(|catalog| catalog.costs("anthropic", model_id, usage, cache_writes, false))
        {
            return Some(costs);
        }
        let rate = self.rate_for_model(model_id)?;
        let cache_write = anthropic_cache_write_cost(usage.cache_write, cache_writes, rate);
        let costs = TokenCostBreakdown {
            input: usage.input.max(0) as f64 * rate.input_per_million / TOKENS_PER_MILLION,
            output: usage.output.max(0) as f64 * rate.output_per_million / TOKENS_PER_MILLION,
            cache_read: usage.cache_read.max(0) as f64 * rate.cached_input_per_million
                / TOKENS_PER_MILLION,
            cache_write,
            reasoning: usage.reasoning.max(0) as f64 * rate.output_per_million / TOKENS_PER_MILLION,
        };
        costs.total().is_finite().then_some(costs)
    }

    fn rate_for_model(&self, model_id: &str) -> Option<AnthropicModelRate> {
        let normalized = normalize_anthropic_model_id(model_id);
        self.official_rates
            .get(&normalized)
            .copied()
            .or_else(|| bundled_anthropic_rate(&normalized, self.effective_date))
    }
}

fn bundled_anthropic_rate(
    normalized_model_id: &str,
    effective_date: NaiveDate,
) -> Option<AnthropicModelRate> {
    let (input, cache_write_5m, cache_write_1h, cache_read, output) = match normalized_model_id {
        "claude-fable-5" | "claude-mythos-5" => (10.0, 12.5, 20.0, 1.0, 50.0),
        "claude-opus-5" | "claude-opus-4-5" | "claude-opus-4-6" | "claude-opus-4-7"
        | "claude-opus-4-8" => (5.0, 6.25, 10.0, 0.5, 25.0),
        "claude-opus-4" | "claude-opus-4-1" | "claude-3-opus" => (15.0, 18.75, 30.0, 1.5, 75.0),
        "claude-sonnet-5" if effective_date <= NaiveDate::from_ymd_opt(2026, 8, 31).unwrap() => {
            (2.0, 2.5, 4.0, 0.2, 10.0)
        }
        "claude-sonnet-5" | "claude-sonnet-4" | "claude-sonnet-4-5" | "claude-sonnet-4-6"
        | "claude-3-7-sonnet" | "claude-3-5-sonnet" => (3.0, 3.75, 6.0, 0.3, 15.0),
        "claude-haiku-4-5" | "claude-haiku-4-6" => (1.0, 1.25, 2.0, 0.1, 5.0),
        "claude-3-5-haiku" => (0.8, 1.0, 1.6, 0.08, 4.0),
        "claude-3-haiku" => (0.25, 0.3, 0.5, 0.03, 1.25),
        _ => return None,
    };
    Some(AnthropicModelRate {
        input_per_million: input,
        cache_write_5m_per_million: cache_write_5m,
        cache_write_1h_per_million: cache_write_1h,
        cached_input_per_million: cache_read,
        output_per_million: output,
    })
}

fn anthropic_cache_write_cost(
    total_cache_write: i64,
    breakdown: Option<&CacheWriteBreakdown>,
    rate: AnthropicModelRate,
) -> f64 {
    let total = total_cache_write.max(0);
    let one_hour = breakdown
        .map(|value| value.one_hour.max(0).min(total))
        .unwrap_or(0);
    let remaining = total.saturating_sub(one_hour);
    let five_minute = breakdown
        .map(|value| value.five_minute.max(0).min(remaining))
        .unwrap_or(0);
    let unclassified = remaining.saturating_sub(five_minute);
    (one_hour as f64 * rate.cache_write_1h_per_million
        + five_minute.saturating_add(unclassified) as f64 * rate.cache_write_5m_per_million)
        / TOKENS_PER_MILLION
}

fn parse_official_anthropic_rates(
    markdown: &str,
    effective_date: NaiveDate,
) -> Result<HashMap<String, AnthropicModelRate>, String> {
    let mut lines = markdown.lines();
    let Some(header) = lines.find(|line| {
        line.trim_start().starts_with("| Model")
            && line.contains("Base Input Tokens")
            && line.contains("5m Cache Writes")
            && line.contains("1h Cache Writes")
            && line.contains("Cache Hits & Refreshes")
            && line.contains("Output Tokens")
    }) else {
        return Err("official Anthropic pricing table header was not found".to_string());
    };
    if markdown_table_cells(header).len() != 6 {
        return Err("official Anthropic pricing table has an unexpected schema".to_string());
    }

    let mut rates = HashMap::new();
    for line in lines {
        let trimmed = line.trim();
        if !trimmed.starts_with('|') {
            if !rates.is_empty() {
                break;
            }
            continue;
        }
        if trimmed.starts_with("| -") {
            continue;
        }
        let cells = markdown_table_cells(trimmed);
        if cells.len() != 6 {
            continue;
        }
        let label = cells[0];
        if !official_pricing_row_applies(label, effective_date) {
            continue;
        }
        let Some(model_id) = official_model_id(label) else {
            continue;
        };
        let Some(rate) = official_rate_from_cells(&cells) else {
            return Err(format!(
                "official Anthropic pricing row is invalid: {label}"
            ));
        };
        rates.insert(model_id, rate);
    }

    if rates.len() < 5 {
        return Err("official Anthropic pricing table contained too few valid models".to_string());
    }
    Ok(rates)
}

fn markdown_table_cells(line: &str) -> Vec<&str> {
    line.trim()
        .trim_matches('|')
        .split('|')
        .map(str::trim)
        .collect()
}

fn official_model_id(label: &str) -> Option<String> {
    let mut words = label.split_whitespace();
    if words.next()? != "Claude" {
        return None;
    }
    let family = words.next()?.to_ascii_lowercase();
    if !matches!(
        family.as_str(),
        "fable" | "mythos" | "opus" | "sonnet" | "haiku"
    ) {
        return None;
    }
    let version = words
        .next()?
        .trim_matches(|character: char| !character.is_ascii_digit() && character != '.');
    if version.is_empty()
        || !version
            .chars()
            .all(|character| character.is_ascii_digit() || character == '.')
    {
        return None;
    }
    Some(format!("claude-{family}-{}", version.replace('.', "-")))
}

fn official_pricing_row_applies(label: &str, effective_date: NaiveDate) -> bool {
    if let Some((_, remainder)) = label.split_once("[through ") {
        let Some((date, _)) = remainder.split_once(']') else {
            return false;
        };
        return parse_english_date(date).is_some_and(|date| effective_date <= date);
    }
    if let Some((_, date)) = label.split_once(" starting ") {
        return parse_english_date(date).is_some_and(|date| effective_date >= date);
    }
    true
}

fn parse_english_date(value: &str) -> Option<NaiveDate> {
    let value = value.trim();
    NaiveDate::parse_from_str(value, "%B %d, %Y")
        .or_else(|_| NaiveDate::parse_from_str(value, "%B %e, %Y"))
        .ok()
}

fn official_rate_from_cells(cells: &[&str]) -> Option<AnthropicModelRate> {
    let rate = AnthropicModelRate {
        input_per_million: parse_usd_per_mtok(cells.get(1)?)?,
        cache_write_5m_per_million: parse_usd_per_mtok(cells.get(2)?)?,
        cache_write_1h_per_million: parse_usd_per_mtok(cells.get(3)?)?,
        cached_input_per_million: parse_usd_per_mtok(cells.get(4)?)?,
        output_per_million: parse_usd_per_mtok(cells.get(5)?)?,
    };
    (rate.input_per_million > 0.0
        && rate.cache_write_5m_per_million >= rate.input_per_million
        && rate.cache_write_1h_per_million >= rate.cache_write_5m_per_million
        && rate.cached_input_per_million > 0.0
        && rate.cached_input_per_million <= rate.input_per_million
        && rate.output_per_million >= rate.input_per_million)
        .then_some(rate)
}

fn parse_usd_per_mtok(value: &str) -> Option<f64> {
    let value = value.trim();
    if !value.ends_with("/ MTok") {
        return None;
    }
    let number = value.strip_prefix('$')?.split_whitespace().next()?;
    let price = number.replace(',', "").parse::<f64>().ok()?;
    (price.is_finite() && price > 0.0 && price <= 1_000.0).then_some(price)
}

pub(crate) fn normalize_anthropic_model_id(model_id: &str) -> String {
    let mut normalized = model_id.trim().to_ascii_lowercase().replace('.', "-");
    for prefix in [
        "anthropic/",
        "vertex_ai/",
        "vertex/",
        "bedrock/",
        "us-anthropic-",
        "eu-anthropic-",
        "global-anthropic-",
        "anthropic-",
    ] {
        if let Some(model) = normalized.strip_prefix(prefix) {
            normalized = model.to_string();
            break;
        }
    }
    if let Some(index) = normalized.find("-20") {
        normalized.truncate(index);
    }
    if let Some(index) = normalized.find("-v1") {
        normalized.truncate(index);
    }
    for suffix in ["-thinking", "-fast"] {
        if let Some(model) = normalized.strip_suffix(suffix) {
            normalized = model.to_string();
        }
    }

    for (alias, canonical) in [
        ("claude-5-fable", "claude-fable-5"),
        ("claude-5-mythos", "claude-mythos-5"),
        ("claude-5-opus", "claude-opus-5"),
        ("claude-5-sonnet", "claude-sonnet-5"),
        ("claude-4-8-opus", "claude-opus-4-8"),
        ("claude-4-7-opus", "claude-opus-4-7"),
        ("claude-4-6-opus", "claude-opus-4-6"),
        ("claude-4-5-opus", "claude-opus-4-5"),
        ("claude-4-6-sonnet", "claude-sonnet-4-6"),
        ("claude-4-5-sonnet", "claude-sonnet-4-5"),
        ("claude-4-6-haiku", "claude-haiku-4-6"),
        ("claude-4-5-haiku", "claude-haiku-4-5"),
        ("fable-5", "claude-fable-5"),
        ("mythos-5", "claude-mythos-5"),
        ("opus-5", "claude-opus-5"),
        ("sonnet-5", "claude-sonnet-5"),
        ("opus-4-8", "claude-opus-4-8"),
        ("opus-4-7", "claude-opus-4-7"),
        ("opus-4-6", "claude-opus-4-6"),
        ("opus-4-5", "claude-opus-4-5"),
        ("sonnet-4-6", "claude-sonnet-4-6"),
        ("sonnet-4-5", "claude-sonnet-4-5"),
        ("haiku-4-6", "claude-haiku-4-6"),
        ("haiku-4-5", "claude-haiku-4-5"),
    ] {
        if normalized == alias {
            return canonical.to_string();
        }
    }
    normalized
}

/// Official Fast multipliers reviewed 2026-09-05:
/// - ChatGPT subscription credits: GPT-5.4 is 2x; GPT-5.5/5.6 and GPT-6 Astra are 2.5x.
/// - API Priority pricing: GPT-5.4 is 2x; GPT-5.5 is 2.5x; GPT-5.6 and GPT-6 Astra are 2x.
///
/// Sources:
/// - https://learn.chatgpt.com/docs/agent-configuration/speed#fast-mode
/// - https://developers.openai.com/api/docs/pricing
/// - https://developers.openai.com/api/docs/guides/priority-processing
fn fast_cost_multiplier(model_id: &str, basis: FastPricingBasis) -> Option<f64> {
    let normalized = normalize_pricing_model_id(model_id);
    match (basis, normalized.as_str()) {
        (FastPricingBasis::ChatGptSubscription, "gpt-6-astra") => Some(2.5),
        (FastPricingBasis::ApiPriority, "gpt-6-astra") => Some(2.0),
        (_, "gpt-5.4") => Some(2.0),
        (_, "gpt-5.5") => Some(2.5),
        (FastPricingBasis::ChatGptSubscription, "gpt-5.6" | "gpt-5.6-sol") => Some(2.5),
        (FastPricingBasis::ChatGptSubscription, "gpt-5.6-terra" | "gpt-5.6-luna") => Some(2.5),
        (FastPricingBasis::ApiPriority, "gpt-5.6" | "gpt-5.6-sol") => Some(2.0),
        (FastPricingBasis::ApiPriority, "gpt-5.6-terra" | "gpt-5.6-luna") => Some(2.0),
        _ => None,
    }
}

fn rate_for_model(model_id: &str) -> Option<ModelRate> {
    let normalized = normalize_pricing_model_id(model_id);
    match normalized.as_str() {
        "gpt-6-astra" => Some(ModelRate {
            input_per_million: 10.0,
            cached_input_per_million: 1.0,
            output_per_million: 50.0,
            cache_write_per_million: Some(12.5),
            long_context_pricing: true,
        }),
        "codex-mini-latest" => Some(ModelRate {
            input_per_million: 1.5,
            cached_input_per_million: 0.375,
            output_per_million: 6.0,
            cache_write_per_million: None,
            long_context_pricing: false,
        }),
        "gpt-5" | "gpt-5-codex" | "gpt-5.1" | "gpt-5.1-codex" | "gpt-5.1-codex-max" => {
            Some(ModelRate {
                input_per_million: 1.25,
                cached_input_per_million: 0.125,
                output_per_million: 10.0,
                cache_write_per_million: None,
                long_context_pricing: false,
            })
        }
        "gpt-5-mini" | "gpt-5.1-codex-mini" => Some(ModelRate {
            input_per_million: 0.25,
            cached_input_per_million: 0.025,
            output_per_million: 2.0,
            cache_write_per_million: None,
            long_context_pricing: false,
        }),
        "gpt-5.2" | "gpt-5.2-codex" | "gpt-5.3-codex" | "gpt-5.3-codex-spark" => Some(ModelRate {
            input_per_million: 1.75,
            cached_input_per_million: 0.175,
            output_per_million: 14.0,
            cache_write_per_million: None,
            long_context_pricing: false,
        }),
        "gpt-5.4" => Some(ModelRate {
            input_per_million: 2.5,
            cached_input_per_million: 0.25,
            output_per_million: 15.0,
            cache_write_per_million: None,
            long_context_pricing: true,
        }),
        "gpt-5.4-mini" => Some(ModelRate {
            input_per_million: 0.75,
            cached_input_per_million: 0.075,
            output_per_million: 4.5,
            cache_write_per_million: None,
            long_context_pricing: false,
        }),
        "gpt-5.5" => Some(ModelRate {
            input_per_million: 5.0,
            cached_input_per_million: 0.5,
            output_per_million: 30.0,
            cache_write_per_million: None,
            long_context_pricing: true,
        }),
        "gpt-5.6" | "gpt-5.6-sol" => Some(ModelRate {
            input_per_million: 4.0,
            cached_input_per_million: 0.4,
            output_per_million: 20.0,
            cache_write_per_million: Some(5.0),
            long_context_pricing: true,
        }),
        "gpt-5.6-terra" => Some(ModelRate {
            input_per_million: 2.0,
            cached_input_per_million: 0.2,
            output_per_million: 12.0,
            cache_write_per_million: Some(2.5),
            long_context_pricing: true,
        }),
        "gpt-5.6-luna" => Some(ModelRate {
            input_per_million: 0.2,
            cached_input_per_million: 0.02,
            output_per_million: 1.2,
            cache_write_per_million: Some(0.25),
            long_context_pricing: true,
        }),
        _ => None,
    }
}

pub(crate) fn normalize_pricing_model_id(model_id: &str) -> String {
    let mut normalized = model_id.trim().to_ascii_lowercase();
    for prefix in ["openai/", "openai_codex/"] {
        if let Some(model) = normalized.strip_prefix(prefix) {
            normalized = model.to_string();
            break;
        }
    }
    if let Some(without_paren) = normalized.strip_suffix(')') {
        if let Some((base, tier)) = without_paren.rsplit_once('(') {
            if matches!(
                tier,
                "minimal" | "low" | "medium" | "high" | "xhigh" | "auto" | "none" | "fast"
            ) {
                normalized = base.to_string();
            }
        }
    }

    const BASE_MODELS: [&str; 20] = [
        "gpt-6-astra",
        "gpt-5.1-codex-mini",
        "gpt-5.1-codex-max",
        "gpt-5.3-codex-spark",
        "codex-mini-latest",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "gpt-5.6-sol",
        "gpt-5.4-mini",
        "gpt-5.3-codex",
        "gpt-5.2-codex",
        "gpt-5.1-codex",
        "gpt-5-codex",
        "gpt-5-mini",
        "gpt-5.4",
        "gpt-5.2",
        "gpt-5.1",
        "gpt-5.5",
        "gpt-5.6",
        "gpt-5",
    ];

    for base in BASE_MODELS {
        if normalized == base || is_snapshot_of(&normalized, base) {
            return base.to_string();
        }
    }

    for suffix in [
        "-minimal", "-medium", "-xhigh", "-high", "-auto", "-none", "-low", "-fast",
    ] {
        if let Some(candidate) = normalized.strip_suffix(suffix) {
            for base in BASE_MODELS {
                if candidate == base || is_snapshot_of(candidate, base) {
                    return base.to_string();
                }
            }
        }
    }
    normalized
}

fn is_snapshot_of(model_id: &str, base: &str) -> bool {
    let Some(suffix) = model_id
        .strip_prefix(base)
        .and_then(|value| value.strip_prefix('-'))
    else {
        return false;
    };
    let compact = suffix.replace('-', "");
    compact.len() == 8 && compact.bytes().all(|byte| byte.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn remote_quotes_take_priority_and_incomplete_quotes_fall_back_as_a_whole() {
        let catalog = Catalog::from_json(br#"{"data":[
            {"id":"openai/gpt-6-astra","pricing":{"prompt":"0.000005","completion":"0.000025"}},
            {"id":"anthropic/claude-sonnet-4.5","pricing":{"prompt":"0.000001","completion":"0.000005"}}
        ]}"#).unwrap();
        let catalog = Arc::new(catalog);
        let pricing = CodexPricing::with_fast_pricing(FastPricingBasis::ChatGptSubscription)
            .with_openrouter_catalog(Some(catalog.clone()));
        let usage = TokenBreakdown {
            input: 100_000,
            output: 1_000,
            ..Default::default()
        };
        let fast = pricing
            .calculate_token_costs_with_service_tier("gpt-6-astra", None, &usage, ServiceTier::Fast)
            .unwrap();
        assert!((fast.total() - 0.525 * 2.5).abs() < 1e-9);
        let cached_usage = TokenBreakdown {
            cache_read: 100_000,
            ..usage.clone()
        };
        let fallback = pricing
            .calculate_token_costs_with_provider("gpt-6-astra", None, &cached_usage)
            .unwrap();
        // Missing remote cache rates must not mix discounted input with bundled cache prices.
        assert!((fallback.total() - 1.15).abs() < 1e-9);
        let claude = AnthropicPricing::default().with_openrouter_catalog(Some(catalog));
        let remote = claude
            .calculate_token_costs("claude-sonnet-4-5", &usage)
            .unwrap();
        assert!((remote.total() - 0.105).abs() < 1e-9);
        let fallback = claude
            .calculate_token_costs("claude-sonnet-4-5", &cached_usage)
            .unwrap();
        assert!((fallback.total() - 0.345).abs() < 1e-9);
    }

    #[test]
    fn astra_official_rates_include_context_and_distinct_fast_bases() {
        let usage = TokenBreakdown {
            input: 100000,
            cache_read: 100000,
            cache_write: 72000,
            output: 10000,
            reasoning: 5000,
        };
        let normal = CodexPricing::bundled()
            .calculate_token_costs_with_provider("gpt-6-astra", None, &usage)
            .unwrap();
        assert!((normal.input - 1.0).abs() < 1e-9);
        assert!((normal.cache_write - 0.9).abs() < 1e-9);
        assert!((normal.output - 0.5).abs() < 1e-9);
        assert!((normal.reasoning - 0.25).abs() < 1e-9);
        for (basis, factor) in [
            (FastPricingBasis::ApiPriority, 2.0),
            (FastPricingBasis::ChatGptSubscription, 2.5),
        ] {
            let fast = CodexPricing::with_fast_pricing(basis)
                .calculate_token_costs_with_service_tier(
                    "gpt-6-astra",
                    None,
                    &usage,
                    ServiceTier::Fast,
                )
                .unwrap();
            assert!((fast.total() - normal.total() * factor).abs() < 1e-9);
        }
        let long = CodexPricing::bundled()
            .calculate_token_costs_with_provider(
                "openai/gpt-6-astra-2026-09-01",
                None,
                &TokenBreakdown {
                    cache_write: 72001,
                    ..usage
                },
            )
            .unwrap();
        assert!((long.input - 2.0).abs() < 1e-9);
        assert!((long.cache_read - 0.2).abs() < 1e-9);
        assert!((long.output - 0.75).abs() < 1e-9);
    }

    #[test]
    fn calculates_disjoint_reasoning_and_cache_cost() {
        let usage = TokenBreakdown {
            input: 1_000_000,
            output: 100_000,
            cache_read: 1_000_000,
            cache_write: 0,
            reasoning: 100_000,
        };
        let cost = CodexPricing::bundled()
            .calculate_cost_with_provider("gpt-5.4-mini", Some("openai"), &usage)
            .unwrap();
        assert!((cost - 1.725).abs() < 1e-9);

        let costs = CodexPricing::bundled()
            .calculate_token_costs_with_provider("gpt-5.4-mini", Some("openai"), &usage)
            .unwrap();
        assert!((costs.input - 0.75).abs() < 1e-9);
        assert!((costs.output - 0.45).abs() < 1e-9);
        assert!((costs.cache_read - 0.075).abs() < 1e-9);
        assert_eq!(costs.cache_write, 0.0);
        assert!((costs.reasoning - 0.45).abs() < 1e-9);
        assert!((costs.total() - cost).abs() < 1e-9);
    }

    #[test]
    fn uses_current_gpt_5_6_short_context_rates() {
        let usage = TokenBreakdown {
            input: 100_000,
            output: 100_000,
            cache_read: 100_000,
            cache_write: 50_000,
            ..Default::default()
        };
        let pricing = CodexPricing::bundled();

        for (model, input, cache_read, cache_write, output) in [
            ("gpt-5.6-sol", 0.4, 0.04, 0.25, 2.0),
            ("gpt-5.6-terra", 0.2, 0.02, 0.125, 1.2),
            ("gpt-5.6-luna", 0.02, 0.002, 0.0125, 0.12),
        ] {
            let costs = pricing
                .calculate_token_costs_with_provider(model, Some("openai"), &usage)
                .unwrap();

            assert!((costs.input - input).abs() < 1e-9, "{model}");
            assert!((costs.cache_read - cache_read).abs() < 1e-9, "{model}");
            assert!((costs.cache_write - cache_write).abs() < 1e-9, "{model}");
            assert!((costs.output - output).abs() < 1e-9, "{model}");
        }
        assert!(pricing
            .calculate_token_costs_with_provider("gpt-5.5", Some("openai"), &usage)
            .is_none());
    }

    #[test]
    fn applies_long_context_rates_only_above_272k_raw_input_tokens() {
        let at_threshold = TokenBreakdown {
            input: 100_000,
            cache_read: 100_000,
            cache_write: 72_000,
            output: 100_000,
            reasoning: 100_000,
        };
        let pricing = CodexPricing::bundled();
        let short = pricing
            .calculate_token_costs_with_provider("gpt-5.6-terra", Some("openai"), &at_threshold)
            .unwrap();
        assert!((short.input - 0.2).abs() < 1e-9);
        assert!((short.cache_read - 0.02).abs() < 1e-9);
        assert!((short.cache_write - 0.18).abs() < 1e-9);
        assert!((short.output - 1.2).abs() < 1e-9);
        assert!((short.reasoning - 1.2).abs() < 1e-9);

        let above_threshold = TokenBreakdown {
            cache_write: 72_001,
            ..at_threshold
        };
        let long = pricing
            .calculate_token_costs_with_provider("gpt-5.6-terra", Some("openai"), &above_threshold)
            .unwrap();
        assert!((long.input - 0.4).abs() < 1e-9);
        assert!((long.cache_read - 0.04).abs() < 1e-9);
        assert!((long.cache_write - 0.360005).abs() < 1e-9);
        assert!((long.output - 1.8).abs() < 1e-9);
        assert!((long.reasoning - 1.8).abs() < 1e-9);
    }

    #[test]
    fn applies_verified_fast_multipliers_without_changing_standard_cost() {
        let usage = TokenBreakdown {
            input: 1_000_000,
            cache_read: 1_000_000,
            output: 1_000_000,
            ..Default::default()
        };
        let pricing = CodexPricing::bundled();

        for (model, multiplier) in [
            ("gpt-5.4", 2.0),
            ("gpt-5.5", 2.5),
            ("gpt-5.6-sol", 2.0),
            ("gpt-5.6-terra", 2.0),
            ("gpt-5.6-luna", 2.0),
        ] {
            let standard = pricing
                .calculate_cost_with_service_tier(
                    model,
                    Some("openai"),
                    &usage,
                    ServiceTier::Standard,
                )
                .unwrap();
            let fast = pricing
                .calculate_cost_with_service_tier(model, Some("openai"), &usage, ServiceTier::Fast)
                .unwrap();
            assert!((fast - standard * multiplier).abs() < 1e-9, "{model}");

            let fast_components = pricing
                .calculate_token_costs_with_service_tier(
                    model,
                    Some("openai"),
                    &usage,
                    ServiceTier::Fast,
                )
                .unwrap();
            assert!((fast_components.total() - fast).abs() < 1e-9, "{model}");
        }
    }

    #[test]
    fn applies_chatgpt_subscription_fast_multiplier_to_gpt_5_6() {
        let usage = TokenBreakdown {
            input: 1_000_000,
            output: 1_000_000,
            ..Default::default()
        };
        let pricing = CodexPricing::with_fast_pricing(FastPricingBasis::ChatGptSubscription);

        for model in ["gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] {
            let standard = pricing
                .calculate_cost_with_service_tier(
                    model,
                    Some("openai"),
                    &usage,
                    ServiceTier::Standard,
                )
                .unwrap();
            let fast = pricing
                .calculate_cost_with_service_tier(model, Some("openai"), &usage, ServiceTier::Fast)
                .unwrap();
            assert!((fast - standard * 2.5).abs() < 1e-9, "{model}");
        }
    }

    #[test]
    fn does_not_guess_a_fast_multiplier_for_an_unsupported_model() {
        let usage = TokenBreakdown {
            input: 1_000_000,
            ..Default::default()
        };
        let pricing = CodexPricing::bundled();
        let standard = pricing
            .calculate_cost_with_service_tier(
                "gpt-5.4-mini",
                Some("openai"),
                &usage,
                ServiceTier::Standard,
            )
            .unwrap();
        let fast = pricing
            .calculate_cost_with_service_tier(
                "gpt-5.4-mini",
                Some("openai"),
                &usage,
                ServiceTier::Fast,
            )
            .unwrap();

        assert_eq!(fast, standard);
    }

    #[test]
    fn recognizes_only_explicit_models_and_snapshots() {
        let usage = TokenBreakdown {
            input: 100,
            ..Default::default()
        };
        let pricing = CodexPricing::bundled();
        assert!(pricing
            .calculate_cost_with_provider("gpt-5.4-mini-2026-03-17(high)", Some("openai"), &usage)
            .is_some());
        assert!(pricing
            .calculate_cost_with_provider("fictional-codex-model", Some("openai"), &usage)
            .is_none());
        assert!(pricing
            .calculate_cost_with_provider("gpt-5.5", Some("azure"), &usage)
            .is_some());
    }

    #[test]
    fn recognizes_codex_model_families_and_log_suffixes() {
        let usage = TokenBreakdown {
            input: 1_000_000,
            cache_read: 1_000_000,
            output: 1_000_000,
            ..Default::default()
        };
        let pricing = CodexPricing::bundled();

        for model in [
            "gpt-5-codex",
            "gpt-5.1-codex-max-xhigh",
            "openai/gpt-5.1-codex(high)",
        ] {
            let cost = pricing
                .calculate_cost_with_provider(model, Some("openai"), &usage)
                .unwrap();
            assert!((cost - 11.375).abs() < 1e-9, "{model}");
        }

        let cost = pricing
            .calculate_cost_with_provider(
                "openai_codex/gpt-5.2-codex-fast",
                Some("openai_codex"),
                &usage,
            )
            .unwrap();
        assert!((cost - 15.925).abs() < 1e-9);

        let mini_cost = pricing
            .calculate_cost_with_provider("gpt-5.1-codex-mini", Some("openai"), &usage)
            .unwrap();
        assert!((mini_cost - 2.275).abs() < 1e-9);

        let legacy_cost = pricing
            .calculate_cost_with_provider("codex-mini-latest", Some("openai"), &usage)
            .unwrap();
        assert!((legacy_cost - 7.875).abs() < 1e-9);
    }

    #[test]
    fn gpt_5_4_uses_long_context_rates_above_272k() {
        let usage = TokenBreakdown {
            input: 300_000,
            output: 100_000,
            ..Default::default()
        };
        let cost = CodexPricing::bundled()
            .calculate_cost_with_provider("gpt-5.4-2026-03-05", Some("openai"), &usage)
            .unwrap();
        assert!((cost - 3.75).abs() < 1e-9);
    }

    #[test]
    fn spark_and_custom_provider_use_compatibility_estimates() {
        let usage = TokenBreakdown {
            input: 1_000_000,
            cache_read: 1_000_000,
            output: 1_000_000,
            ..Default::default()
        };
        let pricing = CodexPricing::bundled();
        let spark = pricing
            .calculate_cost_with_provider("gpt-5.3-codex-spark", Some("openai"), &usage)
            .unwrap();
        assert!((spark - 15.925).abs() < 1e-9);

        let custom_provider = pricing
            .calculate_cost_with_provider("gpt-5.5", Some("tencent"), &usage)
            .unwrap();
        assert!((custom_provider - 56.0).abs() < 1e-9);
    }

    #[test]
    fn estimates_anthropic_models_with_cache_components() {
        let usage = TokenBreakdown {
            input: 1_000_000,
            output: 1_000_000,
            cache_read: 1_000_000,
            cache_write: 1_000_000,
            ..Default::default()
        };
        let pricing =
            AnthropicPricing::bundled_for_date(NaiveDate::from_ymd_opt(2026, 8, 11).unwrap());
        let costs = pricing
            .calculate_token_costs("anthropic/claude-sonnet-4-5-20250929", &usage)
            .unwrap();

        assert!((costs.input - 3.0).abs() < 1e-9);
        assert!((costs.output - 15.0).abs() < 1e-9);
        assert!((costs.cache_read - 0.3).abs() < 1e-9);
        assert!((costs.cache_write - 3.75).abs() < 1e-9);
        assert!(pricing
            .calculate_token_costs("claude-future-99", &usage)
            .is_none());
    }

    #[test]
    fn estimates_claude_five_models_and_cache_write_ttls() {
        let pricing =
            AnthropicPricing::bundled_for_date(NaiveDate::from_ymd_opt(2026, 8, 11).unwrap());
        let usage = TokenBreakdown {
            input: 1_000_000,
            output: 1_000_000,
            cache_read: 1_000_000,
            cache_write: 1_000_000,
            ..Default::default()
        };
        let cache_writes = CacheWriteBreakdown {
            five_minute: 250_000,
            one_hour: 750_000,
        };

        let opus = pricing
            .calculate_token_costs_with_cache_writes("claude-opus-5", &usage, Some(&cache_writes))
            .unwrap();
        assert!((opus.input - 5.0).abs() < 1e-9);
        assert!((opus.output - 25.0).abs() < 1e-9);
        assert!((opus.cache_read - 0.5).abs() < 1e-9);
        assert!((opus.cache_write - 9.0625).abs() < 1e-9);

        let fable = pricing
            .calculate_token_costs_with_cache_writes("claude-fable-5", &usage, Some(&cache_writes))
            .unwrap();
        assert!((fable.input - 10.0).abs() < 1e-9);
        assert!((fable.output - 50.0).abs() < 1e-9);
        assert!((fable.cache_read - 1.0).abs() < 1e-9);
        assert!((fable.cache_write - 18.125).abs() < 1e-9);
    }

    #[test]
    fn parses_the_official_markdown_table_and_selects_dated_rows() {
        const MARKDOWN: &str = r#"
## Model pricing

| Model | Base Input Tokens | 5m Cache Writes | 1h Cache Writes | Cache Hits & Refreshes | Output Tokens |
| --- | --- | --- | --- | --- | --- |
| Claude Fable 5 | $10 / MTok | $12.50 / MTok | $20 / MTok | $1 / MTok | $50 / MTok |
| Claude Opus 5 | $5 / MTok | $6.25 / MTok | $10 / MTok | $0.50 / MTok | $25 / MTok |
| Claude Sonnet 5 [through August 31, 2026](/pricing) | $2 / MTok | $2.50 / MTok | $4 / MTok | $0.20 / MTok | $10 / MTok |
| Claude Sonnet 5 starting September 1, 2026 | $3 / MTok | $3.75 / MTok | $6 / MTok | $0.30 / MTok | $15 / MTok |
| Claude Sonnet 4.6 | $3 / MTok | $3.75 / MTok | $6 / MTok | $0.30 / MTok | $15 / MTok |
| Claude Haiku 4.5 | $1 / MTok | $1.25 / MTok | $2 / MTok | $0.10 / MTok | $5 / MTok |
"#;
        let usage = TokenBreakdown {
            input: 1_000_000,
            ..Default::default()
        };

        let introductory = AnthropicPricing::from_official_markdown(
            MARKDOWN,
            NaiveDate::from_ymd_opt(2026, 8, 31).unwrap(),
        )
        .unwrap();
        assert_eq!(
            introductory
                .calculate_token_costs("claude-sonnet-5", &usage)
                .unwrap()
                .input,
            2.0
        );

        let standard = AnthropicPricing::from_official_markdown(
            MARKDOWN,
            NaiveDate::from_ymd_opt(2026, 9, 1).unwrap(),
        )
        .unwrap();
        assert_eq!(
            standard
                .calculate_token_costs("claude-sonnet-5", &usage)
                .unwrap()
                .input,
            3.0
        );
        assert!(AnthropicPricing::from_official_markdown(
            "# Pricing without a table",
            NaiveDate::from_ymd_opt(2026, 8, 11).unwrap(),
        )
        .is_err());
    }
}
