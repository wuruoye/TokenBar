use std::collections::HashMap;
use std::fs;
use std::path::Path;

use chrono::{Local, NaiveDate};

use crate::usage::{
    CacheWriteBreakdown, ServiceTier, TokenBreakdown, TokenCostBreakdown,
};

const TOKENS_PER_MILLION: f64 = 1_000_000.0;
const LONG_CONTEXT_INPUT_THRESHOLD: i64 = 272_000;

#[derive(Debug, Clone, Copy, PartialEq)]
struct ModelRate {
    input_per_million: f64,
    cached_input_per_million: f64,
    output_per_million: f64,
    cache_write_per_million: Option<f64>,
    long_context: Option<LongContextRate>,
    long_context_available: bool,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct LongContextRate {
    input_per_million: f64,
    cached_input_per_million: f64,
    output_per_million: f64,
    cache_write_per_million: Option<f64>,
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
/// reviewed 2026-09-01 against OpenAI's official pricing table. TokenBar can
/// overlay a strictly validated daily copy of that table. A model without an
/// official or bundled rate returns `None`; callers must keep that request's
/// cost source unknown instead of presenting a fabricated $0.
/// These values are compatibility estimates for activity comparison, not an
/// OpenAI invoice. In particular, the Codex research-preview
/// `gpt-5.3-codex-spark` id has no public per-token API rate, so it uses
/// GPT-5.3-Codex's public rate. Recognized OpenAI model ids keep their estimate
/// even when a local Codex gateway records a custom provider name.
///
/// GPT-5.4, GPT-5.5, and GPT-5.6 apply their explicit long-context table row
/// to each request whose raw input exceeds 272K tokens.
///
/// Sources:
/// - https://developers.openai.com/api/docs/pricing.md
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
    standard_overrides: HashMap<String, ModelRate>,
    fast_overrides: HashMap<String, ModelRate>,
}

impl CodexPricing {
    pub fn bundled() -> Self {
        Self::with_fast_pricing(FastPricingBasis::ApiPriority)
    }

    pub fn with_fast_pricing(fast_pricing_basis: FastPricingBasis) -> Self {
        Self {
            fast_pricing_basis,
            standard_overrides: HashMap::new(),
            fast_overrides: HashMap::new(),
        }
    }

    pub fn from_official_markdown(
        markdown: &str,
        fast_pricing_basis: FastPricingBasis,
    ) -> Result<Self, String> {
        let (standard_overrides, fast_overrides) = parse_official_openai_rates(markdown)?;
        Ok(Self {
            fast_pricing_basis,
            standard_overrides,
            fast_overrides,
        })
    }

    pub fn from_official_markdown_file(
        path: &Path,
        fast_pricing_basis: FastPricingBasis,
    ) -> Result<Self, String> {
        let metadata = fs::metadata(path)
            .map_err(|error| format!("could not inspect OpenAI pricing catalog: {error}"))?;
        if metadata.len() < 1_024 || metadata.len() > 2_000_000 {
            return Err("OpenAI pricing catalog has an invalid size".to_string());
        }
        let markdown = fs::read_to_string(path)
            .map_err(|error| format!("could not read OpenAI pricing catalog: {error}"))?;
        Self::from_official_markdown(&markdown, fast_pricing_basis)
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
        let rate = self.rate_for_model(model_id)?;
        calculate_token_costs(rate, usage)
    }

    fn rate_for_model(&self, model_id: &str) -> Option<ModelRate> {
        let normalized = normalize_pricing_model_id(model_id);
        self.standard_overrides
            .get(&normalized)
            .copied()
            .or_else(|| bundled_rate_for_model(&normalized))
    }

    fn fast_rate_for_model(&self, model_id: &str) -> Option<ModelRate> {
        let normalized = normalize_pricing_model_id(model_id);
        self.fast_overrides.get(&normalized).copied()
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
        self.calculate_token_costs_with_service_tier(
            model_id,
            provider_id,
            usage,
            service_tier,
        )
        .map(|costs| costs.total())
    }

