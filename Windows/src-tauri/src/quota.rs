use crate::settings::Settings;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::BTreeMap,
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub used_percent: f64,
    pub window_minutes: Option<i64>,
    pub resets_at_ms: Option<i64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaGroup {
    pub label: String,
    pub session: Option<Window>,
    pub weekly: Option<Window>,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Quota {
    pub session: Option<Window>,
    pub weekly: Option<Window>,
    pub updated_at_ms: i64,
    pub error: Option<String>,
    #[serde(default)]
    pub available_reset_credits: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secondary_group: Option<QuotaGroup>,
}
pub type Quotas = BTreeMap<String, Quota>;

fn number(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str()?.parse().ok())
        .filter(|v| v.is_finite())
}
fn date(value: &Value) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(value.as_str()?)
        .ok()
        .map(|v| v.timestamp_millis())
}
fn codex_window(value: &Value) -> Option<Window> {
    Some(Window {
        used_percent: number(
            value
                .get("usedPercent")
                .or_else(|| value.get("used_percent"))?,
        )
        .filter(|v| (0.0..=100.0).contains(v))?,
        window_minutes: value
            .get("windowDurationMins")
            .or_else(|| value.get("windowDurationMinutes"))
            .or_else(|| value.get("window_minutes"))
            .and_then(number)
            .map(|v| v as i64),
        resets_at_ms: value
            .get("resetsAt")
            .or_else(|| value.get("resets_at"))
            .and_then(number)
            .map(|v| (v * 1000.0) as i64),
    })
}
fn parse_codex(limits: &Value, sampled_at_ms: i64) -> Option<Quota> {
    if limits["limit_id"].as_str().is_some_and(|id| id != "codex") {
        return None;
    }
    let mut quota = Quota {
        updated_at_ms: sampled_at_ms,
        ..Default::default()
    };
    for (key, fallback_weekly) in [("primary", false), ("secondary", true)] {
        if let Some(window) = limits.get(key).and_then(codex_window) {
            let weekly = match window.window_minutes {
                Some(10080) => true,
                Some(300) => false,
                None => fallback_weekly,
                _ => continue,
            };
            if weekly {
                quota.weekly = Some(window);
            } else {
                quota.session = Some(window);
            }
        }
    }
    if quota.session.is_none() && quota.weekly.is_none() {
        return None;
    }
    Some(quota)
}

fn codex_files(root: &Path, files: &mut Vec<(PathBuf, SystemTime)>) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_dir() {
            codex_files(&entry.path(), files);
        } else if kind.is_file() && entry.path().extension().is_some_and(|e| e == "jsonl") {
            if let Ok(meta) = entry.metadata() {
                files.push((entry.path(), meta.modified().unwrap_or(UNIX_EPOCH)));
            }
        }
    }
}

fn codex_record(line: &[u8], now_ms: i64) -> Option<Quota> {
    let entry: Value = serde_json::from_slice(line).ok()?;
    if entry["type"] != "event_msg" || entry["payload"]["type"] != "token_count" {
        return None;
    }
    let sampled_at = date(&entry["timestamp"])?;
    if sampled_at <= 0 || sampled_at > now_ms + 60_000 {
        return None;
    }
    parse_codex(&entry["payload"]["rate_limits"], sampled_at)
}

fn codex_file_quota(path: &Path, now_ms: i64) -> Option<Quota> {
    let mut file = File::open(path).ok()?;
    let mut end = file.metadata().ok()?.len();
    let mut carry = Vec::new();
    // Walk backwards in bounded chunks, keeping a line that straddles two chunks.
    while end > 0 {
        let start = end.saturating_sub(256 * 1024);
        file.seek(SeekFrom::Start(start)).ok()?;
        let mut bytes = vec![0; (end - start) as usize];
        file.read_exact(&mut bytes).ok()?;
        bytes.extend_from_slice(&carry);
        let first_complete = if start == 0 {
            0
        } else if let Some(newline) = bytes.iter().position(|b| *b == b'\n') {
            newline + 1
        } else {
            carry = bytes;
            end = start;
            continue;
        };
        for line in bytes[first_complete..].split(|b| *b == b'\n').rev() {
            if let Some(quota) = codex_record(line, now_ms) {
                return Some(quota);
            }
        }
        carry = bytes[..first_complete.saturating_sub(1)].to_vec();
        end = start;
    }
    None
}

