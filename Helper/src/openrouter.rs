//! Public OpenRouter token quotes. No account credentials or session data are sent.
use crate::{
    pricing::{normalize_anthropic_model_id, normalize_pricing_model_id},
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
        for row in rows {
            let Some(id) = row.get("id").and_then(Value::as_str) else {
                continue;
            };
            let Some((author, slug)) = id.split_once('/') else {
                continue;
            };
            if !["openai", "anthropic"].contains(&author)
                || slug.contains(':')
                || slug.contains('/')
            {
                continue;
            }
            let canonical = key(author, slug);
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
        Ok(Self { models })
    }
    pub fn model_count(&self) -> usize {
        self.models.len()
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
        if entry.thresholds.is_empty() && known_long_context && prompt > 272000 {
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
        let cache_write = match writes {
            Some(writes) => {
                let total = usage.cache_write.max(0);
                let one_hour = writes.one_hour.max(0).min(total);
                cost(one_hour, rates.cache_write_1h)? + cost(total - one_hour, rates.cache_write)?
            }
            _ => cost(usage.cache_write, rates.cache_write)?,
        };
        let result = TokenCostBreakdown {
            input: cost(usage.input, rates.input)?,
            output: cost(usage.output, rates.output)?,
            cache_read: cost(usage.cache_read, rates.cache_read)?,
            cache_write,
            reasoning: cost(usage.reasoning, rates.output)?,
        };
        result.total().is_finite().then_some(result)
    }
    fn valid(&self) -> bool {
        !self.models.is_empty()
            && self.models.len() <= 10000
            && self.models.iter().all(|(id, price)| {
                id.len() <= 200
                    && (id.starts_with("openai/") || id.starts_with("anthropic/"))
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
fn load_cache(dir: &Path, now: i64) -> Option<Cache> {
    let path = dir.join("openrouter-pricing.json");
    if fs::metadata(&path).ok()?.len() > MAX_BYTES as u64 {
        return None;
    }
    let cache: Cache = serde_json::from_slice(&fs::read(path).ok()?).ok()?;
    (cache.version == 1
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
                version: 1,
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