    pub fn calculate_token_costs_with_service_tier(
        &self,
        model_id: &str,
        provider_id: Option<&str>,
        usage: &TokenBreakdown,
        service_tier: ServiceTier,
    ) -> Option<TokenCostBreakdown> {
        if service_tier == ServiceTier::Fast
            && self.fast_pricing_basis == FastPricingBasis::ApiPriority
        {
            if let Some(rate) = self.fast_rate_for_model(model_id) {
                return calculate_token_costs(rate, usage);
            }
        }

        let base = self.calculate_token_costs_with_provider(model_id, provider_id, usage)?;
        let multiplier = if service_tier == ServiceTier::Fast {
            fast_cost_multiplier(model_id, self.fast_pricing_basis).unwrap_or(1.0)
        } else {
            1.0
        };
        base.scaled(multiplier)
    }
}

fn calculate_token_costs(
    rate: ModelRate,
    usage: &TokenBreakdown,
) -> Option<TokenCostBreakdown> {
    let raw_input_tokens = usage
        .input
        .max(0)
        .saturating_add(usage.cache_read.max(0))
        .saturating_add(usage.cache_write.max(0));
    let effective_rate = if raw_input_tokens > LONG_CONTEXT_INPUT_THRESHOLD {
        match rate.long_context {
            Some(long_context) => long_context,
            None if rate.long_context_available => short_context_rate(rate),
            None => return None,
        }
    } else {
        short_context_rate(rate)
    };
    if usage.cache_write > 0 && effective_rate.cache_write_per_million.is_none() {
        return None;
    }

    let costs = TokenCostBreakdown {
        input: usage.input.max(0) as f64 * effective_rate.input_per_million
            / TOKENS_PER_MILLION,
        output: usage.output.max(0) as f64 * effective_rate.output_per_million
            / TOKENS_PER_MILLION,
        cache_read: usage.cache_read.max(0) as f64
            * effective_rate.cached_input_per_million
            / TOKENS_PER_MILLION,
        cache_write: usage.cache_write.max(0) as f64
            * effective_rate.cache_write_per_million.unwrap_or_default()
            / TOKENS_PER_MILLION,
        reasoning: usage.reasoning.max(0) as f64 * effective_rate.output_per_million
            / TOKENS_PER_MILLION,
    };
    costs.total().is_finite().then_some(costs)
}

fn short_context_rate(rate: ModelRate) -> LongContextRate {
    LongContextRate {
        input_per_million: rate.input_per_million,
        cached_input_per_million: rate.cached_input_per_million,
        output_per_million: rate.output_per_million,
        cache_write_per_million: rate.cache_write_per_million,
    }
}

fn parse_official_openai_rates(
    markdown: &str,
) -> Result<(HashMap<String, ModelRate>, HashMap<String, ModelRate>), String> {
    if !markdown.lines().any(|line| line.trim() == "# Pricing") {
        return Err("official OpenAI pricing title was not found".to_string());
    }

    let mut standard = parse_openai_rate_table(markdown, "### Standard pricing data")?;
    let mut fast = parse_openai_rate_table(markdown, "### Fast pricing data")?;
    for model in ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] {
        if !standard.contains_key(model) || !fast.contains_key(model) {
            return Err(format!("official OpenAI pricing is missing {model}"));
        }
    }
    if standard.len() < 8 || fast.len() < 8 {
        return Err("official OpenAI pricing contained too few valid models".to_string());
    }

    if let Some(rate) = standard.get("gpt-5.6-sol").copied() {
        standard.insert("gpt-5.6".to_string(), rate);
    }
    if let Some(rate) = fast.get("gpt-5.6-sol").copied() {
        fast.insert("gpt-5.6".to_string(), rate);
    }
    Ok((standard, fast))
}

