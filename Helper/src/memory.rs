use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use chrono::{Days, Local, NaiveDate};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const DEFAULT_PORT: u16 = 4318;
pub const ENDPOINT_PATH: &str = "/v1/metrics";
const MAX_HEADER_BYTES: usize = 16 * 1024;
const MAX_BODY_BYTES: usize = 2 * 1024 * 1024;
const PHASE_ONE_METRIC: &str = "codex.memory.phase1.token_usage";
const PHASE_TWO_METRIC: &str = "codex.memory.phase2.token_usage";
const TOKEN_TYPES: [&str; 6] = [
    "total",
    "input",
    "cached_input",
    "cache_write_input",
    "output",
    "reasoning_output",
];

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryPhaseUsage {
    pub total: i64,
    pub input: i64,
    pub cached_input: i64,
    pub cache_write_input: i64,
    pub output: i64,
    pub reasoning_output: i64,
}

impl MemoryPhaseUsage {
    fn add(&mut self, token_type: &str, tokens: i64) {
        let target = match token_type {
            "total" => &mut self.total,
            "input" => &mut self.input,
            "cached_input" => &mut self.cached_input,
            "cache_write_input" => &mut self.cache_write_input,
            "output" => &mut self.output,
            "reasoning_output" => &mut self.reasoning_output,
            _ => return,
        };
        *target = target.saturating_add(tokens.max(0));
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryUsageTotals {
    pub phase1: MemoryPhaseUsage,
    pub phase2: MemoryPhaseUsage,
}

impl MemoryUsageTotals {
    fn add(&mut self, phase: i64, token_type: &str, tokens: i64) {
        match phase {
            1 => self.phase1.add(token_type, tokens),
            2 => self.phase2.add(token_type, tokens),
            _ => {}
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryDailySummary {
    pub date: String,
    pub phase1: MemoryPhaseUsage,
    pub phase2: MemoryPhaseUsage,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryUsageSnapshot {
    pub collected_from_ms: i64,
    pub last_received_at_ms: Option<i64>,
    pub last_memory_received_at_ms: Option<i64>,
    pub observation_count: i64,
    pub today: MemoryUsageTotals,
    pub range_totals: MemoryUsageTotals,
    pub days: Vec<MemoryDailySummary>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryReceiverConfig {
    pub database_path: PathBuf,
    pub status_path: Option<PathBuf>,
    pub port: u16,
    pub parent_pid: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Temporality {
    Delta = 1,
    Cumulative = 2,
}

#[derive(Debug)]
struct IncomingObservation {
    metric_name: &'static str,
    phase: i64,
    token_type: String,
    temporality: Temporality,
    start_time_unix_nano: u64,
    time_unix_nano: u64,
    resource_fingerprint: String,
    resource_identity: String,
    attribute_fingerprint: String,
    observation_count: Option<u64>,
    sum_tokens: i64,
}

impl IncomingObservation {
    fn series_key(&self) -> String {
        stable_fingerprint(&format!(
            "{}|{}|{}|{}|{}",
            self.metric_name,
            self.resource_fingerprint,
            self.attribute_fingerprint,
            self.token_type,
            self.start_time_unix_nano
        ))
    }

    fn observation_key(&self) -> String {
        stable_fingerprint(&format!(
            "{}|{}|{}|{}|{}",
            self.temporality as i64,
            self.series_key(),
            self.start_time_unix_nano,
            self.time_unix_nano,
            self.sum_tokens
        ))
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
struct IngestStats {
    parsed: usize,
    inserted: usize,
    added_tokens: i64,
}

struct MemoryStore {
    connection: Connection,
}

impl MemoryStore {
    fn open(path: &Path, opened_at_ms: i64) -> Result<Self, String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!("could not create memory telemetry directory: {error}")
            })?;
        }
        let connection = Connection::open(path)
            .map_err(|error| format!("could not open memory telemetry database: {error}"))?;
        set_private_permissions(path)?;
        connection
            .busy_timeout(Duration::from_secs(5))
            .map_err(|error| format!("could not configure memory telemetry database: {error}"))?;
        initialize_schema(&connection, opened_at_ms)?;
        Ok(Self { connection })
    }

    fn ingest_json(&mut self, payload: &Value, received_at_ms: i64) -> Result<IngestStats, String> {
        let observations = parse_observations(payload)?;
        let mut stats = IngestStats {
            parsed: observations.len(),
            ..IngestStats::default()
        };
        let transaction = self
            .connection
            .transaction()
            .map_err(|error| format!("could not start memory telemetry transaction: {error}"))?;
        for observation in observations {
            let Some(delta) = insert_observation(&transaction, &observation, received_at_ms)? else {
                continue;
            };
            stats.inserted += 1;
            stats.added_tokens = stats.added_tokens.saturating_add(delta);
        }
        transaction
            .execute(
                "INSERT INTO memory_metadata(key, value) VALUES('last_received_at_ms', ?1)\
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [received_at_ms.to_string()],
            )
            .map_err(|error| format!("could not update memory telemetry metadata: {error}"))?;
        if stats.parsed > 0 {
            transaction
                .execute(
                    "INSERT INTO memory_metadata(key, value) VALUES('last_memory_received_at_ms', ?1)\
                     ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [received_at_ms.to_string()],
                )
                .map_err(|error| {
                    format!("could not update Memory metric metadata: {error}")
                })?;
        }
        transaction
            .commit()
            .map_err(|error| format!("could not commit memory telemetry transaction: {error}"))?;
        Ok(stats)
    }
}

fn initialize_schema(connection: &Connection, opened_at_ms: i64) -> Result<(), String> {
    connection
        .execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             CREATE TABLE IF NOT EXISTS memory_metadata (
                 key TEXT PRIMARY KEY,
                 value TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS memory_observations (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 observation_key TEXT NOT NULL UNIQUE,
                 received_at_ms INTEGER NOT NULL,
                 event_at_ms INTEGER NOT NULL,
                 metric_name TEXT NOT NULL,
                 phase INTEGER NOT NULL,
                 token_type TEXT NOT NULL,
                 temporality INTEGER NOT NULL,
                 start_time_unix_nano TEXT NOT NULL,
                 time_unix_nano TEXT NOT NULL,
                 resource_fingerprint TEXT NOT NULL,
                 resource_identity TEXT NOT NULL,
                 attribute_fingerprint TEXT NOT NULL,
                 observation_count TEXT,
                 sum_tokens INTEGER NOT NULL,
                 delta_tokens INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS memory_observations_event_idx
                 ON memory_observations(event_at_ms, phase, token_type);
             CREATE TABLE IF NOT EXISTS memory_series_watermarks (
                 series_key TEXT PRIMARY KEY,
                 latest_time_unix_nano TEXT NOT NULL,
                 latest_sum_tokens INTEGER NOT NULL
             );",
        )
        .map_err(|error| format!("could not initialize memory telemetry database: {error}"))?;
    connection
        .execute(
            "INSERT OR IGNORE INTO memory_metadata(key, value) VALUES('schema_version', '1')",
            [],
        )
        .map_err(|error| format!("could not initialize memory telemetry metadata: {error}"))?;
    connection
        .execute(
            "INSERT OR IGNORE INTO memory_metadata(key, value) VALUES('collected_from_ms', ?1)",
            [opened_at_ms.to_string()],
        )
        .map_err(|error| format!("could not initialize memory telemetry start time: {error}"))?;
    Ok(())
}

fn insert_observation(
    transaction: &Transaction<'_>,
    observation: &IncomingObservation,
    received_at_ms: i64,
) -> Result<Option<i64>, String> {
    let series_key = observation.series_key();
    let observation_key = observation.observation_key();
    let event_at_ms = if observation.time_unix_nano == 0 {
        received_at_ms
    } else {
        (observation.time_unix_nano / 1_000_000).min(i64::MAX as u64) as i64
    };
    let inserted = transaction
        .execute(
            "INSERT OR IGNORE INTO memory_observations(
                 observation_key, received_at_ms, event_at_ms, metric_name, phase, token_type,
                 temporality, start_time_unix_nano, time_unix_nano, resource_fingerprint,
                 resource_identity, attribute_fingerprint, observation_count, sum_tokens,
                 delta_tokens
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, 0)",
            params![
                observation_key,
                received_at_ms,
                event_at_ms,
                observation.metric_name,
                observation.phase,
                observation.token_type,
                observation.temporality as i64,
                observation.start_time_unix_nano.to_string(),
                observation.time_unix_nano.to_string(),
                observation.resource_fingerprint,
                observation.resource_identity,
                observation.attribute_fingerprint,
                observation.observation_count.map(|value| value.to_string()),
                observation.sum_tokens,
            ],
        )
        .map_err(|error| format!("could not save memory telemetry observation: {error}"))?;
    if inserted == 0 {
        return Ok(None);
    }

    let delta = match observation.temporality {
        Temporality::Delta => observation.sum_tokens,
        Temporality::Cumulative => cumulative_delta(transaction, &series_key, observation)?,
    }
    .max(0);
    transaction
        .execute(
            "UPDATE memory_observations SET delta_tokens = ?1 WHERE observation_key = ?2",
            params![delta, observation_key],
        )
        .map_err(|error| format!("could not finalize memory telemetry observation: {error}"))?;
    Ok(Some(delta))
}

fn cumulative_delta(
    transaction: &Transaction<'_>,
    series_key: &str,
    observation: &IncomingObservation,
) -> Result<i64, String> {
    let watermark = transaction
        .query_row(
            "SELECT latest_time_unix_nano, latest_sum_tokens
             FROM memory_series_watermarks WHERE series_key = ?1",
            [series_key],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()
        .map_err(|error| format!("could not read memory telemetry watermark: {error}"))?;
    let (delta, should_update) = match watermark {
        None => (observation.sum_tokens, true),
        Some((latest_time, latest_sum)) => {
            let latest_time = latest_time.parse::<u64>().unwrap_or(0);
            if observation.time_unix_nano > latest_time {
                let delta = if observation.sum_tokens >= latest_sum {
                    observation.sum_tokens - latest_sum
                } else {
                    // A lower cumulative value at a later timestamp is a producer reset.
                    observation.sum_tokens
                };
                (delta, true)
            } else if observation.time_unix_nano == latest_time
                && observation.sum_tokens > latest_sum
            {
                (observation.sum_tokens - latest_sum, true)
            } else {
                // Older or lower replacements are retained as raw observations but add no usage.
                (0, false)
            }
        }
    };
    if should_update {
        transaction
            .execute(
                "INSERT INTO memory_series_watermarks(
                     series_key, latest_time_unix_nano, latest_sum_tokens
                 ) VALUES(?1, ?2, ?3)
                 ON CONFLICT(series_key) DO UPDATE SET
                     latest_time_unix_nano = excluded.latest_time_unix_nano,
                     latest_sum_tokens = excluded.latest_sum_tokens",
                params![
                    series_key,
                    observation.time_unix_nano.to_string(),
                    observation.sum_tokens,
                ],
            )
            .map_err(|error| format!("could not update memory telemetry watermark: {error}"))?;
    }
    Ok(delta)
}

pub fn load_usage_snapshot(
    path: &Path,
    today: NaiveDate,
    generated_at_ms: i64,
    day_count: usize,
) -> Result<Option<MemoryUsageSnapshot>, String> {
    if !path.is_file() {
        return Ok(None);
    }
    if day_count == 0 {
        return Err("memory usage day count must be greater than zero".to_string());
    }
    let connection = Connection::open(path)
        .map_err(|error| format!("could not open memory telemetry database: {error}"))?;
    connection
        .busy_timeout(Duration::from_secs(5))
        .map_err(|error| format!("could not configure memory telemetry database: {error}"))?;
    let collected_from_ms = metadata_i64(&connection, "collected_from_ms")?.unwrap_or(generated_at_ms);
    let last_received_at_ms = metadata_i64(&connection, "last_received_at_ms")?;
    let last_memory_received_at_ms =
        metadata_i64(&connection, "last_memory_received_at_ms")?;
    let observation_count = connection
        .query_row("SELECT COUNT(*) FROM memory_observations", [], |row| row.get(0))
        .map_err(|error| format!("could not count memory telemetry observations: {error}"))?;
    let first_day = today
        .checked_sub_days(Days::new((day_count - 1) as u64))
        .ok_or("memory usage day range is too large")?;
    let mut totals_by_day: BTreeMap<NaiveDate, MemoryUsageTotals> = BTreeMap::new();
    let mut statement = connection
        .prepare(
            "SELECT event_at_ms, phase, token_type, delta_tokens
             FROM memory_observations
             WHERE event_at_ms <= ?1 AND delta_tokens > 0
             ORDER BY event_at_ms, id",
        )
        .map_err(|error| format!("could not query memory telemetry observations: {error}"))?;
    let rows = statement
        .query_map([generated_at_ms], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })
        .map_err(|error| format!("could not read memory telemetry observations: {error}"))?;
    for row in rows {
        let (event_at_ms, phase, token_type, delta_tokens) =
            row.map_err(|error| format!("could not decode memory telemetry observation: {error}"))?;
        let Some(timestamp) = chrono::DateTime::from_timestamp_millis(event_at_ms) else {
            continue;
        };
        let date = timestamp.with_timezone(&Local).date_naive();
        if date < first_day || date > today {
            continue;
        }
        totals_by_day
            .entry(date)
            .or_default()
            .add(phase, &token_type, delta_tokens);
    }

    let mut range_totals = MemoryUsageTotals::default();
    let mut days = Vec::with_capacity(day_count);
    for offset in 0..day_count {
        let date = first_day
            .checked_add_days(Days::new(offset as u64))
            .ok_or("memory usage day range is too large")?;
        let totals = totals_by_day.remove(&date).unwrap_or_default();
        add_usage_totals(&mut range_totals, &totals);
        days.push(MemoryDailySummary {
            date: date.format("%Y-%m-%d").to_string(),
            phase1: totals.phase1,
            phase2: totals.phase2,
        });
    }
    let today_totals = days
        .last()
        .map(|day| MemoryUsageTotals {
            phase1: day.phase1.clone(),
            phase2: day.phase2.clone(),
        })
        .unwrap_or_default();
    Ok(Some(MemoryUsageSnapshot {
        collected_from_ms,
        last_received_at_ms,
        last_memory_received_at_ms,
        observation_count,
        today: today_totals,
        range_totals,
        days,
    }))
}

fn metadata_i64(connection: &Connection, key: &str) -> Result<Option<i64>, String> {
    let value = connection
        .query_row(
            "SELECT value FROM memory_metadata WHERE key = ?1",
            [key],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(|error| format!("could not read memory telemetry metadata: {error}"))?;
    Ok(value.and_then(|value| value.parse().ok()))
}

fn add_usage_totals(target: &mut MemoryUsageTotals, source: &MemoryUsageTotals) {
    for (token_type, phase1, phase2) in [
        ("total", source.phase1.total, source.phase2.total),
        ("input", source.phase1.input, source.phase2.input),
        (
            "cached_input",
            source.phase1.cached_input,
            source.phase2.cached_input,
        ),
        (
            "cache_write_input",
            source.phase1.cache_write_input,
            source.phase2.cache_write_input,
        ),
        ("output", source.phase1.output, source.phase2.output),
        (
            "reasoning_output",
            source.phase1.reasoning_output,
            source.phase2.reasoning_output,
        ),
    ] {
        target.phase1.add(token_type, phase1);
        target.phase2.add(token_type, phase2);
    }
}

fn parse_observations(payload: &Value) -> Result<Vec<IncomingObservation>, String> {
    let Some(resource_metrics) = payload.get("resourceMetrics").and_then(Value::as_array) else {
        return Err("OTLP metrics payload is missing resourceMetrics".to_string());
    };
    let mut observations = Vec::new();
    for resource_metric in resource_metrics {
        let resource_attributes = resource_metric
            .pointer("/resource/attributes")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        let resource_fingerprint = attributes_fingerprint(resource_attributes);
        let resource_identity = safe_resource_identity(resource_attributes);
        let Some(scope_metrics) = resource_metric.get("scopeMetrics").and_then(Value::as_array)
        else {
            continue;
        };
        for scope_metric in scope_metrics {
            let scope_fingerprint = stable_fingerprint(
                &canonical_json(scope_metric.get("scope").unwrap_or(&Value::Null)),
            );
            let Some(metrics) = scope_metric.get("metrics").and_then(Value::as_array) else {
                continue;
            };
            for metric in metrics {
                let Some((metric_name, phase)) = metric
                    .get("name")
                    .and_then(Value::as_str)
                    .and_then(memory_metric)
                else {
                    continue;
                };
                let Some(histogram) = metric.get("histogram") else {
                    continue;
                };
                let temporality = parse_temporality(histogram.get("aggregationTemporality"));
                let Some(data_points) = histogram.get("dataPoints").and_then(Value::as_array)
                else {
                    continue;
                };
                for point in data_points {
                    let attributes = point
                        .get("attributes")
                        .and_then(Value::as_array)
                        .map(Vec::as_slice)
                        .unwrap_or(&[]);
                    let Some(token_type) = attribute_string(attributes, "token_type") else {
                        continue;
                    };
                    if !TOKEN_TYPES.contains(&token_type) {
                        continue;
                    }
                    let Some(sum_tokens) = point.get("sum").and_then(parse_token_sum) else {
                        continue;
                    };
                    let start_time_unix_nano = point
                        .get("startTimeUnixNano")
                        .and_then(parse_u64)
                        .unwrap_or(0);
                    let time_unix_nano = point
                        .get("timeUnixNano")
                        .and_then(parse_u64)
                        .unwrap_or(0);
                    let observation_count = point.get("count").and_then(parse_u64);
                    observations.push(IncomingObservation {
                        metric_name,
                        phase,
                        token_type: token_type.to_string(),
                        temporality,
                        start_time_unix_nano,
                        time_unix_nano,
                        resource_fingerprint: stable_fingerprint(&format!(
                            "{resource_fingerprint}|{scope_fingerprint}"
                        )),
                        resource_identity: resource_identity.clone(),
                        attribute_fingerprint: attributes_fingerprint(attributes),
                        observation_count,
                        sum_tokens,
                    });
                }
            }
        }
    }
    Ok(observations)
}

fn memory_metric(name: &str) -> Option<(&'static str, i64)> {
    match name {
        PHASE_ONE_METRIC => Some((PHASE_ONE_METRIC, 1)),
        PHASE_TWO_METRIC => Some((PHASE_TWO_METRIC, 2)),
        _ => None,
    }
}

fn parse_temporality(value: Option<&Value>) -> Temporality {
    match value {
        Some(Value::Number(value)) if value.as_i64() == Some(1) => Temporality::Delta,
        Some(Value::String(value))
            if value == "1" || value.to_ascii_uppercase().contains("DELTA") =>
        {
            Temporality::Delta
        }
        _ => Temporality::Cumulative,
    }
}

fn parse_token_sum(value: &Value) -> Option<i64> {
    if let Some(value) = value.as_i64() {
        return (value >= 0).then_some(value);
    }
    if let Some(value) = value.as_u64() {
        return (value <= i64::MAX as u64).then_some(value as i64);
    }
    let value = value
        .as_f64()
        .or_else(|| value.as_str()?.parse::<f64>().ok())?;
    if !value.is_finite() || value < 0.0 || value > i64::MAX as f64 {
        return None;
    }
    Some(value.round() as i64)
}

fn parse_u64(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_str()?.parse::<u64>().ok())
}

fn attribute_string<'a>(attributes: &'a [Value], expected_key: &str) -> Option<&'a str> {
    attributes.iter().find_map(|attribute| {
        (attribute.get("key")?.as_str()? == expected_key)
            .then(|| attribute.pointer("/value/stringValue")?.as_str())
            .flatten()
    })
}

fn attributes_fingerprint(attributes: &[Value]) -> String {
    let mut values = attributes
        .iter()
        .filter_map(|attribute| {
            let key = attribute.get("key")?.as_str()?;
            let value = attribute.get("value").unwrap_or(&Value::Null);
            Some(format!("{key}={}", canonical_json(value)))
        })
        .collect::<Vec<_>>();
    values.sort();
    stable_fingerprint(&values.join("|"))
}

fn safe_resource_identity(attributes: &[Value]) -> String {
    const SAFE_KEYS: [&str; 7] = [
        "service.name",
        "service.version",
        "service.instance.id",
        "process.pid",
        "process.executable.name",
        "process.command",
        "app.version",
    ];
    let mut values = BTreeMap::new();
    for attribute in attributes {
        let Some(key) = attribute.get("key").and_then(Value::as_str) else {
            continue;
        };
        if !SAFE_KEYS.contains(&key) {
            continue;
        }
        let Some(value) = attribute.get("value") else {
            continue;
        };
        values.insert(key.to_string(), canonical_json(value));
    }
    serde_json::to_string(&values).unwrap_or_else(|_| "{}".to_string())
}

fn canonical_json(value: &Value) -> String {
    match value {
        Value::Object(values) => {
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort();
            let body = keys
                .into_iter()
                .map(|key| {
                    format!(
                        "{}:{}",
                        serde_json::to_string(key).unwrap_or_default(),
                        canonical_json(&values[key])
                    )
                })
                .collect::<Vec<_>>()
                .join(",");
            format!("{{{body}}}")
        }
        Value::Array(values) => format!(
            "[{}]",
            values
                .iter()
                .map(canonical_json)
                .collect::<Vec<_>>()
                .join(",")
        ),
        _ => serde_json::to_string(value).unwrap_or_else(|_| "null".to_string()),
    }
}

fn stable_fingerprint(value: &str) -> String {
    fn lane(bytes: &[u8], seed: u64) -> u64 {
        bytes.iter().fold(seed, |hash, byte| {
            (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3)
        })
    }
    format!(
        "{:016x}{:016x}",
        lane(value.as_bytes(), 0xcbf2_9ce4_8422_2325),
        lane(value.as_bytes(), 0x8422_2325_cbf2_9ce4)
    )
}

pub fn run_receiver(config: MemoryReceiverConfig) -> Result<(), String> {
    let result = run_receiver_inner(&config);
    if let Err(error) = &result {
        if let Some(status_path) = config.status_path.as_deref() {
            let _ = write_status(
                status_path,
                &ReceiverStatus {
                    state: "error",
                    endpoint: format!("http://127.0.0.1:{}{ENDPOINT_PATH}", config.port),
                    started_at_ms: None,
                    message: Some(error.clone()),
                },
            );
        }
    }
    result
}

fn run_receiver_inner(config: &MemoryReceiverConfig) -> Result<(), String> {
    let listener = TcpListener::bind(("127.0.0.1", config.port)).map_err(|error| {
        format!(
            "could not listen on 127.0.0.1:{} for Codex memory metrics: {error}",
            config.port
        )
    })?;
    listener
        .set_nonblocking(true)
        .map_err(|error| format!("could not configure memory metrics listener: {error}"))?;
    let started_at_ms = now_ms();
    let mut store = MemoryStore::open(&config.database_path, started_at_ms)?;
    if let Some(status_path) = config.status_path.as_deref() {
        write_status(
            status_path,
            &ReceiverStatus {
                state: "listening",
                endpoint: format!("http://127.0.0.1:{}{ENDPOINT_PATH}", config.port),
                started_at_ms: Some(started_at_ms),
                message: None,
            },
        )?;
    }
    loop {
        if config.parent_pid.is_some_and(|pid| !process_is_alive(pid)) {
            return Ok(());
        }
        match listener.accept() {
            Ok((mut stream, _)) => {
                if let Err(error) = handle_connection(&mut stream, &mut store) {
                    let _ = write_response(&mut stream, 400, "Bad Request", r#"{"error":"invalid request"}"#);
                    eprintln!("memory metrics request failed: {error}");
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(100));
            }
            Err(error) => return Err(format!("memory metrics listener failed: {error}")),
        }
    }
}

fn handle_connection(stream: &mut TcpStream, store: &mut MemoryStore) -> Result<(), String> {
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|error| error.to_string())?;
    let mut request = Vec::new();
    let header_end = loop {
        if request.len() >= MAX_HEADER_BYTES {
            write_response(stream, 431, "Request Header Fields Too Large", "{}")
                .map_err(|error| error.to_string())?;
            return Ok(());
        }
        let mut buffer = [0_u8; 4096];
        let read = stream.read(&mut buffer).map_err(|error| error.to_string())?;
        if read == 0 {
            return Err("connection closed before HTTP headers".to_string());
        }
        request.extend_from_slice(&buffer[..read]);
        if let Some(index) = request.windows(4).position(|window| window == b"\r\n\r\n") {
            break index + 4;
        }
    };
    let headers = std::str::from_utf8(&request[..header_end])
        .map_err(|_| "HTTP headers are not UTF-8".to_string())?;
    let mut lines = headers.split("\r\n");
    let request_line = lines.next().ok_or("missing HTTP request line")?;
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next().ok_or("missing HTTP method")?;
    let path = request_parts.next().ok_or("missing HTTP path")?;
    if path == "/health" {
        if method != "GET" {
            write_response(stream, 405, "Method Not Allowed", "{}")
                .map_err(|error| error.to_string())?;
        } else {
            write_response(stream, 200, "OK", r#"{"status":"ok"}"#)
                .map_err(|error| error.to_string())?;
        }
        return Ok(());
    }
    if path != ENDPOINT_PATH {
        write_response(stream, 404, "Not Found", "{}").map_err(|error| error.to_string())?;
        return Ok(());
    }
    if method != "POST" {
        write_response(stream, 405, "Method Not Allowed", "{}")
            .map_err(|error| error.to_string())?;
        return Ok(());
    }
    let mut content_length = None;
    let mut content_type_is_json = false;
    for line in lines.filter(|line| !line.is_empty()) {
        let Some((name, value)) = line.split_once(':') else {
            return Err("malformed HTTP header".to_string());
        };
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim();
        match name.as_str() {
            "content-length" => {
                content_length = Some(
                    value
                        .parse::<usize>()
                        .map_err(|_| "invalid Content-Length".to_string())?,
                );
            }
            "content-type" => {
                content_type_is_json = value
                    .to_ascii_lowercase()
                    .starts_with("application/json");
            }
            "transfer-encoding" if !value.eq_ignore_ascii_case("identity") => {
                write_response(stream, 400, "Bad Request", "{}")
                    .map_err(|error| error.to_string())?;
                return Ok(());
            }
            "content-encoding" if !value.eq_ignore_ascii_case("identity") => {
                write_response(stream, 415, "Unsupported Media Type", "{}")
                    .map_err(|error| error.to_string())?;
                return Ok(());
            }
            _ => {}
        }
    }
    if !content_type_is_json {
        write_response(stream, 415, "Unsupported Media Type", "{}")
            .map_err(|error| error.to_string())?;
        return Ok(());
    }
    let Some(content_length) = content_length else {
        write_response(stream, 411, "Length Required", "{}")
            .map_err(|error| error.to_string())?;
        return Ok(());
    };
    if content_length > MAX_BODY_BYTES {
        write_response(stream, 413, "Content Too Large", "{}")
            .map_err(|error| error.to_string())?;
        return Ok(());
    }
    while request.len() - header_end < content_length {
        let mut buffer = [0_u8; 8192];
        let remaining = content_length - (request.len() - header_end);
        let read_length = remaining.min(buffer.len());
        let read = stream
            .read(&mut buffer[..read_length])
            .map_err(|error| error.to_string())?;
        if read == 0 {
            return Err("connection closed before HTTP body".to_string());
        }
        request.extend_from_slice(&buffer[..read]);
    }
    let payload = serde_json::from_slice::<Value>(
        &request[header_end..header_end.saturating_add(content_length)],
    )
    .map_err(|_| "invalid OTLP JSON body".to_string())?;
    store.ingest_json(&payload, now_ms())?;
    write_response(stream, 200, "OK", "{}").map_err(|error| error.to_string())?;
    Ok(())
}

fn write_response(
    stream: &mut TcpStream,
    status: u16,
    reason: &str,
    body: &str,
) -> io::Result<()> {
    write!(
        stream,
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )?;
    stream.flush()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ReceiverStatus<'a> {
    state: &'a str,
    endpoint: String,
    started_at_ms: Option<i64>,
    message: Option<String>,
}

fn write_status(path: &Path, status: &ReceiverStatus<'_>) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("could not create receiver status directory: {error}"))?;
    }
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    let data = serde_json::to_vec(status)
        .map_err(|error| format!("could not encode receiver status: {error}"))?;
    fs::write(&temporary, data)
        .map_err(|error| format!("could not write receiver status: {error}"))?;
    set_private_permissions(&temporary)?;
    fs::rename(&temporary, path)
        .map_err(|error| format!("could not publish receiver status: {error}"))
}

fn set_private_permissions(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("could not protect memory telemetry file: {error}"))?;
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

#[cfg(unix)]
fn process_is_alive(pid: u32) -> bool {
    if pid == 0 || pid > i32::MAX as u32 {
        return false;
    }
    let result = unsafe { libc::kill(pid as i32, 0) };
    result == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(windows)]
fn process_is_alive(pid: u32) -> bool {
    use std::ffi::c_void;

    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const ERROR_INVALID_PARAMETER: i32 = 87;
    const STILL_ACTIVE: u32 = 259;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn OpenProcess(
            desired_access: u32,
            inherit_handle: i32,
            process_id: u32,
        ) -> *mut c_void;
        fn GetExitCodeProcess(process: *mut c_void, exit_code: *mut u32) -> i32;
        fn CloseHandle(object: *mut c_void) -> i32;
    }

    if pid == 0 {
        return false;
    }
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if process.is_null() {
        return io::Error::last_os_error().raw_os_error() != Some(ERROR_INVALID_PARAMETER);
    }
    let mut exit_code = 0_u32;
    let queried = unsafe { GetExitCodeProcess(process, &mut exit_code) } != 0;
    unsafe {
        CloseHandle(process);
    }
    !queried || exit_code == STILL_ACTIVE
}

#[cfg(not(any(unix, windows)))]
fn process_is_alive(pid: u32) -> bool {
    pid != 0
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_DATABASE: AtomicU64 = AtomicU64::new(0);
    const EVENT_MS: i64 = 1_800_000_000_000;

    #[test]
    fn current_process_is_alive() {
        assert!(process_is_alive(std::process::id()));
    }

    fn temporary_database(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "tokenbar-memory-{name}-{}-{}.sqlite",
            std::process::id(),
            NEXT_DATABASE.fetch_add(1, Ordering::Relaxed)
        ))
    }