async fn codex(settings: &Settings) -> Result<Quota, String> {
    let root = settings.root("codex");
    tokio::task::spawn_blocking(move || {
        let now_ms = chrono::Utc::now().timestamp_millis();
        let mut files = Vec::new();
        for folder in ["sessions", "archived_sessions"] {
            codex_files(&root.join(folder), &mut files);
        }
        files.sort_by(|a, b| b.1.cmp(&a.1));
        let mut latest: Option<Quota> = None;
        for (path, modified) in files {
            let modified_ms = modified
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis();
            if latest
                .as_ref()
                .is_some_and(|q| modified_ms < q.updated_at_ms as u128)
            {
                break;
            }
            if let Some(quota) = codex_file_quota(&path, now_ms) {
                if latest
                    .as_ref()
                    .is_none_or(|old| quota.updated_at_ms > old.updated_at_ms)
                {
                    latest = Some(quota);
                }
            }
        }
        let mut quota = latest.ok_or("Codex 本地日志中没有额度记录；使用 Codex 后会更新。")?;
        for window in [&mut quota.session, &mut quota.weekly] {
            if window
                .as_ref()
                .is_some_and(|w| w.resets_at_ms.is_some_and(|t| t <= now_ms))
            {
                *window = None;
            }
        }
        if quota.session.is_none() && quota.weekly.is_none() {
            return Err("Codex 本地额度窗口已过期；等待 Codex 写入新记录。".into());
        }
        Ok(quota)
    })
    .await
    .map_err(|_| "无法读取 Codex 本地额度。".to_string())?
}

async fn claude(cache_dir: &Path) -> Result<Quota, String> {
    let now_ms = chrono::Utc::now().timestamp_millis();
    let fresh =
        |sampled_at: i64| sampled_at > 0 && (-60_000..30 * 60_000).contains(&(now_ms - sampled_at));
    let appdata = std::env::var_os("APPDATA")
        .filter(|p| !p.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::settings::user_home().join("AppData/Roaming"));
    let desktop = tokio::fs::read(appdata.join("Claude/plan-usage-history.json"))
        .await
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|history| {
            let sample = history["samples"]
                .as_array()?
                .iter()
                .filter_map(|sample| Some((sample["t"].as_i64()?, sample)))
                .filter(|(timestamp, _)| fresh(*timestamp))
                .max_by_key(|(timestamp, _)| *timestamp)?
                .1;
            let mut payload = serde_json::json!({});
            for (source, target) in [("fh", "five_hour"), ("sd", "seven_day")] {
                if let Some(usage) = number(&sample["u"][source]) {
                    payload[target] = serde_json::json!({"utilization": usage});
                }
            }
            parse_claude(&payload, sample["t"].as_i64()?).ok()
        });
    let status_line = tokio::fs::read(cache_dir.join("claude-rate-limits.json"))
        .await
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|payload| {
            let timestamp = number(&payload["_cached_at_ms"])?;
            if timestamp <= 0.0 || timestamp > (now_ms + 60_000) as f64 {
                return None;
            }
            parse_claude(&payload, timestamp as i64).ok()
        });
    let Some(mut quota) = desktop else {
        return status_line
            .filter(|q| fresh(q.updated_at_ms))
            .ok_or_else(|| "没有近期的 Claude 本地额度记录；等待 Claude 写入用量缓存。".into());
    };
    if let Some(observed) = status_line {
        let include_observed = fresh(observed.updated_at_ms);
        for (current, observed) in [
            (&mut quota.session, observed.session),
            (&mut quota.weekly, observed.weekly),
        ] {
            if let Some(window) = current {
                if let Some(reset) = observed.as_ref().and_then(|w| w.resets_at_ms) {
                    if reset > now_ms
                        && window
                            .window_minutes
                            .is_some_and(|minutes| reset - now_ms <= minutes * 60_000)
                    {
                        window.resets_at_ms = Some(reset);
                    }
                }
            } else if include_observed {
                *current = observed;
            }
        }
    }
    Ok(quota)
}