fn parse_openai_rate_table(
    markdown: &str,
    heading: &str,
) -> Result<HashMap<String, ModelRate>, String> {
    const EXPECTED_HEADER: [&str; 9] = [
        "Model",
        "Short context input",
        "Short context cached input",
        "Short context cache writes",
        "Short context output",
        "Long context input",
        "Long context cached input",
        "Long context cache writes",
        "Long context output",
    ];

    let mut lines = markdown.lines();
    if !lines.any(|line| line.trim() == heading) {
        return Err(format!("official OpenAI pricing section was not found: {heading}"));
    }
    let header = lines
        .find(|line| line.trim_start().starts_with("| Model |"))
        .ok_or_else(|| format!("official OpenAI pricing header was not found: {heading}"))?;
    let header_cells = markdown_table_cells(header);
    if header_cells.as_slice() != EXPECTED_HEADER {
        return Err(format!("official OpenAI pricing has an unexpected schema: {heading}"));
    }
    let separator = lines
        .next()
        .ok_or_else(|| format!("official OpenAI pricing separator was not found: {heading}"))?;
    if markdown_table_cells(separator).len() != EXPECTED_HEADER.len() {
        return Err(format!("official OpenAI pricing separator is invalid: {heading}"));
    }

    let mut rates = HashMap::new();
    for line in lines {
        if !line.trim_start().starts_with('|') {
            break;
        }
        let cells = markdown_table_cells(line);
        if cells.len() != EXPECTED_HEADER.len() {
            return Err(format!("official OpenAI pricing row is invalid: {heading}"));
        }
        if let Some((model, rate)) = openai_rate_from_cells(&cells)? {
            rates.insert(model, rate);
        }
    }
    Ok(rates)
}

fn openai_rate_from_cells(cells: &[&str]) -> Result<Option<(String, ModelRate)>, String> {
    let Some(raw_model) = cells.first().copied() else {
        return Err("official OpenAI pricing row has no model".to_string());
    };
    let model = raw_model
        .split_once(" (")
        .map(|(model, _)| model)
        .unwrap_or(raw_model)
        .trim()
        .to_ascii_lowercase();
    if !model.starts_with("gpt-") && !model.starts_with("codex-") {
        return Ok(None);
    }
    if !model
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.'))
    {
        return Err(format!("official OpenAI pricing model is invalid: {raw_model}"));
    }

    let Some(input_per_million) = parse_openai_price_cell(cells[1])? else {
        return Ok(None);
    };
    let Some(cached_input_per_million) = parse_openai_price_cell(cells[2])? else {
        return Ok(None);
    };
    let cache_write_per_million = parse_openai_price_cell(cells[3])?;
    let Some(output_per_million) = parse_openai_price_cell(cells[4])? else {
        return Ok(None);
    };

    let long_input = parse_openai_price_cell(cells[5])?;
    let long_cached = parse_openai_price_cell(cells[6])?;
    let long_cache_write = parse_openai_price_cell(cells[7])?;
    let long_output = parse_openai_price_cell(cells[8])?;
    let long_context = match (long_input, long_cached, long_output) {
        (Some(input), Some(cached), Some(output)) => Some(LongContextRate {
            input_per_million: input,
            cached_input_per_million: cached,
            output_per_million: output,
            cache_write_per_million: long_cache_write,
        }),
        (None, None, None) if long_cache_write.is_none() => None,
        _ => {
            return Err(format!(
                "official OpenAI long-context pricing is incomplete: {raw_model}"
            ));
        }
    };
    let rate = ModelRate {
        input_per_million,
        cached_input_per_million,
        output_per_million,
        cache_write_per_million,
        long_context,
        long_context_available: long_context.is_some()
            || !raw_model.contains("(<272K context length)"),
    };
    if !valid_openai_rate(rate) {
        return Err(format!("official OpenAI pricing row is invalid: {raw_model}"));
    }
    Ok(Some((model, rate)))
}