    fn remove_database(path: &Path) {
        for candidate in [
            path.to_path_buf(),
            PathBuf::from(format!("{}-wal", path.display())),
            PathBuf::from(format!("{}-shm", path.display())),
        ] {
            let _ = fs::remove_file(candidate);
        }
    }

    fn payload(
        metric: &str,
        temporality: Value,
        resource_id: &str,
        token_type: &str,
        start: u64,
        time: u64,
        sum: i64,
    ) -> Value {
        json!({
            "resourceMetrics": [{
                "resource": {"attributes": [{
                    "key": "service.instance.id",
                    "value": {"stringValue": resource_id}
                }]},
                "scopeMetrics": [{
                    "scope": {"name": "codex_otel"},
                    "metrics": [{
                        "name": metric,
                        "histogram": {
                            "aggregationTemporality": temporality,
                            "dataPoints": [{
                                "attributes": [{
                                    "key": "token_type",
                                    "value": {"stringValue": token_type}
                                }],
                                "startTimeUnixNano": start.to_string(),
                                "timeUnixNano": time.to_string(),
                                "count": "999",
                                "sum": sum
                            }]
                        }
                    }]
                }]
            }]
        })
    }

    fn snapshot(path: &Path) -> MemoryUsageSnapshot {
        let date = chrono::DateTime::from_timestamp_millis(EVENT_MS)
            .unwrap()
            .with_timezone(&Local)
            .date_naive();
        load_usage_snapshot(path, date, EVENT_MS + 10_000, 30)
            .unwrap()
            .unwrap()
    }

