use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::sync::Arc;

use crate::openrouter::Catalog;

use chrono::{Local, NaiveDate};

use crate::usage::{
    normalize_model_for_grouping, BillingBasis, CacheWriteBreakdown, ServiceTier, TokenBreakdown,
    TokenCostBreakdown,
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
/// Rates are standard API text-token prices in USD per million tokens, reviewed
/// 2026-09-05 against OpenAI's official pricing table; GPT-6.1 Sol was reviewed
/// 2026-10-14. TokenBar can
/// overlay a strictly validated daily copy of that table. A model without an
/// official, OpenRouter, or bundled rate returns `None`; callers must keep that request's
/// cost source unknown instead of presenting a fabricated $0.
/// These values are compatibility estimates for activity comparison, not an
/// OpenAI invoice. In particular, the Codex research-preview
/// `gpt-5.3-codex-spark` id has no public per-token API rate, so it uses
/// GPT-5.3-Codex's public rate. Recognized OpenAI model ids keep their estimate
/// even when a local Codex gateway records a custom provider name.
///
/// GPT-5.4, GPT-5.5, GPT-5.6, and GPT-6.1 Sol apply their explicit long-context table row
/// to each request whose raw input exceeds 272K tokens. GPT-6 Astra applies
/// its long-context table row for API Priority sessions, while ChatGPT subscription
/// sessions keep short-context rates across all prompt lengths.
///
/// Fast and Ultrafast depend on how each request was paid for. API keys use
/// the official Fast or Ultrafast table row. ChatGPT sign-in uses the Standard
/// estimate times the usage multiplier from the official Codex speed page,
/// which differs between included usage and purchased credits.
///
/// Sources:
/// - https://developers.openai.com/api/docs/models/gpt-6-astra
/// - https://openrouter.ai/docs/guides/overview/models
/// - https://developers.openai.com/api/docs/pricing.md
/// - https://learn.chatgpt.com/docs/agent-configuration/speed.md
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
#[derive(Debug, Clone, Default)]
pub struct CodexPricing {
    default_billing: BillingBasis,
    standard_overrides: HashMap<String, ModelRate>,
    fast_overrides: HashMap<String, ModelRate>,
    ultrafast_overrides: HashMap<String, ModelRate>,
    speed_rules: SpeedRules,
    openrouter: Option<Arc<Catalog>>,
}

impl CodexPricing {
    pub fn bundled() -> Self {
        Self::with_default_billing(BillingBasis::Api)
    }

    /// `default_billing` applies to requests whose session log does not say
    /// how they were paid for.
    pub fn with_default_billing(default_billing: BillingBasis) -> Self {
        Self {
            default_billing,
            ..Self::default()
        }
    }

    pub fn from_official_markdown(
        markdown: &str,
        default_billing: BillingBasis,
    ) -> Result<Self, String> {
        let tables = parse_official_openai_rates(markdown)?;
        Ok(Self {
            default_billing,
            standard_overrides: tables.standard,
            fast_overrides: tables.fast,
            ultrafast_overrides: tables.ultrafast,
            ..Self::default()
        })
    }

    pub fn from_official_markdown_file(
        path: &Path,
        default_billing: BillingBasis,
    ) -> Result<Self, String> {
        let metadata = fs::metadata(path)
            .map_err(|error| format!("could not inspect OpenAI pricing catalog: {error}"))?;
        if metadata.len() < 1_024 || metadata.len() > 2_000_000 {
            return Err("OpenAI pricing catalog has an invalid size".to_string());
        }
        let markdown = fs::read_to_string(path)
            .map_err(|error| format!("could not read OpenAI pricing catalog: {error}"))?;
        Self::from_official_markdown(&markdown, default_billing)
    }

    /// Overlays ChatGPT's Fast and Ultrafast usage multipliers from a copy of
    /// the official Codex speed page. A page that no longer reads cleanly keeps
    /// the bundled multipliers.
    pub fn with_speed_markdown_file(mut self, path: &Path) -> Self {
        let rules = fs::metadata(path)
            .ok()
            .filter(|metadata| metadata.len() <= 2_000_000)
            .and_then(|_| fs::read_to_string(path).ok())
            .and_then(|markdown| SpeedRules::from_official_markdown(&markdown));
        if let Some(rules) = rules {
            self.speed_rules = rules;
        }
        self
    }

    pub fn with_openrouter_catalog(mut self, catalog: Option<Arc<Catalog>>) -> Self {
        self.openrouter = catalog;
        self
    }

    /// Prices one request. `billing` comes from the session log when it
    /// recorded one; otherwise the current sign-in method applies. Fast and
    /// Ultrafast change cost only; token and cache counts stay raw. A speed tier
    /// without a verified multiplier keeps the Standard estimate instead of
    /// receiving a guessed one.
    pub fn calculate_token_costs_with_service_tier(
        &self,
        model_id: &str,
        usage: &TokenBreakdown,
        service_tier: ServiceTier,
        billing: Option<BillingBasis>,
    ) -> Option<TokenCostBreakdown> {
        let billing = billing.unwrap_or(self.default_billing);
        let Some(speed) = Speed::from_service_tier(service_tier) else {
            return self.standard_costs(model_id, usage, billing);
        };
        if billing == BillingBasis::Api {
            let table = match speed {
                Speed::Fast => &self.fast_overrides,
                Speed::Ultrafast => &self.ultrafast_overrides,
            };
            if let Some(rate) = lookup_rate(table, model_id) {
                return calculate_token_costs(rate, usage);
            }
        }
        let multiplier = self.speed_multiplier(model_id, speed, billing).unwrap_or(1.0);
        self.standard_costs(model_id, usage, billing)?.scaled(multiplier)
    }

    fn standard_costs(
        &self,
        model_id: &str,
        usage: &TokenBreakdown,
        billing: BillingBasis,
    ) -> Option<TokenCostBreakdown> {
        // Explicit official tables retain priority; automatic quotes cover other models.
        if lookup_rate(&self.standard_overrides, model_id).is_none() {
            let normalized = normalize_pricing_model_id(model_id);
            let known_long_context = bundled_rate_for_model(&normalized)
                .is_some_and(|rate| rate.long_context.is_some())
                && !(billing.is_chatgpt() && normalized == "gpt-6-astra");
            if let Some(costs) = self.openrouter.as_ref().and_then(|catalog|
                catalog.costs("openai", model_id, usage, None, known_long_context)) {
                return Some(costs);
            }
        }
        let rate = self.rate_for_model(model_id, billing)?;
        calculate_token_costs(rate, usage)
    }

    fn rate_for_model(&self, model_id: &str, billing: BillingBasis) -> Option<ModelRate> {
        let normalized = normalize_pricing_model_id(model_id);
        let mut rate = lookup_rate(&self.standard_overrides, model_id)
            .or_else(|| bundled_rate_for_model(&normalized))?;
        if billing.is_chatgpt() && normalized == "gpt-6-astra" {
            rate.long_context = None;
        }
        Some(rate)
    }

    fn speed_multiplier(
        &self,
        model_id: &str,
        speed: Speed,
        billing: BillingBasis,
    ) -> Option<f64> {
        let normalized = normalize_pricing_model_id(model_id);
        if billing.is_chatgpt() {
            if let Some(rule) = self
                .speed_rules
                .rule(speed)
                .filter(|rule| rule.models.contains(&normalized))
            {
                return Some(if billing == BillingBasis::ChatGptIncluded {
                    rule.included
                } else {
                    rule.credits
                });
            }
        }
        bundled_speed_multiplier(&normalized, speed, billing)
    }
}

/// Looks up the exact model id first, so a row for a dated snapshot wins, then
/// the base model.
fn lookup_rate(table: &HashMap<String, ModelRate>, model_id: &str) -> Option<ModelRate> {
    table
        .get(&clean_pricing_model_id(model_id))
        .or_else(|| table.get(&normalize_pricing_model_id(model_id)))
        .copied()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Speed {
    Fast,
    Ultrafast,
}

impl Speed {
    fn from_service_tier(tier: ServiceTier) -> Option<Self> {
        match tier {
            ServiceTier::Fast => Some(Self::Fast),
            ServiceTier::Ultrafast => Some(Self::Ultrafast),
            ServiceTier::Unknown | ServiceTier::Standard => None,
        }
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

struct OpenAiRateTables {
    standard: HashMap<String, ModelRate>,
    fast: HashMap<String, ModelRate>,
    ultrafast: HashMap<String, ModelRate>,
}

/// Reads OpenAI's official pricing Markdown. Only the Standard table is
/// required; Fast and Ultrafast tables are used when present and readable.
/// Validation checks the table shape and price ranges rather than particular
/// model names, so a retired model leaving the table does not reject the file.
fn parse_official_openai_rates(
    markdown: &str,
) -> Result<OpenAiRateTables, String> {
    if !markdown.lines().any(|line| line.trim() == "# Pricing") {
        return Err("official OpenAI pricing title was not found".to_string());
    }

    let standard = parse_openai_rate_table(markdown, "### Standard pricing data")?;
    if standard.len() < 8 {
        return Err("official OpenAI pricing contained too few valid models".to_string());
    }
    let optional_table =
        |heading: &str| parse_openai_rate_table(markdown, heading).unwrap_or_default();
    let mut tables = OpenAiRateTables {
        standard,
        fast: optional_table("### Fast pricing data"),
        ultrafast: optional_table("### Ultrafast pricing data"),
    };
    for table in [&mut tables.standard, &mut tables.fast, &mut tables.ultrafast] {
        if let Some(rate) = table.get("gpt-5.6-sol").copied() {
            table.insert("gpt-5.6".to_string(), rate);
        }
        add_base_model_aliases(table);
    }
    Ok(tables)
}

/// Lets a table that lists only dated snapshots price the base model id Codex
/// logs. An explicit base row wins; otherwise the newest snapshot does.
fn add_base_model_aliases(table: &mut HashMap<String, ModelRate>) {
    let mut snapshots = table
        .iter()
        .map(|(model, rate)| (normalize_pricing_model_id(model), model.clone(), *rate))
        .filter(|(base, model, _)| base != model && !table.contains_key(base))
        .collect::<Vec<_>>();
    snapshots.sort_by(|left, right| left.1.cmp(&right.1));
    for (base, _, rate) in snapshots {
        table.insert(base, rate);
    }
}

/// Reads every pricing table under one `###` heading. Columns are found by
/// header name, so a table that reorders columns, adds cache-write durations,
/// or lists older models in a shorter table still reads.
fn parse_openai_rate_table(
    markdown: &str,
    heading: &str,
) -> Result<HashMap<String, ModelRate>, String> {
    let mut lines = markdown.lines();
    if !lines.any(|line| line.trim() == heading) {
        return Err(format!("official OpenAI pricing section was not found: {heading}"));
    }

    let mut lines = lines.peekable();
    let mut rates = HashMap::new();
    let mut table_count = 0;
    while let Some(line) = lines.next() {
        let trimmed = line.trim();
        if ["# ", "## ", "### "].iter().any(|prefix| trimmed.starts_with(prefix)) {
            break;
        }
        if !trimmed.starts_with("| Model |") {
            continue;
        }
        let header_cells = markdown_table_cells(trimmed);
        let columns = OpenAiRateColumns::from_header(&header_cells)
            .ok_or_else(|| format!("official OpenAI pricing has an unexpected schema: {heading}"))?;
        let separator = lines
            .next()
            .ok_or_else(|| format!("official OpenAI pricing separator was not found: {heading}"))?;
        if markdown_table_cells(separator).len() != header_cells.len() {
            return Err(format!("official OpenAI pricing separator is invalid: {heading}"));
        }
        table_count += 1;
        while let Some(row) = lines.next_if(|line| line.trim_start().starts_with('|')) {
            let cells = markdown_table_cells(row);
            if cells.len() != header_cells.len() {
                return Err(format!("official OpenAI pricing row is invalid: {heading}"));
            }
            if let Some((model, rate)) = openai_rate_from_cells(&cells, &columns)? {
                rates.insert(model, rate);
            }
        }
    }
    if table_count == 0 {
        return Err(format!("official OpenAI pricing header was not found: {heading}"));
    }
    Ok(rates)
}

/// Column positions in one pricing table. Where the table lists several
/// cache-write durations, the 30-minute write is used; it matches the single
/// cache-write price the table listed before durations were split.
struct OpenAiRateColumns {
    input: usize,
    cached_input: usize,
    output: usize,
    cache_write: Option<usize>,
    long_input: Option<usize>,
    long_cached_input: Option<usize>,
    long_output: Option<usize>,
    long_cache_write: Option<usize>,
}

impl OpenAiRateColumns {
    fn from_header(cells: &[&str]) -> Option<Self> {
        if !cells.first()?.eq_ignore_ascii_case("model") {
            return None;
        }
        let names = cells
            .iter()
            .map(|cell| cell.to_ascii_lowercase())
            .collect::<Vec<_>>();
        let find = |candidates: &[&str]| {
            names
                .iter()
                .position(|name| candidates.contains(&name.as_str()))
        };
        Some(Self {
            input: find(&["short context input", "input"])?,
            cached_input: find(&["short context cached input", "cached input"])?,
            output: find(&["short context output", "output"])?,
            cache_write: find(&[
                "short context 30m write",
                "short context cache writes",
                "30m write",
                "cache writes",
            ]),
            long_input: find(&["long context input"]),
            long_cached_input: find(&["long context cached input"]),
            long_output: find(&["long context output"]),
            long_cache_write: find(&["long context 30m write", "long context cache writes"]),
        })
    }
}

fn openai_rate_from_cells(
    cells: &[&str],
    columns: &OpenAiRateColumns,
) -> Result<Option<(String, ModelRate)>, String> {
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

    let price = |index: usize| parse_openai_price_cell(cells[index]);
    let optional_price = |index: Option<usize>| index.map_or(Ok(None), price);
    let Some(input_per_million) = price(columns.input)? else {
        return Ok(None);
    };
    let Some(cached_input_per_million) = price(columns.cached_input)? else {
        return Ok(None);
    };
    let cache_write_per_million = optional_price(columns.cache_write)?;
    let Some(output_per_million) = price(columns.output)? else {
        return Ok(None);
    };

    let long_input = optional_price(columns.long_input)?;
    let long_cached = optional_price(columns.long_cached_input)?;
    let long_cache_write = optional_price(columns.long_cache_write)?;
    let long_output = optional_price(columns.long_output)?;
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
/// model's rate. A model priced by prompt length, such as "for prompts over
/// 100,000 tokens", switches to its higher row once a request's prompt passes
/// that size.
///
/// Source: https://platform.claude.com/docs/en/about-claude/pricing.md
#[derive(Debug, Clone)]
pub struct AnthropicPricing {
    effective_date: NaiveDate,
    official_rates: HashMap<String, AnthropicModelRate>,
    long_prompt_rates: HashMap<String, AnthropicLongPromptRate>,
    openrouter: Option<Arc<Catalog>>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct AnthropicLongPromptRate {
    prompt_tokens_over: i64,
    rate: AnthropicModelRate,
}

type AnthropicRateTables = (
    HashMap<String, AnthropicModelRate>,
    HashMap<String, AnthropicLongPromptRate>,
);

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
            long_prompt_rates: HashMap::new(),
            openrouter: None,
        }
    }

    pub fn from_official_markdown(
        markdown: &str,
        effective_date: NaiveDate,
    ) -> Result<Self, String> {
        let (official_rates, long_prompt_rates) =
            parse_official_anthropic_rates(markdown, effective_date)?;
        Ok(Self {
            effective_date,
            official_rates,
            long_prompt_rates,
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
        if !self.official_rates.contains_key(&normalize_anthropic_model_id(model_id)) {
            if let Some(costs) = self.openrouter.as_ref().and_then(|catalog|
                catalog.costs("anthropic", model_id, usage, cache_writes, false)) {
                return Some(costs);
            }
        }
        let rate = self.rate_for_model(model_id, usage)?;
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

    fn rate_for_model(
        &self,
        model_id: &str,
        usage: &TokenBreakdown,
    ) -> Option<AnthropicModelRate> {
        let normalized = normalize_anthropic_model_id(model_id);
        let prompt_tokens = usage
            .input
            .max(0)
            .saturating_add(usage.cache_read.max(0))
            .saturating_add(usage.cache_write.max(0));
        if let Some(long_prompt) = self.long_prompt_rates.get(&normalized) {
            if prompt_tokens > long_prompt.prompt_tokens_over {
                return Some(long_prompt.rate);
            }
        }
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
) -> Result<AnthropicRateTables, String> {
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
    let mut long_prompt_rates = HashMap::new();
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
        match long_prompt_threshold(label) {
            Some(prompt_tokens_over) => {
                long_prompt_rates.insert(
                    model_id,
                    AnthropicLongPromptRate {
                        prompt_tokens_over,
                        rate,
                    },
                );
            }
            None => {
                rates.insert(model_id, rate);
            }
        }
    }

    if rates.len() < 5 {
        return Err("official Anthropic pricing table contained too few valid models".to_string());
    }
    long_prompt_rates.retain(|model_id, _| rates.contains_key(model_id));
    Ok((rates, long_prompt_rates))
}

/// Reads the size from a row label such as "Claude Haiku 5.5 (for prompts over
/// 100,000 tokens)". The matching "up to" row is the model's base price.
fn long_prompt_threshold(label: &str) -> Option<i64> {
    let lower = label.to_ascii_lowercase();
    let (_, remainder) = lower.split_once("for prompts over ")?;
    let digits = remainder
        .chars()
        .take_while(|character| character.is_ascii_digit() || *character == ',')
        .filter(char::is_ascii_digit)
        .collect::<String>();
    digits.parse::<i64>().ok().filter(|tokens| *tokens > 0)
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
    if family.is_empty() || !family.bytes().all(|byte| byte.is_ascii_lowercase()) {
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
    let footnote = footnote.replace("<sup>", "").replace("</sup>", "");
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

/// Bundled Fast and Ultrafast multipliers, used when the official speed page or
/// pricing table does not cover a model. Fast reviewed 2026-09-05; GPT-6.1 Sol
/// reviewed 2026-10-14; GPT-6.1 Terra, GPT-6 Sol, GPT-6 Luna, Ultrafast, and
/// purchased credits reviewed 2026-10-28:
/// - ChatGPT included usage: Fast is 2x for GPT-5.4 and 2.5x for GPT-5.5 and
///   later; Ultrafast is 8x.
/// - ChatGPT purchased credits: Fast is 2x and Ultrafast is 6x for the models
///   the speed page lists.
/// - API Priority pricing: GPT-5.4 is 2x; GPT-5.5 is 2.5x; GPT-5.6 and later
///   are 2x; Ultrafast is 6x.
///
/// Sources:
/// - https://learn.chatgpt.com/docs/agent-configuration/speed#fast-mode
/// - https://developers.openai.com/api/docs/pricing
/// - https://developers.openai.com/api/docs/guides/priority-processing
fn bundled_speed_multiplier(model_id: &str, speed: Speed, billing: BillingBasis) -> Option<f64> {
    const FAST_MODELS: [&str; 9] = [
        "gpt-6.1-sol",
        "gpt-6.1-terra",
        "gpt-6-astra",
        "gpt-6-sol",
        "gpt-6-luna",
        "gpt-5.6",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
    ];
    const ULTRAFAST_MODELS: [&str; 2] = ["gpt-6-astra", "gpt-6.1-sol"];

    let normalized = normalize_pricing_model_id(model_id);
    let model = normalized.as_str();
    match (speed, billing) {
        (Speed::Ultrafast, _) if !ULTRAFAST_MODELS.contains(&model) => None,
        (Speed::Ultrafast, BillingBasis::ChatGptIncluded) => Some(8.0),
        (Speed::Ultrafast, BillingBasis::ChatGptCredits | BillingBasis::Api) => Some(6.0),
        (Speed::Fast, BillingBasis::ChatGptIncluded) => match model {
            "gpt-5.4" => Some(2.0),
            "gpt-5.5" => Some(2.5),
            _ => FAST_MODELS.contains(&model).then_some(2.5),
        },
        (Speed::Fast, BillingBasis::ChatGptCredits) => FAST_MODELS.contains(&model).then_some(2.0),
        (Speed::Fast, BillingBasis::Api) => match model {
            "gpt-5.4" => Some(2.0),
            "gpt-5.5" => Some(2.5),
            _ => FAST_MODELS.contains(&model).then_some(2.0),
        },
    }
}

/// ChatGPT usage multipliers for Fast and Ultrafast, read from a daily copy of
/// the official Codex speed page.
///
/// Source: https://learn.chatgpt.com/docs/agent-configuration/speed.md
#[derive(Debug, Clone, Default)]
struct SpeedRules {
    fast: Option<SpeedRule>,
    ultrafast: Option<SpeedRule>,
}

#[derive(Debug, Clone)]
struct SpeedRule {
    models: HashSet<String>,
    included: f64,
    credits: f64,
}

impl SpeedRules {
    fn from_official_markdown(markdown: &str) -> Option<Self> {
        if !markdown.lines().any(|line| line.trim() == "# Speed") {
            return None;
        }
        let rules = Self {
            fast: speed_rule(markdown, "Fast mode"),
            ultrafast: speed_rule(markdown, "Ultrafast mode"),
        };
        (rules.fast.is_some() || rules.ultrafast.is_some()).then_some(rules)
    }

    fn rule(&self, speed: Speed) -> Option<&SpeedRule> {
        match speed {
            Speed::Fast => self.fast.as_ref(),
            Speed::Ultrafast => self.ultrafast.as_ref(),
        }
    }
}

/// Reads one `## <heading>` section of the speed page: the models named in
/// its "supports" sentences, and the "at Nx" multipliers in its included-usage
/// and purchased-credits sentences. A section missing any of the three is
/// ignored so the bundled multipliers stay in use.
fn speed_rule(markdown: &str, heading: &str) -> Option<SpeedRule> {
    let section = markdown_section(markdown, heading)?;
    let text = section.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut models = HashSet::new();
    let mut included = None;
    let mut credits = None;
    for sentence in text.split(". ") {
        let lower = sentence.to_ascii_lowercase();
        if lower.contains("support") {
            models.extend(gpt_model_ids(sentence));
        }
        let Some(multiplier) = multiplier_after_at(&lower) else {
            continue;
        };
        if lower.contains("included") {
            included.get_or_insert(multiplier);
        } else if lower.contains("credits") {
            credits.get_or_insert(multiplier);
        }
    }
    if models.is_empty() {
        return None;
    }
    Some(SpeedRule {
        models,
        included: included?,
        credits: credits?,
    })
}

fn markdown_section(markdown: &str, heading: &str) -> Option<String> {
    let mut lines = markdown.lines();
    lines.find(|line| {
        line.trim()
            .strip_prefix("## ")
            .is_some_and(|title| title.trim().eq_ignore_ascii_case(heading))
    })?;
    let section = lines
        .take_while(|line| {
            let line = line.trim_start();
            !line.starts_with("# ") && !line.starts_with("## ")
        })
        .collect::<Vec<_>>();
    Some(section.join("\n"))
}

/// Turns names such as "GPT-6.1 Sol" or "GPT-5.6" into the ids Codex logs
/// ("gpt-6.1-sol", "gpt-5.6").
fn gpt_model_ids(sentence: &str) -> Vec<String> {
    let words = sentence.split_whitespace().collect::<Vec<_>>();
    let mut ids = Vec::new();
    let mut index = 0;
    while index < words.len() {
        let (word, mut ended) = trim_sentence_word(words[index]);
        index += 1;
        let Some(version) = word.strip_prefix("GPT-").filter(|version| {
            version.starts_with(|character: char| character.is_ascii_digit())
                && version.bytes().all(|byte| byte.is_ascii_digit() || byte == b'.')
        }) else {
            continue;
        };
        let mut id = format!("gpt-{version}");
        while !ended && index < words.len() {
            let (name, name_ended) = trim_sentence_word(words[index]);
            if !name.starts_with(|character: char| character.is_ascii_uppercase())
                || !name.bytes().all(|byte| byte.is_ascii_alphanumeric())
                || matches!(name, "Fast" | "Ultrafast" | "Standard" | "Priority")
            {
                break;
            }
            id.push('-');
            id.push_str(&name.to_ascii_lowercase());
            ended = name_ended;
            index += 1;
        }
        ids.push(id);
    }
    ids
}

fn trim_sentence_word(word: &str) -> (&str, bool) {
    let trimmed = word.trim_end_matches(|character: char| {
        matches!(character, ',' | '.' | ';' | ':' | ')')
    });
    (trimmed, trimmed.len() != word.len())
}

fn multiplier_after_at(sentence: &str) -> Option<f64> {
    let words = sentence.split_whitespace().collect::<Vec<_>>();
    words.windows(2).find_map(|pair| {
        if pair[0] != "at" {
            return None;
        }
        trim_sentence_word(pair[1])
            .0
            .strip_suffix('x')?
            .parse::<f64>()
            .ok()
            .filter(|multiplier| multiplier.is_finite() && *multiplier > 1.0 && *multiplier <= 50.0)
    })
}

fn bundled_rate_for_model(model_id: &str) -> Option<ModelRate> {
    let normalized = normalize_pricing_model_id(model_id);
    match normalized.as_str() {
        "gpt-6.1-sol" => Some(ModelRate {
            input_per_million: 2.0,
            cached_input_per_million: 0.1,
            output_per_million: 10.0,
            cache_write_per_million: Some(2.5),
            long_context: Some(LongContextRate {
                input_per_million: 4.0,
                cached_input_per_million: 0.2,
                output_per_million: 15.0,
                cache_write_per_million: Some(5.0),
            }),
            long_context_available: true,
        }),
        "gpt-6-astra" => Some(ModelRate {
            input_per_million: 10.0,
            cached_input_per_million: 1.0,
            output_per_million: 50.0,
            cache_write_per_million: Some(12.5),
            long_context: Some(LongContextRate {
                input_per_million: 20.0,
                cached_input_per_million: 2.0,
                output_per_million: 75.0,
                cache_write_per_million: Some(25.0),
            }),
            long_context_available: true,
        }),
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

/// Lowercases a Codex model id and removes provider prefixes and a trailing
/// `(effort)` label. Snapshot dates and effort suffixes stay, so a pricing row
/// for an exact snapshot still wins over its base model.
fn clean_pricing_model_id(model_id: &str) -> String {
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
    normalized
}

/// Reduces a Codex model id to the base model that price tables list, with no
/// provider prefix, effort label or suffix, or snapshot date. The rule needs no
/// list of known models, so a new row in the official table also prices the
/// dated and effort-suffixed ids Codex logs for that model.
pub(crate) fn normalize_pricing_model_id(model_id: &str) -> String {
    normalize_model_for_grouping(model_id)
}

/// Google Gemini pricing used for Antigravity estimates.
///
/// Google publishes no machine-readable rate table, so TokenBar reads
/// OpenRouter's public model catalog, which lists the same per-token Gemini
/// rates as structured JSON including the long-context override. A reviewed
/// fallback table covers the catalog being unavailable or changing shape.
/// Rates are standard paid-tier text prices in USD per million tokens. Gemini
/// bills thinking tokens at the output rate and cached input at the
/// context-caching rate. Unknown or future model versions stay unpriced instead
/// of inheriting a nearby model's rate.
///
/// Sources:
/// - https://openrouter.ai/api/v1/models
/// - https://ai.google.dev/gemini-api/docs/pricing
#[derive(Debug, Clone)]
pub struct GooglePricing {
    effective_date: NaiveDate,
    catalog_rates: HashMap<String, GoogleRateRow>,
}

impl Default for GooglePricing {
    fn default() -> Self {
        Self::bundled_for_date(Local::now().date_naive())
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct GoogleModelRate {
    input_per_million: f64,
    cached_input_per_million: f64,
    output_per_million: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct GoogleRateRow {
    standard: GoogleModelRate,
    long_context: Option<GoogleModelRate>,
    long_context_min_prompt_tokens: i64,
}

/// Gemini Pro switches to a long-context rate above this prompt size. The
/// catalog carries its own threshold; this is the reviewed fallback.
const GOOGLE_LONG_CONTEXT_THRESHOLD: i64 = 200_000;

/// Minimum number of priced Gemini models before the catalog is trusted.
const GOOGLE_MINIMUM_CATALOG_MODELS: usize = 8;

impl GooglePricing {
    pub fn bundled_for_date(effective_date: NaiveDate) -> Self {
        Self {
            effective_date,
            catalog_rates: HashMap::new(),
        }
    }

    pub fn from_openrouter_catalog(
        json: &str,
        effective_date: NaiveDate,
    ) -> Result<Self, String> {
        Ok(Self {
            effective_date,
            catalog_rates: parse_openrouter_gemini_rates(json)?,
        })
    }

    pub fn from_openrouter_catalog_file(
        path: &Path,
        effective_date: NaiveDate,
    ) -> Result<Self, String> {
        let metadata = fs::metadata(path)
            .map_err(|error| format!("could not inspect OpenRouter catalog: {error}"))?;
        if metadata.len() < 4_096 || metadata.len() > 16_000_000 {
            return Err("OpenRouter catalog has an invalid size".to_string());
        }
        let json = fs::read_to_string(path)
            .map_err(|error| format!("could not read OpenRouter catalog: {error}"))?;
        Self::from_openrouter_catalog(&json, effective_date)
    }

    pub fn calculate_token_costs(
        &self,
        model_id: &str,
        usage: &TokenBreakdown,
    ) -> Option<TokenCostBreakdown> {
        let prompt_tokens = usage
            .input
            .max(0)
            .saturating_add(usage.cache_read.max(0))
            .saturating_add(usage.cache_write.max(0));
        let row = self.row_for_model(model_id)?;
        let rate = match row.long_context {
            Some(long) if prompt_tokens > row.long_context_min_prompt_tokens => long,
            _ => row.standard,
        };
        let costs = TokenCostBreakdown {
            input: usage.input.max(0) as f64 * rate.input_per_million / TOKENS_PER_MILLION,
            output: usage.output.max(0) as f64 * rate.output_per_million / TOKENS_PER_MILLION,
            cache_read: usage.cache_read.max(0) as f64 * rate.cached_input_per_million
                / TOKENS_PER_MILLION,
            cache_write: usage.cache_write.max(0) as f64 * rate.input_per_million
                / TOKENS_PER_MILLION,
            reasoning: usage.reasoning.max(0) as f64 * rate.output_per_million
                / TOKENS_PER_MILLION,
        };
        costs.total().is_finite().then_some(costs)
    }

    fn row_for_model(&self, model_id: &str) -> Option<GoogleRateRow> {
        let normalized = normalize_google_model_id(model_id);
        self.catalog_rates
            .get(&normalized)
            .copied()
            .or_else(|| bundled_google_row(&normalized, self.effective_date))
    }
}

/// Reviewed fallback rates, last checked 2026-09-03 against Google's pricing
/// page. Google publishes the scheduled 2027-01-01 increase alongside the
/// current price, so both are recorded here and selected by `effective_date`.
fn bundled_google_row(
    normalized_model_id: &str,
    effective_date: NaiveDate,
) -> Option<GoogleRateRow> {
    let raised = effective_date >= NaiveDate::from_ymd_opt(2027, 1, 1).unwrap();
    let rate = |input: f64, cached_input: f64, output: f64| GoogleModelRate {
        input_per_million: input,
        cached_input_per_million: cached_input,
        output_per_million: output,
    };
    let flat = |input: f64, cached_input: f64, output: f64| GoogleRateRow {
        standard: rate(input, cached_input, output),
        long_context: None,
        long_context_min_prompt_tokens: GOOGLE_LONG_CONTEXT_THRESHOLD,
    };
    let tiered = |standard: (f64, f64, f64), long: (f64, f64, f64)| GoogleRateRow {
        standard: rate(standard.0, standard.1, standard.2),
        long_context: Some(rate(long.0, long.1, long.2)),
        long_context_min_prompt_tokens: GOOGLE_LONG_CONTEXT_THRESHOLD,
    };
    Some(match normalized_model_id {
        "gemini-3.8-flash" | "gemini-3.7-flash" | "gemini-3.6-flash" if raised => {
            flat(1.5, 0.15, 7.5)
        }
        "gemini-3.8-flash" | "gemini-3.7-flash" | "gemini-3.6-flash" => flat(0.75, 0.075, 3.75),
        "gemini-3.5-flash" => flat(1.5, 0.15, 9.0),
        "gemini-3.5-flash-lite" => flat(0.3, 0.03, 2.5),
        "gemini-3.1-flash-lite" => flat(0.25, 0.025, 1.5),
        "gemini-3.1-pro" => tiered((2.0, 0.2, 12.0), (4.0, 0.4, 18.0)),
        "gemini-2.5-pro" => tiered((1.25, 0.125, 10.0), (2.5, 0.25, 15.0)),
        "gemini-2.5-flash" => flat(0.3, 0.03, 2.5),
        "gemini-2.5-flash-lite" => flat(0.1, 0.01, 0.4),
        _ => return None,
    })
}

fn normalize_google_model_id(model_id: &str) -> String {
    let mut normalized = model_id.trim().to_ascii_lowercase();
    for prefix in ["models/", "google/", "gemini/", "vertex_ai/", "vertex/"] {
        if let Some(model) = normalized.strip_prefix(prefix) {
            normalized = model.to_string();
            break;
        }
    }
    if let Some(index) = normalized.find("-preview") {
        normalized.truncate(index);
    }
    for suffix in ["-latest", "-thinking", "-exp"] {
        if let Some(model) = normalized.strip_suffix(suffix) {
            normalized = model.to_string();
        }
    }
    normalized
}

/// Reads the Gemini rows of OpenRouter's model catalog.
///
/// Prices are USD per token, and an `overrides` entry carries the long-context
/// tier. Discounted variants such as `:batch` are ignored so a Gemini request
/// never inherits a cheaper delivery mode.
fn parse_openrouter_gemini_rates(
    json: &str,
) -> Result<HashMap<String, GoogleRateRow>, String> {
    let catalog: serde_json::Value = serde_json::from_str(json)
        .map_err(|error| format!("OpenRouter catalog is not valid JSON: {error}"))?;
    let models = catalog
        .get("data")
        .and_then(serde_json::Value::as_array)
        .ok_or("OpenRouter catalog has no model list")?;

    let mut rates: HashMap<String, (usize, GoogleRateRow)> = HashMap::new();
    for model in models {
        let Some(id) = model.get("id").and_then(serde_json::Value::as_str) else {
            continue;
        };
        if !id.starts_with("google/gemini") || id.contains(':') {
            continue;
        }
        let Some(pricing) = model.get("pricing") else {
            continue;
        };
        let Some(standard) = openrouter_rate(pricing) else {
            continue;
        };
        let override_entry = pricing
            .get("overrides")
            .and_then(serde_json::Value::as_array)
            .and_then(|entries| {
                entries.iter().find(|entry| {
                    entry
                        .get("min_prompt_tokens")
                        .and_then(serde_json::Value::as_i64)
                        .is_some_and(|threshold| threshold > 0)
                })
            });
        let long_context_min_prompt_tokens = override_entry
            .and_then(|entry| entry.get("min_prompt_tokens"))
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(GOOGLE_LONG_CONTEXT_THRESHOLD);
        let long_context = override_entry.and_then(|entry| {
            Some(GoogleModelRate {
                input_per_million: openrouter_price(entry.get("prompt"))
                    .unwrap_or(standard.input_per_million),
                cached_input_per_million: openrouter_price(entry.get("input_cache_read"))
                    .unwrap_or(standard.cached_input_per_million),
                output_per_million: openrouter_price(entry.get("completion"))?,
            })
        });

        let key = normalize_google_model_id(id);
        let row = GoogleRateRow {
            standard,
            long_context,
            long_context_min_prompt_tokens,
        };
        // Several catalog ids normalize to one model; keep the plainest one.
        match rates.get(&key) {
            Some((length, _)) if *length <= id.len() => {}
            _ => {
                rates.insert(key, (id.len(), row));
            }
        }
    }

    if rates.len() < GOOGLE_MINIMUM_CATALOG_MODELS {
        return Err(format!(
            "OpenRouter catalog listed only {} priced Gemini models",
            rates.len()
        ));
    }
    Ok(rates.into_iter().map(|(key, (_, row))| (key, row)).collect())
}

fn openrouter_rate(pricing: &serde_json::Value) -> Option<GoogleModelRate> {
    let input = openrouter_price(pricing.get("prompt"))?;
    let output = openrouter_price(pricing.get("completion"))?;
    if output <= 0.0 {
        return None;
    }
    Some(GoogleModelRate {
        input_per_million: input,
        cached_input_per_million: openrouter_price(pricing.get("input_cache_read"))
            .unwrap_or(input),
        output_per_million: output,
    })
}

/// OpenRouter quotes USD per token, usually as a string.
fn openrouter_price(value: Option<&serde_json::Value>) -> Option<f64> {
    let value = value?;
    let per_token = match value {
        serde_json::Value::String(text) => text.trim().parse::<f64>().ok()?,
        serde_json::Value::Number(number) => number.as_f64()?,
        _ => return None,
    };
    let per_million = per_token * TOKENS_PER_MILLION;
    (per_million.is_finite() && per_million >= 0.0).then_some(per_million)
}