fn parse_openai_price_cell(value: &str) -> Result<Option<f64>, String> {
    let value = value.trim();
    if value == "-" {
        return Ok(None);
    }
    let price = value
        .strip_prefix('$')
        .and_then(|number| number.replace(',', "").parse::<f64>().ok())
        .filter(|price| price.is_finite() && *price > 0.0 && *price <= 1_000.0)
        .ok_or_else(|| format!("official OpenAI price is invalid: {value}"))?;
    Ok(Some(price))
}

fn valid_openai_rate(rate: ModelRate) -> bool {
    let short = short_context_rate(rate);
    valid_openai_context_rate(short)
        && rate.long_context.is_none_or(|long| {
            valid_openai_context_rate(long)
                && long.input_per_million >= short.input_per_million
                && long.cached_input_per_million >= short.cached_input_per_million
                && long.output_per_million >= short.output_per_million
                && match (
                    short.cache_write_per_million,
                    long.cache_write_per_million,
                ) {
                    (None, None) => true,
                    (Some(short), Some(long)) => long >= short,
                    _ => false,
                }
        })
}

fn valid_openai_context_rate(rate: LongContextRate) -> bool {
    rate.input_per_million.is_finite()
        && rate.cached_input_per_million.is_finite()
        && rate.output_per_million.is_finite()
        && rate.input_per_million > 0.0
        && rate.input_per_million <= 1_000.0
        && rate.cached_input_per_million > 0.0
        && rate.cached_input_per_million <= rate.input_per_million
        && rate.output_per_million >= rate.input_per_million
        && rate.output_per_million <= 1_000.0
        && rate.cache_write_per_million.is_none_or(|price| {
            price.is_finite() && price >= rate.input_per_million && price <= 1_000.0
        })
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
        }
    }

    pub fn from_official_markdown(
        markdown: &str,
        effective_date: NaiveDate,
    ) -> Result<Self, String> {
        Ok(Self {
            effective_date,
            official_rates: parse_official_anthropic_rates(markdown, effective_date)?,
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

    pub fn calculate_token_costs_with_cache_writes(
        &self,
        model_id: &str,
        usage: &TokenBreakdown,
        cache_writes: Option<&CacheWriteBreakdown>,
    ) -> Option<TokenCostBreakdown> {
        let rate = self.rate_for_model(model_id)?;
        let cache_write = anthropic_cache_write_cost(usage.cache_write, cache_writes, rate);
        let costs = TokenCostBreakdown {
            input: usage.input.max(0) as f64 * rate.input_per_million / TOKENS_PER_MILLION,
            output: usage.output.max(0) as f64 * rate.output_per_million / TOKENS_PER_MILLION,
            cache_read: usage.cache_read.max(0) as f64 * rate.cached_input_per_million
                / TOKENS_PER_MILLION,
            cache_write,
            reasoning: usage.reasoning.max(0) as f64 * rate.output_per_million
                / TOKENS_PER_MILLION,
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
    let (input, cache_write_5m, cache_write_1h, cache_read, output) =
        match normalized_model_id {
        "claude-fable-5" | "claude-mythos-5" => (10.0, 12.5, 20.0, 1.0, 50.0),
        "claude-opus-5" | "claude-opus-4-5" | "claude-opus-4-6"
        | "claude-opus-4-7" | "claude-opus-4-8" => (5.0, 6.25, 10.0, 0.5, 25.0),
        "claude-opus-4" | "claude-opus-4-1" | "claude-3-opus" => {
            (15.0, 18.75, 30.0, 1.5, 75.0)
        }
        "claude-sonnet-5"
            if effective_date <= NaiveDate::from_ymd_opt(2026, 8, 31).unwrap() =>
        {
            (2.0, 2.5, 4.0, 0.2, 10.0)
        }
        "claude-sonnet-5" | "claude-sonnet-4" | "claude-sonnet-4-5"
        | "claude-sonnet-4-6" | "claude-3-7-sonnet" | "claude-3-5-sonnet" => {
            (3.0, 3.75, 6.0, 0.3, 15.0)
        }
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
        + five_minute.saturating_add(unclassified) as f64
            * rate.cache_write_5m_per_million)
        / TOKENS_PER_MILLION
}

fn parse_official_anthropic_rates(
    markdown: &str,
    effective_date: NaiveDate,
) -> Result<HashMap<String, AnthropicModelRate>, String> {
    let mut lines = markdown.lines();
    let Some(header) = lines.find(|line| {
        let header = line.trim_start().to_ascii_lowercase();
        header.starts_with("| model")
            && header.contains("base input tokens")
            && header.contains("5m cache writes")
            && header.contains("1h cache writes")
            && (header.contains("cache hits and refreshes")
                || header.contains("cache hits & refreshes"))
            && header.contains("output tokens")
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
            return Err(format!("official Anthropic pricing row is invalid: {label}"));
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
    if !matches!(family.as_str(), "fable" | "mythos" | "opus" | "sonnet" | "haiku") {
        return None;
    }
    let version = words.next()?.trim_matches(|character: char| {
        !character.is_ascii_digit() && character != '.'
    });
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
    let (price, footnote) = value.split_once("/ MTok")?;
    if !footnote.chars().all(|character| {
        character.is_ascii_digit()
            || matches!(character, '^' | '{' | '}' | '[' | ']')
            || matches!(character, '¹' | '²' | '³')
    }) {
        return None;
    }
    let number = price.trim().strip_prefix('$')?.trim();
    let price = number.replace(',', "").parse::<f64>().ok()?;
    (price.is_finite() && price > 0.0 && price <= 1_000.0).then_some(price)
}

fn normalize_anthropic_model_id(model_id: &str) -> String {
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
        ("claude-5-1-fable", "claude-fable-5-1"),
        ("claude-5-1-mythos", "claude-mythos-5-1"),
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
        ("fable-5-1", "claude-fable-5-1"),
        ("mythos-5-1", "claude-mythos-5-1"),
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

/// Official Fast multipliers reviewed 2026-07-16:
/// - ChatGPT subscription credits: GPT-5.4 is 2x; GPT-5.5/5.6 are 2.5x.
/// - API Priority pricing: GPT-5.4 is 2x; GPT-5.5 is 2.5x; GPT-5.6 is 2x.
///
/// Sources:
/// - https://learn.chatgpt.com/docs/agent-configuration/speed#fast-mode
/// - https://developers.openai.com/api/docs/pricing
/// - https://developers.openai.com/api/docs/guides/priority-processing
fn fast_cost_multiplier(model_id: &str, basis: FastPricingBasis) -> Option<f64> {
    let normalized = normalize_pricing_model_id(model_id);
    match (basis, normalized.as_str()) {
        (_, "gpt-5.4") => Some(2.0),
        (_, "gpt-5.5") => Some(2.5),
        (FastPricingBasis::ChatGptSubscription, "gpt-5.6" | "gpt-5.6-sol") => Some(2.5),
        (FastPricingBasis::ChatGptSubscription, "gpt-5.6-terra" | "gpt-5.6-luna") => Some(2.5),
        (FastPricingBasis::ApiPriority, "gpt-5.6" | "gpt-5.6-sol") => Some(2.0),
        (FastPricingBasis::ApiPriority, "gpt-5.6-terra" | "gpt-5.6-luna") => Some(2.0),
        _ => None,
    }
}

fn bundled_rate_for_model(model_id: &str) -> Option<ModelRate> {
    let normalized = normalize_pricing_model_id(model_id);
    match normalized.as_str() {
        "codex-mini-latest" => Some(ModelRate {
            input_per_million: 1.5,
            cached_input_per_million: 0.375,
            output_per_million: 6.0,
            cache_write_per_million: None,
            long_context: None,
            long_context_available: true,
        }),
        "gpt-5" | "gpt-5-codex" | "gpt-5.1" | "gpt-5.1-codex" | "gpt-5.1-codex-max" => {
            Some(ModelRate {
                input_per_million: 1.25,
                cached_input_per_million: 0.125,
                output_per_million: 10.0,
                cache_write_per_million: None,
                long_context: None,
                long_context_available: true,
            })
        }
        "gpt-5-mini" | "gpt-5.1-codex-mini" => Some(ModelRate {
            input_per_million: 0.25,
            cached_input_per_million: 0.025,
            output_per_million: 2.0,
            cache_write_per_million: None,
            long_context: None,
            long_context_available: true,
        }),
        "gpt-5.2" | "gpt-5.2-codex" | "gpt-5.3-codex" | "gpt-5.3-codex-spark" => Some(ModelRate {
            input_per_million: 1.75,
            cached_input_per_million: 0.175,
            output_per_million: 14.0,
            cache_write_per_million: None,
            long_context: None,
            long_context_available: true,
        }),
        "gpt-5.4" => Some(ModelRate {
            input_per_million: 2.5,
            cached_input_per_million: 0.25,
            output_per_million: 15.0,
            cache_write_per_million: None,
            long_context: Some(LongContextRate {
                input_per_million: 5.0,
                cached_input_per_million: 0.5,
                output_per_million: 22.5,
                cache_write_per_million: None,
            }),
            long_context_available: true,
        }),
        "gpt-5.4-mini" => Some(ModelRate {
            input_per_million: 0.75,
            cached_input_per_million: 0.075,
            output_per_million: 4.5,
            cache_write_per_million: None,
            long_context: None,
            long_context_available: true,
        }),
        "gpt-5.5" => Some(ModelRate {
            input_per_million: 5.0,
            cached_input_per_million: 0.5,
            output_per_million: 30.0,
            cache_write_per_million: None,
            long_context: Some(LongContextRate {
                input_per_million: 10.0,
                cached_input_per_million: 1.0,
                output_per_million: 45.0,
                cache_write_per_million: None,
            }),
            long_context_available: true,
        }),
        "gpt-5.6" | "gpt-5.6-sol" => Some(ModelRate {
            input_per_million: 4.0,
            cached_input_per_million: 0.4,
            output_per_million: 20.0,
            cache_write_per_million: Some(5.0),
            long_context: Some(LongContextRate {
                input_per_million: 8.0,
                cached_input_per_million: 0.8,
                output_per_million: 30.0,
                cache_write_per_million: Some(10.0),
            }),
            long_context_available: true,
        }),
        "gpt-5.6-terra" => Some(ModelRate {
            input_per_million: 2.0,
            cached_input_per_million: 0.2,
            output_per_million: 12.0,
            cache_write_per_million: Some(2.5),
            long_context: Some(LongContextRate {
                input_per_million: 4.0,
                cached_input_per_million: 0.4,
                output_per_million: 18.0,
                cache_write_per_million: Some(5.0),
            }),
            long_context_available: true,
        }),
        "gpt-5.6-luna" => Some(ModelRate {
            input_per_million: 0.2,
            cached_input_per_million: 0.02,
            output_per_million: 1.2,
            cache_write_per_million: Some(0.25),
            long_context: Some(LongContextRate {
                input_per_million: 0.4,
                cached_input_per_million: 0.04,
                output_per_million: 1.8,
                cache_write_per_million: Some(0.5),
            }),
            long_context_available: true,
        }),
        _ => None,
    }
}

fn normalize_pricing_model_id(model_id: &str) -> String {
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

    const BASE_MODELS: [&str; 19] = [
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
    fn overlays_validated_official_standard_fast_and_long_context_rates() {
        let pricing = CodexPricing::from_official_markdown(
            official_openai_markdown(),
            FastPricingBasis::ApiPriority,
        )
        .unwrap();
        let short_usage = TokenBreakdown {
            input: 100_000,
            output: 100_000,
            cache_read: 100_000,
            cache_write: 50_000,
            ..Default::default()
        };

        let standard = pricing
            .calculate_token_costs_with_service_tier(
                "gpt-5.6",
                Some("openai"),
                &short_usage,
                ServiceTier::Standard,
            )
            .unwrap();
        assert!((standard.input - 0.375).abs() < 1e-9);
        assert!((standard.cache_read - 0.035).abs() < 1e-9);
        assert!((standard.cache_write - 0.2375).abs() < 1e-9);
        assert!((standard.output - 1.9).abs() < 1e-9);

        let fast = pricing
            .calculate_token_costs_with_service_tier(
                "gpt-5.6-sol",
                Some("openai"),
                &short_usage,
                ServiceTier::Fast,
            )
            .unwrap();
        assert!((fast.input - 0.9).abs() < 1e-9);
        assert!((fast.cache_read - 0.09).abs() < 1e-9);
        assert!((fast.cache_write - 0.5625).abs() < 1e-9);
        assert!((fast.output - 4.5).abs() < 1e-9);

        let long_usage = TokenBreakdown {
            input: 273_000,
            output: 100_000,
            ..Default::default()
        };
        let long = pricing
            .calculate_token_costs_with_provider(
                "gpt-5.6-sol",
                Some("openai"),
                &long_usage,
            )
            .unwrap();
        assert!((long.input - 1.97925).abs() < 1e-9);
        assert!((long.output - 2.8).abs() < 1e-9);
        assert!(pricing
            .calculate_token_costs_with_service_tier(
                "gpt-5.5",
                Some("openai"),
                &long_usage,
                ServiceTier::Fast,
            )
            .is_none());
    }

    #[test]
    fn chatgpt_fast_uses_credit_multiplier_with_refreshed_standard_rates() {
        let pricing = CodexPricing::from_official_markdown(
            official_openai_markdown(),
            FastPricingBasis::ChatGptSubscription,
        )
        .unwrap();
        let usage = TokenBreakdown {
            input: 100_000,
            output: 100_000,
            ..Default::default()
        };

        let standard = pricing
            .calculate_cost_with_service_tier(
                "gpt-5.6-sol",
                Some("openai"),
                &usage,
                ServiceTier::Standard,
            )
            .unwrap();
        let fast = pricing
            .calculate_cost_with_service_tier(
                "gpt-5.6-sol",
                Some("openai"),
                &usage,
                ServiceTier::Fast,
            )
            .unwrap();

        assert!((standard - 2.275).abs() < 1e-9);
        assert!((fast - standard * 2.5).abs() < 1e-9);
    }

    #[test]
    fn rejects_incomplete_or_changed_official_openai_tables() {
        let changed_header = official_openai_markdown().replace(
            "Short context cached input",
            "Cached prompt",
        );
        assert!(CodexPricing::from_official_markdown(
            &changed_header,
            FastPricingBasis::ApiPriority,
        )
        .is_err());

        let incomplete = official_openai_markdown().replace(
            "$7.25 | $0.70 | $9.50 | $28.00",
            "$7.25 | - | $9.50 | $28.00",
        );
        assert!(CodexPricing::from_official_markdown(
            &incomplete,
            FastPricingBasis::ApiPriority,
        )
        .is_err());
    }

    #[test]
    fn applies_long_context_rates_only_above_272k_raw_input_tokens() {
        let at_threshold = TokenBreakdown {
            input: 100_000,
            cache_read: 100_000,
            cache_write: 72_000,
            output: 100_000,
            reasoning: 100_000,
            ..Default::default()
        };
        let pricing = CodexPricing::bundled();
        let short = pricing
            .calculate_token_costs_with_provider(
                "gpt-5.6-terra",
                Some("openai"),
                &at_threshold,
            )
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
            .calculate_token_costs_with_provider(
                "gpt-5.6-terra",
                Some("openai"),
                &above_threshold,
            )
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
        let pricing = AnthropicPricing::bundled_for_date(
            NaiveDate::from_ymd_opt(2026, 8, 11).unwrap(),
        );
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
        let pricing = AnthropicPricing::bundled_for_date(
            NaiveDate::from_ymd_opt(2026, 8, 11).unwrap(),
        );
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
            .calculate_token_costs_with_cache_writes(
                "claude-opus-5",
                &usage,
                Some(&cache_writes),
            )
            .unwrap();
        assert!((opus.input - 5.0).abs() < 1e-9);
        assert!((opus.output - 25.0).abs() < 1e-9);
        assert!((opus.cache_read - 0.5).abs() < 1e-9);
        assert!((opus.cache_write - 9.0625).abs() < 1e-9);

        let fable = pricing
            .calculate_token_costs_with_cache_writes(
                "claude-fable-5",
                &usage,
                Some(&cache_writes),
            )
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

| Model | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |
| --- | --- | --- | --- | --- | --- |
| Claude Fable 5.1 | $10 / MTok | $12.50 / MTok | $20 / MTok | $0.25 / MTok1 | $50 / MTok |
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
        let fable = standard
            .calculate_token_costs("claude-fable-5-1", &TokenBreakdown {
                cache_read: 1_000_000,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(fable.cache_read, 0.25);
        assert!(AnthropicPricing::from_official_markdown(
            "# Pricing without a table",
            NaiveDate::from_ymd_opt(2026, 8, 11).unwrap(),
        )
        .is_err());
    }

    fn official_openai_markdown() -> &'static str {
        r#"
# Pricing

### Standard pricing data

| Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| gpt-5.6-sol | $3.75 | $0.35 | $4.75 | $19.00 | $7.25 | $0.70 | $9.50 | $28.00 |
| gpt-5.6-terra | $2.00 | $0.20 | $2.50 | $12.00 | $4.00 | $0.40 | $5.00 | $18.00 |
| gpt-5.6-luna | $0.20 | $0.02 | $0.25 | $1.20 | $0.40 | $0.04 | $0.50 | $1.80 |
| gpt-5.5 (<272K context length) | $5.00 | $0.50 | - | $30.00 | $10.00 | $1.00 | - | $45.00 |
| gpt-5.4 (<272K context length) | $2.50 | $0.25 | - | $15.00 | $5.00 | $0.50 | - | $22.50 |
| gpt-5.4-mini | $0.75 | $0.075 | - | $4.50 | - | - | - | - |
| gpt-5.2 | $1.75 | $0.175 | - | $14.00 | - | - | - | - |
| gpt-5.1 | $1.25 | $0.125 | - | $10.00 | - | - | - | - |

### Fast pricing data

| Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| gpt-5.6-sol | $9.00 | $0.90 | $11.25 | $45.00 | $18.00 | $1.80 | $22.50 | $67.50 |
| gpt-5.6-terra | $4.00 | $0.40 | $5.00 | $24.00 | $8.00 | $0.80 | $10.00 | $36.00 |
| gpt-5.6-luna | $0.40 | $0.04 | $0.50 | $2.40 | $0.80 | $0.08 | $1.00 | $3.60 |
| gpt-5.5 (<272K context length) | $12.50 | $1.25 | - | $75.00 | - | - | - | - |
| gpt-5.4 (<272K context length) | $5.00 | $0.50 | - | $30.00 | - | - | - | - |
| gpt-5.4-mini | $1.50 | $0.15 | - | $9.00 | - | - | - | - |
| gpt-5.2 | $3.50 | $0.35 | - | $28.00 | - | - | - | - |
| gpt-5.1 | $2.50 | $0.25 | - | $20.00 | - | - | - | - |
"#
    }
}