    #[test]
    fn cumulative_exports_only_add_the_watermark_delta() {
        let path = temporary_database("cumulative");
        let mut store = MemoryStore::open(&path, EVENT_MS - 1_000).unwrap();
        let first = payload(
            PHASE_ONE_METRIC,
            json!("AGGREGATION_TEMPORALITY_CUMULATIVE"),
            "process-a",
            "total",
            10,
            (EVENT_MS as u64) * 1_000_000,
            100,
        );
        let later = payload(
            PHASE_ONE_METRIC,
            json!(2),
            "process-a",
            "total",
            10,
            (EVENT_MS as u64 + 1_000) * 1_000_000,
            150,
        );

        assert_eq!(store.ingest_json(&first, EVENT_MS).unwrap().added_tokens, 100);
        assert_eq!(store.ingest_json(&first, EVENT_MS).unwrap().added_tokens, 0);
        assert_eq!(store.ingest_json(&later, EVENT_MS + 1_000).unwrap().added_tokens, 50);
        drop(store);

        let snapshot = snapshot(&path);
        assert_eq!(snapshot.range_totals.phase1.total, 150);
        assert_eq!(snapshot.observation_count, 2);
        assert_eq!(snapshot.last_received_at_ms, Some(EVENT_MS + 1_000));
        assert_eq!(snapshot.last_memory_received_at_ms, Some(EVENT_MS + 1_000));
        remove_database(&path);
    }

