use crate::usage::{ServiceTier, TokenBreakdown};

const TOKENS_PER_MILLION: f64 = 1_000_000.0;

#[derive(Debug, Clone, Copy, PartialEq)]
struct ModelRate {
    input_per_million: f64,
    cached_input_per_million: f64,
    output_per_million: f64,
    cache_write_per_million: Option<f64>,
}

/// TokenBar's bundled Codex pricing catalog.
///
/// Rates are standard API text-token prices in USD per million tokens, last
/// reviewed 2026-07-14 against the official OpenAI model pages. TokenBar never
/// reads Tokscale, LiteLLM, OpenRouter, or user-level pricing caches. A model
/// without an explicit bundled rate returns `None`; callers must keep
/// that request's cost source unknown instead of presenting a fabricated $0.
/// These values are compatibility estimates for activity comparison, not an
/// OpenAI invoice. In particular, the Codex research-preview
/// `gpt-5.3-codex-spark` id has no public per-token API rate, so it uses
/// GPT-5.3-Codex's public rate. Recognized OpenAI model ids keep their estimate
/// even when a local Codex gateway records a custom provider name.
///
/// GPT-5.4, GPT-5.5, and GPT-5.6 documentation applies 2x input and 1.5x
/// output pricing to prompts over 272K input tokens. TokenBar intentionally
/// does not apply that multiplier yet so existing TokenBar/Tokscale history
/// does not silently change. A future billing-estimate mode should expose the
/// different semantic explicitly before enabling it.
///
/// Sources:
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
#[derive(Debug, Clone, Copy, Default)]
pub struct CodexPricing;

impl CodexPricing {
    pub const fn bundled() -> Self {
        Self
    }

    pub fn calculate_cost_with_provider(
        &self,
        model_id: &str,
        _provider_id: Option<&str>,
        usage: &TokenBreakdown,
    ) -> Option<f64> {
        let rate = rate_for_model(model_id)?;
        if usage.cache_write > 0 && rate.cache_write_per_million.is_none() {
            return None;
        }

        let input_cost = usage.input.max(0) as f64 * rate.input_per_million / TOKENS_PER_MILLION;
        let cached_cost =
            usage.cache_read.max(0) as f64 * rate.cached_input_per_million / TOKENS_PER_MILLION;
        let cache_write_cost = usage.cache_write.max(0) as f64
            * rate.cache_write_per_million.unwrap_or_default()
            / TOKENS_PER_MILLION;
        let output_tokens = usage.output.max(0).saturating_add(usage.reasoning.max(0));
        let output_cost = output_tokens as f64 * rate.output_per_million / TOKENS_PER_MILLION;
        let total = input_cost + cached_cost + cache_write_cost + output_cost;
        total.is_finite().then_some(total)
    }

    /// Applies Codex Fast/Priority pricing to the standard API-equivalent
    /// estimate. The tier changes cost only; token and cache counts stay raw.
    /// Models without an explicitly verified Priority rate keep their standard
    /// estimate instead of receiving a guessed multiplier.
    pub fn calculate_cost_with_service_tier(
        &self,
        model_id: &str,
        provider_id: Option<&str>,
        usage: &TokenBreakdown,
        service_tier: ServiceTier,
    ) -> Option<f64> {
        let base = self.calculate_cost_with_provider(model_id, provider_id, usage)?;
        let multiplier = if service_tier == ServiceTier::Fast {
            fast_cost_multiplier(model_id).unwrap_or(1.0)
        } else {
            1.0
        };
        let total = base * multiplier;
        total.is_finite().then_some(total)
    }
}