fn parse_claude(payload: &Value, sampled_at_ms: i64) -> Result<Quota, String> {
    let window = |key: &str, minutes| {
        let value = payload.get(key)?;
        Some(Window {
            used_percent: number(&value["utilization"])?.clamp(0.0, 100.0),
            window_minutes: Some(minutes),
            resets_at_ms: date(&value["resets_at"]),
        })
    };
    let quota = Quota {
        session: window("five_hour", 300),
        weekly: window("seven_day", 10080),
        updated_at_ms: sampled_at_ms,
        error: None,
        available_reset_credits: None,
        secondary_group: None,
    };
    if quota.session.is_none() && quota.weekly.is_none() {
        return Err("Claude 未返回额度窗口。".into());
    }
    Ok(quota)
}

async fn grok(settings: &Settings) -> Result<Quota, String> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let mut file = tokio::fs::File::open(settings.root("grok").join("logs/unified.jsonl"))
        .await
        .map_err(|_| "未找到 Grok 用量日志，请在 Grok Build 中运行 /usage。")?;
    // Read the tail only; the unified log can be large.
    let length = file
        .metadata()
        .await
        .map_err(|_| "无法读取 Grok 日志。")?
        .len();
    file.seek(std::io::SeekFrom::Start(
        length.saturating_sub(4 * 1024 * 1024),
    ))
    .await
    .map_err(|_| "无法读取 Grok 日志。")?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .await
        .map_err(|_| "无法读取 Grok 日志。")?;
    let record = bytes
        .split(|b| *b == b'\n')
        .rev()
        .filter_map(|line| serde_json::from_slice::<Value>(line).ok())
        .find(|v| v["msg"] == "billing: fetched credits config")
        .ok_or("Grok 日志中没有近期额度，请运行 /usage。")?;
    parse_grok(&record)
}
fn parse_grok(record: &Value) -> Result<Quota, String> {
    let config = &record["ctx"]["config"];
    let used = number(&config["creditUsagePercent"])
        .or_else(|| {
            let limit = number(&config["monthlyLimit"]["val"])?;
            if limit <= 0.0 {
                return None;
            }
            Some(number(&config["used"]["val"])? / limit * 100.0)
        })
        .ok_or("Grok 额度数据无效。")?;
    let end = date(&config["currentPeriod"]["end"]).or_else(|| date(&config["billingPeriodEnd"]));
    let minutes = end
        .zip(date(&config["currentPeriod"]["start"]))
        .map(|(end, start)| (end - start) / 60000)
        .filter(|v| *v > 0);
    Ok(Quota {
        session: None,
        weekly: Some(Window {
            used_percent: used.clamp(0.0, 100.0),
            window_minutes: minutes,
            resets_at_ms: end,
        }),
        updated_at_ms: date(&record["ts"]).ok_or("Grok 本地额度记录缺少采样时间。")?,
        error: None,
        available_reset_credits: None,
        secondary_group: None,
    })
}

pub async fn fetch(settings: &Settings, previous: &Quotas, cache_dir: &Path) -> Quotas {
    let (codex, claude, grok, antigravity) = tokio::join!(
        codex(settings),
        async {
            if settings.show_claude {
                claude(cache_dir).await
            } else {
                Err("已隐藏".into())
            }
        },
        async {
            if settings.show_grok {
                grok(settings).await
            } else {
                Err("已隐藏".into())
            }
        },
        async {
            if settings.show_antigravity {
                Err("AGY 仅显示上次保存的额度；已停用可能触发后台请求的查询接口。".into())
            } else {
                Err("已隐藏".into())
            }
        }
    );
    [
        ("codex", codex),
        ("claude", claude),
        ("grok", grok),
        ("antigravity", antigravity),
    ]
    .into_iter()
    .map(|(name, result)| {
        let value = result.unwrap_or_else(|error| {
            let mut old = previous.get(name).cloned().unwrap_or_default();
            old.error = Some(error);
            old
        });
        (name.to_string(), value)
    })
    .collect()
}