    #[test]
    fn unrelated_otlp_metrics_mark_the_connection_without_marking_memory() {
        let path = temporary_database("connection-only");
        let mut store = MemoryStore::open(&path, EVENT_MS - 1_000).unwrap();
        let unrelated = payload(
            "codex.tool.call",
            json!(1),
            "process-a",
            "total",
            10,
            (EVENT_MS as u64) * 1_000_000,
            42,
        );

        let stats = store.ingest_json(&unrelated, EVENT_MS).unwrap();
        assert_eq!(stats.parsed, 0);
        assert_eq!(stats.inserted, 0);
        drop(store);

        let snapshot = snapshot(&path);
        assert_eq!(snapshot.last_received_at_ms, Some(EVENT_MS));
        assert_eq!(snapshot.last_memory_received_at_ms, None);
        assert_eq!(snapshot.observation_count, 0);
        assert_eq!(snapshot.range_totals.phase1.total, 0);
        assert_eq!(snapshot.range_totals.phase2.total, 0);
        remove_database(&path);
    }

    #[test]
    fn delta_exports_add_each_unique_interval_and_ignore_replays() {
        let path = temporary_database("delta");
        let mut store = MemoryStore::open(&path, EVENT_MS - 1_000).unwrap();
        let first = payload(
            PHASE_TWO_METRIC,
            json!("AGGREGATION_TEMPORALITY_DELTA"),
            "process-a",
            "total",
            10,
            (EVENT_MS as u64) * 1_000_000,
            20,
        );
        let second = payload(
            PHASE_TWO_METRIC,
            json!(1),
            "process-a",
            "total",
            20,
            (EVENT_MS as u64 + 1_000) * 1_000_000,
            30,
        );

        store.ingest_json(&first, EVENT_MS).unwrap();
        store.ingest_json(&first, EVENT_MS).unwrap();
        store.ingest_json(&second, EVENT_MS + 1_000).unwrap();
        drop(store);

        assert_eq!(snapshot(&path).range_totals.phase2.total, 50);
        remove_database(&path);
    }