/// Official OpenAI Priority prices reviewed 2026-07-14:
/// - GPT-5.4: 2x
/// - GPT-5.5: 2.5x
/// - GPT-5.6 Sol/Terra/Luna: 2x
///
/// Sources:
/// - https://developers.openai.com/api/docs/pricing
/// - https://developers.openai.com/api/docs/guides/priority-processing
fn fast_cost_multiplier(model_id: &str) -> Option<f64> {
    match normalize_pricing_model_id(model_id).as_str() {
        "gpt-5.4" => Some(2.0),
        "gpt-5.5" => Some(2.5),
        "gpt-5.6" | "gpt-5.6-sol" | "gpt-5.6-terra" | "gpt-5.6-luna" => Some(2.0),
        _ => None,
    }
}

fn rate_for_model(model_id: &str) -> Option<ModelRate> {
    let normalized = normalize_pricing_model_id(model_id);
    match normalized.as_str() {
        "codex-mini-latest" => Some(ModelRate {
            input_per_million: 1.5,
            cached_input_per_million: 0.375,
            output_per_million: 6.0,
            cache_write_per_million: None,
        }),
        "gpt-5" | "gpt-5-codex" | "gpt-5.1" | "gpt-5.1-codex" | "gpt-5.1-codex-max" => {
            Some(ModelRate {
                input_per_million: 1.25,
                cached_input_per_million: 0.125,
                output_per_million: 10.0,
                cache_write_per_million: None,
            })
        }
        "gpt-5-mini" | "gpt-5.1-codex-mini" => Some(ModelRate {
            input_per_million: 0.25,
            cached_input_per_million: 0.025,
            output_per_million: 2.0,
            cache_write_per_million: None,
        }),
        "gpt-5.2" | "gpt-5.2-codex" | "gpt-5.3-codex" | "gpt-5.3-codex-spark" => Some(ModelRate {
            input_per_million: 1.75,
            cached_input_per_million: 0.175,
            output_per_million: 14.0,
            cache_write_per_million: None,
        }),
        "gpt-5.4" => Some(ModelRate {
            input_per_million: 2.5,
            cached_input_per_million: 0.25,
            output_per_million: 15.0,
            cache_write_per_million: None,
        }),
        "gpt-5.4-mini" => Some(ModelRate {
            input_per_million: 0.75,
            cached_input_per_million: 0.075,
            output_per_million: 4.5,
            cache_write_per_million: None,
        }),
        "gpt-5.5" => Some(ModelRate {
            input_per_million: 5.0,
            cached_input_per_million: 0.5,
            output_per_million: 30.0,
            cache_write_per_million: None,
        }),
        "gpt-5.6" | "gpt-5.6-sol" => Some(ModelRate {
            input_per_million: 5.0,
            cached_input_per_million: 0.5,
            output_per_million: 30.0,
            cache_write_per_million: Some(6.25),
        }),
        "gpt-5.6-terra" => Some(ModelRate {
            input_per_million: 2.5,
            cached_input_per_million: 0.25,
            output_per_million: 15.0,
            cache_write_per_million: Some(3.125),
        }),
        "gpt-5.6-luna" => Some(ModelRate {
            input_per_million: 1.0,
            cached_input_per_million: 0.1,
            output_per_million: 6.0,
            cache_write_per_million: Some(1.25),
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
    }

    #[test]
    fn preserves_compatibility_pricing_for_long_context_usage() {
        let usage = TokenBreakdown {
            input: 300_000,
            output: 100_000,
            ..Default::default()
        };
        let cost = CodexPricing::bundled()
            .calculate_cost_with_provider("gpt-5.5", Some("openai"), &usage)
            .unwrap();
        assert!((cost - 4.5).abs() < 1e-9);
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
    fn gpt_5_4_keeps_the_compatibility_rate_above_272k() {
        let usage = TokenBreakdown {
            input: 300_000,
            output: 100_000,
            ..Default::default()
        };
        let cost = CodexPricing::bundled()
            .calculate_cost_with_provider("gpt-5.4-2026-03-05", Some("openai"), &usage)
            .unwrap();
        assert!((cost - 2.25).abs() < 1e-9);
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
        assert!((custom_provider - 35.5).abs() < 1e-9);
    }
}
