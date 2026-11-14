//! Public OpenRouter token quotes. No account credentials or session data are sent.
use crate::{
    pricing::{normalize_anthropic_model_id, normalize_google_model_id, normalize_pricing_model_id},
    usage::{CacheWriteBreakdown, TokenBreakdown, TokenCostBreakdown},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::Read,
    path::{Path, PathBuf},
    time::Duration,
};

pub const MODELS_URL: &str = "https://openrouter.ai/api/v1/models";
const MAX_BYTES: usize = 16 * 1024 * 1024;
const DAY_MS: i64 = 86_400_000;
const RETRY_MS: i64 = 3_600_000;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Rates {
    input: Option<f64>,
    output: Option<f64>,
    cache_read: Option<f64>,
    cache_write: Option<f64>,
    cache_write_1h: Option<f64>,
}
impl Rates {
    fn valid(&self, partial: bool) -> bool {
        (partial || (self.input.is_some() && self.output.is_some()))
            && [
                self.input,
                self.output,
                self.cache_read,
                self.cache_write,
                self.cache_write_1h,
            ]
            .into_iter()
            .flatten()
            .all(|v| v.is_finite() && (0.0..=1.0).contains(&v))
    }
    fn overlay(&mut self, other: &Self) {
        if other.input.is_some() {
            self.input = other.input;
        }
        if other.output.is_some() {
            self.output = other.output;
        }
        if other.cache_read.is_some() {
            self.cache_read = other.cache_read;
        }
        if other.cache_write.is_some() {
            self.cache_write = other.cache_write;
        }
        if other.cache_write_1h.is_some() {
            self.cache_write_1h = other.cache_write_1h;
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Threshold {
    min_prompt_tokens: i64,
    rates: Rates,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct ModelPrice {
    rates: Rates,
    thresholds: Vec<Threshold>,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Catalog {
    models: HashMap<String, ModelPrice>,
    /// Model-id to context-window size, taken from the catalog's public
    /// `context_length` field. Kept beside the prices so one download serves
    /// both, and so a model whose local log records no window still gets one.
    #[serde(default)]
    context_windows: HashMap<String, i64>,
}

/// Context windows are token counts; reject anything outside a plausible range
/// so a malformed catalog cannot produce a nonsensical occupancy reading.
const MAX_CONTEXT_WINDOW: i64 = 100_000_000;

/// Normalizes a locally recorded model id for a catalog context-window lookup.
///
/// Local logs spell the same model in several ways (`gpt-5.4(high)`,
/// `anthropic/claude-sonnet-4-5`, `models/gemini-2.5-pro`), while the catalog
/// uses one `author/slug` row per model. This strips the provider prefix, the
/// reasoning tier, and the vendor-specific decorations that never appear in a
/// catalog id, so the lookup keys stay comparable.
fn normalize_context_model_id(model: &str) -> String {
    let mut name = model.trim().to_ascii_lowercase();
    if let Some(index) = name.find('(') {
        name.truncate(index);
    }
    for prefix in [
        "models/",
        "openai/",
        "openai_codex/",
        "anthropic/",
        "google/",
        "gemini/",
        "xai/",
        "vertex_ai/",
        "vertex/",
    ] {
        if let Some(rest) = name.strip_prefix(prefix) {
            name = rest.to_string();
            break;
        }
    }
    if let Some(index) = name.find("-preview") {
        name.truncate(index);
    }
    for suffix in ["-latest", "-thinking", "-exp"] {
        if let Some(rest) = name.strip_suffix(suffix) {
            name = rest.to_string();
        }
    }
    // Claude Code writes `claude-sonnet-4-5` while the catalog lists
    // `anthropic/claude-sonnet-4.5`; compare on the dotted spelling.
    name.trim().to_string()
}

fn key(author: &str, model: &str) -> String {
    match author {
        "openai" => {
            let canonical = normalize_pricing_model_id(model);
            format!(
                "openai/{}",
                if canonical == "gpt-5.6" {
                    "gpt-5.6-sol"
                } else {
                    &canonical
                }
            )
        }
        "anthropic" => format!("anthropic/{}", normalize_anthropic_model_id(model)),
        "google" => format!("google/{}", normalize_google_model_id(model)),
        _ => String::new(),
    }
}
fn price(value: Option<&Value>) -> Result<Option<f64>, String> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => value
            .parse::<f64>()
            .ok()
            .filter(|v| v.is_finite() && (0.0..=1.0).contains(v))
            .map(Some)
            .ok_or_else(|| "invalid token price".into()),
        _ => Err("token prices must be decimal strings".into()),
    }
}
fn rates(value: &Value, partial: bool) -> Result<Rates, String> {
    if !value.is_object() {
        return Err("pricing is not an object".into());
    }
    let rates = Rates {
        input: price(value.get("prompt"))?,
        output: price(value.get("completion"))?,
        cache_read: price(value.get("input_cache_read"))?,
        cache_write: price(value.get("input_cache_write"))?,
        cache_write_1h: price(value.get("input_cache_write_1h"))?,
    };
    if !rates.valid(partial) {
        return Err("missing input/output rates".into());
    }
    Ok(rates)
}
impl Catalog {
    pub fn from_json(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > MAX_BYTES {
            return Err("catalog exceeds 16 MiB".into());
        }
        let value: Value =
            serde_json::from_slice(bytes).map_err(|_| "catalog is not valid JSON")?;
        if value.pointer("/links/next").is_some_and(|v| !v.is_null()) {
            return Err("incomplete paginated catalog".into());
        }
        let rows = value
            .get("data")
            .and_then(Value::as_array)
            .ok_or("catalog data is not an array")?;
        if rows.len() > 10000 {
            return Err("too many catalog models".into());
        }
        let mut models = HashMap::new();
        let mut context_windows = HashMap::new();
        let mut google_raw_lengths: HashMap<String, usize> = HashMap::new();
        for row in rows {
            let Some(id) = row.get("id").and_then(Value::as_str) else {
                continue;
            };
            let Some((author, slug)) = id.split_once('/') else {
                continue;
            };
            // Context windows cover every listed author, because Claude Code and
            // Antigravity logs record no window of their own. Prices stay
            // limited to the authors TokenBar actually prices locally.
            if let Some(window) = row.get("context_length").and_then(Value::as_i64) {
                if window > 0 && window <= MAX_CONTEXT_WINDOW && !slug.contains(':') {
                    context_windows.insert(id.to_string(), window);
                }
            }
            if !["openai", "anthropic", "google"].contains(&author)
                || slug.contains(':')
                || slug.contains('/')
            {
                continue;
            }
            if author == "google" && !slug.starts_with("gemini") {
                continue;
            }
            let canonical = key(author, slug);
            if author == "google" {
                let Ok(base) = rates(&row["pricing"], false) else {
                    continue;
                };
                if base.output.unwrap_or(0.0) <= 0.0 {
                    continue;
                }
                if google_raw_lengths
                    .get(&canonical)
                    .is_some_and(|length| *length <= id.len())
                {
                    continue;
                }
                let mut thresholds = Vec::new();
                if let Some(overrides) = row["pricing"].get("overrides") {
                    if let Some(overrides) = overrides.as_array() {
                        for item in overrides.iter().take(64) {
                            let Some(min) = item.get("min_prompt_tokens").and_then(Value::as_i64) else {
                                continue;
                            };
                            if !(0..=10_000_000).contains(&min) {
                                continue;
                            }
                            if let Ok(override_rates) = rates(item, true) {
                                thresholds.push(Threshold {
                                    min_prompt_tokens: min,
                                    rates: override_rates,
                                });
                            }
                        }
                    }
                }
                google_raw_lengths.insert(canonical.clone(), id.len());
                models.insert(
                    canonical,
                    ModelPrice {
                        rates: base,
                        thresholds,
                    },
                );
                continue;
            }
            // Use current canonical model entries; a dated/variant quote must
            // not overwrite the current model's base rate.
            let plain_slug = if author == "anthropic" {
                slug.replace('.', "-")
            } else {
                slug.to_string()
            };
            if canonical != format!("{author}/{plain_slug}") {
                continue;
            }
            let base = rates(&row["pricing"], false)?;
            let mut thresholds = Vec::new();
            if let Some(overrides) = row["pricing"].get("overrides") {
                let overrides = overrides.as_array().ok_or("invalid overrides")?;
                if overrides.len() > 64 {
                    return Err("too many pricing overrides".into());
                }
                for item in overrides {
                    let object = item.as_object().ok_or("invalid pricing override")?;
                    const KEYS: [&str; 6] = [
                        "min_prompt_tokens",
                        "prompt",
                        "completion",
                        "input_cache_read",
                        "input_cache_write",
                        "input_cache_write_1h",
                    ];
                    // The helper has no request-time tariff input. Do not apply
                    // time schedules or unknown conditions to historical usage.
                    if object.keys().any(|k| !KEYS.contains(&k.as_str())) {
                        continue;
                    }
                    let Some(min) = item.get("min_prompt_tokens").and_then(Value::as_i64) else {
                        continue;
                    };
                    if !(0..=10_000_000).contains(&min) {
                        return Err("invalid context threshold".into());
                    }
                    thresholds.push(Threshold {
                        min_prompt_tokens: min,
                        rates: rates(item, true)?,
                    });
                }
            }
            if models
                .insert(
                    canonical,
                    ModelPrice {
                        rates: base,
                        thresholds,
                    },
                )
                .is_some()
            {
                return Err("duplicate model quote".into());
            }
        }
        if models.is_empty() {
            return Err("catalog contains no supported model quotes".into());
        }
        Ok(Self {
            models,
            context_windows,
        })
    }
    pub fn model_count(&self) -> usize {
        self.models.len()
    }
    /// Resolves a model's context window from the catalog.
    ///
    /// Local logs and the catalog disagree on spelling (`claude-sonnet-4-5`
    /// versus `anthropic/claude-sonnet-4.5`, `gpt-5.4(high)` versus
    /// `openai/gpt-5.4`), so the lookup compares provider-stripped slugs with
    /// dots and dashes treated alike. This is only a fallback for models whose
    /// own log records no window, so a rare slug collision is preferable to
    /// showing no occupancy at all.
    pub fn context_window(&self, model: &str) -> Option<i64> {
        let normalized = normalize_context_model_id(model);
        if normalized.is_empty() {
            return None;
        }
        if let Some(window) = self.context_windows.get(&normalized) {
            return Some(*window);
        }
        let dashed = normalized.replace('.', "-");
        // Catalog keys keep their `author/` prefix while local model ids usually
        // drop it, so compare on the author-stripped slug with dots and dashes
        // treated alike.
        self.context_windows
            .iter()
            .find(|(id, _)| {
                let slug = id.rsplit('/').next().unwrap_or(id);
                slug.replace('.', "-") == dashed
            })
            .map(|(_, window)| *window)
    }
    pub fn context_window_count(&self) -> usize {
        self.context_windows.len()
    }
    pub fn costs(
        &self,
        author: &str,
        model: &str,
        usage: &TokenBreakdown,
        writes: Option<&CacheWriteBreakdown>,
        known_long_context: bool,
    ) -> Option<TokenCostBreakdown> {
        let entry = self.models.get(&key(author, model))?;
        let prompt = usage
            .input
            .max(0)
            .saturating_add(usage.cache_read.max(0))
            .saturating_add(usage.cache_write.max(0));
        let mut rates = entry.rates.clone();
        if known_long_context {
            for override_ in &entry.thresholds {
                if prompt > override_.min_prompt_tokens {
                    rates.overlay(&override_.rates);
                }
            }
        }
        // When the quote omits context overrides, retain the verified OpenAI
        // long-context rule instead of silently treating the whole prompt as short.
        if author == "openai" && entry.thresholds.is_empty() && known_long_context && prompt > 272000 {
            rates.input = rates.input.map(|v| v * 2.0);
            rates.cache_read = rates.cache_read.map(|v| v * 2.0);
            rates.cache_write = rates.cache_write.map(|v| v * 2.0);
            rates.output = rates.output.map(|v| v * 1.5);
        }
        fn cost(tokens: i64, rate: Option<f64>) -> Option<f64> {
            if tokens <= 0 {
                Some(0.0)
            } else {
                Some(tokens as f64 * rate?)
            }
        }
        let cache_read_rate = if author == "google" {
            rates.cache_read.or(rates.input)
        } else {
            rates.cache_read
        };
        let cache_write_rate = if author == "google" {
            rates.cache_write.or(rates.input)
        } else {
            rates.cache_write
        };
        let cache_write = match writes {
            Some(writes) => {
                let total = usage.cache_write.max(0);
                let one_hour = writes.one_hour.max(0).min(total);
                cost(one_hour, rates.cache_write_1h)? + cost(total - one_hour, cache_write_rate)?
            }
            _ => cost(usage.cache_write, cache_write_rate)?,
        };
        let result = TokenCostBreakdown {
            input: cost(usage.input, rates.input)?,
            output: cost(usage.output, rates.output)?,
            cache_read: cost(usage.cache_read, cache_read_rate)?,
            cache_write,
            reasoning: cost(usage.reasoning, rates.output)?,
        };
        result.total().is_finite().then_some(result)
    }
    fn valid(&self) -> bool {
        !self.models.is_empty()
            && self.models.len() <= 10000
            && self.context_windows.len() <= 10000
            && self
                .context_windows
                .iter()
                .all(|(id, window)| id.len() <= 200 && *window > 0 && *window <= MAX_CONTEXT_WINDOW)
            && self.models.iter().all(|(id, price)| {
                id.len() <= 200
                    && (id.starts_with("openai/")
                        || id.starts_with("anthropic/")
                        || id.starts_with("google/"))
                    && price.rates.valid(false)
                    && price.thresholds.len() <= 64
                    && price.thresholds.iter().all(|t| {
                        (0..=10_000_000).contains(&t.min_prompt_tokens) && t.rates.valid(true)
                    })
            })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogStatus {
    pub source: String,
    pub updated_at_ms: Option<i64>,
    pub model_count: usize,
    pub status: String,
}
pub struct CatalogLoad {
    pub catalog: Option<Catalog>,
    pub status: CatalogStatus,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Cache {
    version: u32,
    fetched_at_ms: i64,
    catalog: Catalog,
}

/// Bumped to 3 when the catalog began retaining `google/gemini*` prices so
/// cached version-2 files (OpenAI/Anthropic prices only) are refreshed.
const CACHE_VERSION: u32 = 3;
fn load_cache(dir: &Path, now: i64) -> Option<Cache> {
    let path = dir.join("openrouter-pricing.json");
    if fs::metadata(&path).ok()?.len() > MAX_BYTES as u64 {
        return None;
    }
    let cache: Cache = serde_json::from_slice(&fs::read(path).ok()?).ok()?;
    (cache.version == CACHE_VERSION
        && cache.fetched_at_ms > 0
        && cache.fetched_at_ms <= now + 300000
        && cache.catalog.valid())
    .then_some(cache)
}
fn result(cache: Option<Cache>, status: &str) -> CatalogLoad {
    let metadata = CatalogStatus {
        source: if cache.is_some() {
            "openrouter"
        } else {
            "bundled"
        }
        .into(),
        updated_at_ms: cache.as_ref().map(|c| c.fetched_at_ms),
        model_count: cache.as_ref().map(|c| c.catalog.model_count()).unwrap_or(0),
        status: status.into(),
    };
    CatalogLoad {
        catalog: cache.map(|c| c.catalog),
        status: metadata,
    }
}
fn private_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let temp = path.with_extension(format!("{}.tmp", std::process::id()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&temp)
        .map_err(|_| "cannot write pricing cache")?;
    let _temp_guard = RefreshLock(temp.clone());
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|_| "cannot save pricing cache")?;
    drop(file);
    fs::rename(temp, path).map_err(|_| "cannot replace pricing cache".into())
}
struct RefreshLock(PathBuf);
impl Drop for RefreshLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
pub fn default_cache_dir() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("TOKENBAR_PRICING_CACHE_DIR").filter(|s| !s.is_empty()) {
        return Some(path.into());
    }
    #[cfg(windows)]
    if let Some(path) = std::env::var_os("LOCALAPPDATA") {
        return Some(PathBuf::from(path).join("TokenBar/pricing"));
    }
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    #[cfg(target_os = "macos")]
    {
        Some(home.join("Library/Application Support/TokenBar/pricing"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        Some(
            std::env::var_os("XDG_CACHE_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".cache"))
                .join("tokenbar/pricing"),
        )
    }
}
pub fn refresh(dir: &Path, offline: bool) -> CatalogLoad {
    refresh_with(
        dir,
        chrono::Utc::now().timestamp_millis(),
        offline,
        download,
    )
}
fn refresh_with(
    dir: &Path,
    now: i64,
    offline: bool,
    fetch: impl FnOnce() -> Result<Vec<u8>, String>,
) -> CatalogLoad {
    let old = load_cache(dir, now);
    if offline {
        return result(old, "offline");
    }
    if old.as_ref().is_some_and(|c| now - c.fetched_at_ms < DAY_MS) {
        return result(old, "cached");
    }
    if fs::create_dir_all(dir).is_err() {
        return result(old, "cache-unavailable");
    }
    let attempt = dir.join("openrouter-last-attempt");
    if fs::read_to_string(&attempt)
        .ok()
        .and_then(|v| v.trim().parse::<i64>().ok())
        .is_some_and(|t| t <= now && now - t < RETRY_MS)
    {
        return result(old, "retry-wait");
    }
    let lock_path = dir.join("openrouter-refresh.lock");
    if fs::metadata(&lock_path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.elapsed().ok())
        .is_some_and(|age| age > Duration::from_secs(120))
    {
        let _ = fs::remove_file(&lock_path);
    }
    let Ok(lock) = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&lock_path)
    else {
        return result(old, "refresh-in-progress");
    };
    drop(lock);
    let _guard = RefreshLock(lock_path);
    // Another helper may have finished between the first read and acquiring the lock.
    if let Some(fresh) = load_cache(dir, now).filter(|c| now - c.fetched_at_ms < DAY_MS) {
        return result(Some(fresh), "cached");
    }
    let _ = private_write(&attempt, now.to_string().as_bytes());
    let updated = fetch()
        .and_then(|bytes| Catalog::from_json(&bytes))
        .and_then(|catalog| {
            let cache = Cache {
                version: CACHE_VERSION,
                fetched_at_ms: now,
                catalog,
            };
            let bytes = serde_json::to_vec(&cache).map_err(|_| "cannot encode pricing cache")?;
            private_write(&dir.join("openrouter-pricing.json"), &bytes)?;
            Ok(cache)
        });
    match updated {
        Ok(cache) => result(Some(cache), "updated"),
        Err(_) => result(old, "update-failed"),
    }
}
fn download() -> Result<Vec<u8>, String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .https_only(true)
        .user_agent("TokenBar pricing updater")
        .build()
        .map_err(|_| "cannot create pricing HTTP client")?;
    let response = client
        .get(MODELS_URL)
        .header("Accept", "application/json")
        .send()
        .map_err(|_| "pricing download failed")?;
    if !response.status().is_success() {
        return Err("pricing server returned an error".into());
    }
    if response
        .content_length()
        .is_some_and(|n| n > MAX_BYTES as u64)
    {
        return Err("pricing response too large".into());
    }
    let mut bytes = Vec::new();
    response
        .take(MAX_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "pricing download interrupted")?;
    if bytes.len() > MAX_BYTES {
        return Err("pricing response too large".into());
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pricing::GooglePricing;
    use chrono::NaiveDate;
    use std::sync::Arc;

    #[test]
    fn catalog_prices_google_gemini_and_tiered_models() {
        let json = br#"{
            "data": [
                {
                    "id": "openai/gpt-5.4",
                    "context_length": 1000000,
                    "pricing": {"prompt": "0.0000025", "completion": "0.000015"}
                },
                {
                    "id": "google/gemini-4-hydrogen",
                    "context_length": 1048576,
                    "pricing": {
                        "prompt": "0.0000015",
                        "completion": "0.0000075",
                        "input_cache_read": "0.000000075",
                        "input_cache_write": "0.0000000833333333333333"
                    }
                },
                {
                    "id": "google/gemini-4-carbon",
                    "context_length": 1048576,
                    "pricing": {
                        "prompt": "0.000002",
                        "completion": "0.00001",
                        "input_cache_read": "0.0000001"
                    }
                },
                {
                    "id": "google/gemini-3.8-flash",
                    "context_length": 1048576,
                    "pricing": {
                        "prompt": "0.000000825",
                        "completion": "0.000004125",
                        "input_cache_read": "0.0000000825"
                    }
                },
                {
                    "id": "google/gemini-3.1-pro-preview",
                    "context_length": 1048576,
                    "pricing": {
                        "prompt": "0.000002",
                        "completion": "0.000012",
                        "input_cache_read": "0.0000002"
                    }
                },
                {
                    "id": "google/gemini-3.1-pro-preview-customtools",
                    "context_length": 1048576,
                    "pricing": {
                        "prompt": "0.000009",
                        "completion": "0.000099"
                    }
                }
            ]
        }"#;
        let catalog = Arc::new(Catalog::from_json(json).expect("catalog should parse"));
        assert!(catalog.valid());
        let pricing = GooglePricing::bundled_for_date(NaiveDate::from_ymd_opt(2026, 11, 14).unwrap())
            .with_openrouter_catalog(Some(catalog));
        let usage = TokenBreakdown {
            input: 1_000_000,
            output: 1_000_000,
            cache_read: 1_000_000,
            cache_write: 0,
            reasoning: 0,
        };
        let hydrogen = pricing
            .calculate_token_costs("gemini-4-hydrogen", &usage)
            .expect("gemini-4-hydrogen should have price");
        assert!((hydrogen.total() - 9.075).abs() < 1e-6);

        let carbon = pricing
            .calculate_token_costs("gemini-4-carbon", &usage)
            .expect("gemini-4-carbon should have price");
        assert!((carbon.total() - 12.1).abs() < 1e-6);

        let tiered = pricing
            .calculate_token_costs("gemini-3.8-flash-tiered", &usage)
            .expect("gemini-3.8-flash-tiered should normalize to gemini-3.8-flash");
        assert!((tiered.total() - 5.0325).abs() < 1e-6);

        let pro = pricing
            .calculate_token_costs("gemini-3.1-pro", &usage)
            .expect("gemini-3.1-pro-preview should be retained with shortest raw id");
        assert!((pro.total() - 14.2).abs() < 1e-6);
    }
}