    #[test]
    fn persisted_watermarks_survive_receiver_restarts() {
        let path = temporary_database("restart");
        let first = payload(
            PHASE_ONE_METRIC,
            json!(2),
            "process-a",
            "total",
            10,
            (EVENT_MS as u64) * 1_000_000,
            100,
        );
        let later = payload(
            PHASE_ONE_METRIC,
            json!(2),
            "process-a",
            "total",
            10,
            (EVENT_MS as u64 + 1_000) * 1_000_000,
            130,
        );
        MemoryStore::open(&path, EVENT_MS - 1_000)
            .unwrap()
            .ingest_json(&first, EVENT_MS)
            .unwrap();
        MemoryStore::open(&path, EVENT_MS + 500)
            .unwrap()
            .ingest_json(&later, EVENT_MS + 1_000)
            .unwrap();

        assert_eq!(snapshot(&path).range_totals.phase1.total, 130);
        remove_database(&path);
    }

    #[test]
    fn new_series_and_processes_are_counted_independently() {
        let path = temporary_database("series");
        let mut store = MemoryStore::open(&path, EVENT_MS - 1_000).unwrap();
        for (resource, start, sum) in [("process-a", 10, 40), ("process-b", 20, 60)] {
            store
                .ingest_json(
                    &payload(
                        PHASE_ONE_METRIC,
                        json!(2),
                        resource,
                        "total",
                        start,
                        (EVENT_MS as u64) * 1_000_000,
                        sum,
                    ),
                    EVENT_MS,
                )
                .unwrap();
        }
        drop(store);

        assert_eq!(snapshot(&path).range_totals.phase1.total, 100);
        remove_database(&path);
    }

    #[test]
    fn out_of_order_and_duplicate_cumulative_payloads_do_not_inflate_usage() {
        let path = temporary_database("out-of-order");
        let mut store = MemoryStore::open(&path, EVENT_MS - 1_000).unwrap();
        let newer = payload(
            PHASE_ONE_METRIC,
            json!(2),
            "process-a",
            "total",
            10,
            (EVENT_MS as u64 + 1_000) * 1_000_000,
            150,
        );
        let older = payload(
            PHASE_ONE_METRIC,
            json!(2),
            "process-a",
            "total",
            10,
            (EVENT_MS as u64) * 1_000_000,
            100,
        );

        store.ingest_json(&newer, EVENT_MS + 1_000).unwrap();
        store.ingest_json(&older, EVENT_MS + 1_500).unwrap();
        store.ingest_json(&newer, EVENT_MS + 2_000).unwrap();
        drop(store);

        assert_eq!(snapshot(&path).range_totals.phase1.total, 150);
        remove_database(&path);
    }

    #[test]
    fn histogram_sum_is_used_instead_of_observation_count() {
        let path = temporary_database("sum");
        let mut store = MemoryStore::open(&path, EVENT_MS - 1_000).unwrap();
        store
            .ingest_json(
                &payload(
                    PHASE_ONE_METRIC,
                    json!(1),
                    "process-a",
                    "input",
                    10,
                    (EVENT_MS as u64) * 1_000_000,
                    42,
                ),
                EVENT_MS,
            )
            .unwrap();
        drop(store);

        assert_eq!(snapshot(&path).range_totals.phase1.input, 42);
        remove_database(&path);
    }

    #[test]
    fn arbitrary_resource_and_point_attributes_are_never_stored_verbatim() {
        let path = temporary_database("private-attributes");
        let mut value = payload(
            PHASE_ONE_METRIC,
            json!(1),
            "process-a",
            "input",
            10,
            (EVENT_MS as u64) * 1_000_000,
            42,
        );
        value
            .pointer_mut("/resourceMetrics/0/resource/attributes")
            .and_then(Value::as_array_mut)
            .unwrap()
            .push(json!({
                "key": "process.command_args",
                "value": {"arrayValue": {"values": [{"stringValue": "private prompt text"}]}}
            }));
        value
            .pointer_mut("/resourceMetrics/0/scopeMetrics/0/metrics/0/histogram/dataPoints/0/attributes")
            .and_then(Value::as_array_mut)
            .unwrap()
            .push(json!({
                "key": "user.prompt",
                "value": {"stringValue": "private prompt text"}
            }));
        let mut store = MemoryStore::open(&path, EVENT_MS - 1_000).unwrap();
        store.ingest_json(&value, EVENT_MS).unwrap();

        let stored: String = store
            .connection
            .query_row(
                "SELECT resource_identity || resource_fingerprint || attribute_fingerprint
                 FROM memory_observations LIMIT 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(!stored.contains("private prompt text"));
        assert!(!stored.contains("process.command_args"));
        assert!(!stored.contains("user.prompt"));
        drop(store);
        remove_database(&path);
    }

    #[test]
    fn http_receiver_restricts_routes_and_accepts_otlp_json() {
        let path = temporary_database("http");
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let address = listener.local_addr().unwrap();
        let body = serde_json::to_vec(&payload(
            PHASE_TWO_METRIC,
            json!(1),
            "process-a",
            "total",
            10,
            (EVENT_MS as u64) * 1_000_000,
            75,
        ))
        .unwrap();
        let thread_path = path.clone();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut store = MemoryStore::open(&thread_path, EVENT_MS - 1_000).unwrap();
            handle_connection(&mut stream, &mut store).unwrap();
        });
        let mut client = TcpStream::connect(address).unwrap();
        write!(
            client,
            "POST {ENDPOINT_PATH} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
            body.len()
        )
        .unwrap();
        client.write_all(&body).unwrap();
        let mut response = String::new();
        client.read_to_string(&mut response).unwrap();
        server.join().unwrap();

        assert!(response.starts_with("HTTP/1.1 200 OK"));
        assert_eq!(snapshot(&path).range_totals.phase2.total, 75);
        remove_database(&path);
    }

    #[test]
    fn port_conflicts_fail_safely_and_publish_status() {
        let path = temporary_database("port-conflict");
        let status_path = path.with_extension("status.json");
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();

        let error = run_receiver(MemoryReceiverConfig {
            database_path: path.clone(),
            status_path: Some(status_path.clone()),
            port,
            parent_pid: None,
        })
        .unwrap_err();

        assert!(error.contains("could not listen on 127.0.0.1"));
        let status: Value = serde_json::from_slice(&fs::read(&status_path).unwrap()).unwrap();
        assert_eq!(status["state"], "error");
        assert!(!path.exists());
        let _ = fs::remove_file(status_path);
    }
}
