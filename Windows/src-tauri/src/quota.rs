use crate::{process, settings::Settings};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::BTreeMap, path::PathBuf, process::Stdio, time::Duration};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub used_percent: f64,
    pub window_minutes: Option<i64>,
    pub resets_at_ms: Option<i64>,
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
        )?
        .clamp(0.0, 100.0),
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
pub fn parse_codex(result: &Value) -> Result<Quota, String> {
    let limits = result
        .get("rateLimitsByLimitId")
        .and_then(|v| v.get("codex"))
        .or_else(|| result.get("rateLimits"))
        .ok_or("Codex 未返回额度。")?;
    let mut quota = Quota {
        updated_at_ms: chrono::Utc::now().timestamp_millis(),
        available_reset_credits: result["rateLimitResetCredits"]["availableCount"]
            .as_i64()
            .filter(|v| *v >= 0),
        ..Default::default()
    };
    for (key, fallback_weekly) in [("primary", false), ("secondary", true)] {
        if let Some(window) = limits.get(key).and_then(codex_window) {
            let weekly = match window.window_minutes {
                Some(10080) => true,
                Some(300) => false,
                _ => fallback_weekly,
            };
            if weekly {
                quota.weekly = Some(window);
            } else {
                quota.session = Some(window);
            }
        }
    }
    if quota.session.is_none() && quota.weekly.is_none() {
        return Err("当前 Codex 账户未提供额度窗口。".into());
    }
    Ok(quota)
}

pub fn codex_binary(settings: &Settings) -> Option<PathBuf> {
    if !settings.codex_binary.is_empty() {
        return Some(PathBuf::from(&settings.codex_binary));
    }
    if let Some(path) = std::env::var_os("CODEX_CLI_PATH")
        .map(PathBuf::from)
        .filter(|p| p.is_file())
    {
        return Some(path);
    }
    let mut paths: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    if let Some(appdata) = std::env::var_os("APPDATA") {
        paths.push(PathBuf::from(appdata).join("npm"));
    }
    for parent in paths {
        for path in [
            parent.join("codex.exe"),
            parent.join("node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/codex/codex.exe"),
            parent.join("node_modules/@openai/codex/vendor/x86_64-pc-windows-msvc/codex/codex.exe"),
        ] { if path.is_file() { return Some(path); } }
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        let root = PathBuf::from(local).join("OpenAI/Codex/bin");
        let mut candidates: Vec<_> = std::fs::read_dir(root)
            .ok()?
            .flatten()
            .map(|entry| entry.path().join("codex.exe"))
            .filter(|p| p.is_file())
            .collect();
        candidates.sort_by_key(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok());
        return candidates.pop();
    }
    None
}

async fn codex(settings: &Settings) -> Result<Quota, String> {
    let path = codex_binary(settings).ok_or("未找到 Codex；可在设置中指定 codex.exe。")?;
    let mut command = process::command(&path, settings);
    command
        .args(["-s", "read-only", "app-server"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped());
    let mut child = command.spawn().map_err(|_| "Codex app-server 启动失败。")?;
    let mut stdin = child.stdin.take().ok_or("Codex 输入不可用。")?;
    let stdout = child.stdout.take().ok_or("Codex 输出不可用。")?;
    let result = tokio::time::timeout(Duration::from_secs(20), async {
        let mut reader = BufReader::new(stdout);
        stdin.write_all(b"{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"tokenbar\",\"version\":\"0.1.0\"}}}\n")
            .await.map_err(|_| "Codex 初始化失败。")?;
        let mut initialized = false;
        loop {
            let mut line = String::new();
            // app-server is a local trusted executable, but bound its protocol output.
            let read = (&mut reader).take(1024 * 1024).read_line(&mut line).await.map_err(|_| "Codex 连接中断。")?;
            if read == 0 || line.len() >= 1024 * 1024 { return Err("Codex 返回了无效的响应。".into()); }
            let Ok(value) = serde_json::from_str::<Value>(&line) else { continue; };
            let id = value["id"].as_i64();
            if (id == Some(1) || id == Some(2)) && value.get("error").is_some() {
                return Err("Codex 额度查询失败，请确认已登录并稍后重试。".into());
            }
            if id == Some(1) && !initialized {
                initialized = true;
                stdin.write_all(b"{\"method\":\"initialized\"}\n{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":null}\n")
                    .await.map_err(|_| "Codex 请求发送失败。")?;
            } else if id == Some(2) { return parse_codex(&value["result"]); }
        }
    }).await.map_err(|_| "Codex 额度查询超时。".to_string()).and_then(|v| v);
    drop(stdin);
    let _ = child.kill().await;
    let _ = child.wait().await;
    result
}

async fn claude(settings: &Settings) -> Result<Quota, String> {
    let bytes = tokio::fs::read(settings.root("claude").join(".credentials.json"))
        .await
        .map_err(|_| "未找到 Claude Code 登录信息。请先运行 claude 登录。")?;
    let credentials: Value =
        serde_json::from_slice(&bytes).map_err(|_| "Claude Code 登录信息无效。")?;
    let token = credentials["claudeAiOauth"]["accessToken"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or("Claude Code 未提供 OAuth 凭据。")?;
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "无法初始化额度请求。")?
        .get("https://api.anthropic.com/api/oauth/usage")
        .bearer_auth(token)
        .header("anthropic-beta", "oauth-2025-04-20")
        .send()
        .await
        .map_err(|_| "Claude 额度请求未完成，请检查网络。")?;
    if !response.status().is_success() {
        return Err(format!(
            "Claude 额度查询失败（HTTP {}）。",
            response.status().as_u16()
        ));
    }
    let payload: Value = response.json().await.map_err(|_| "Claude 额度响应无效。")?;
    parse_claude(&payload)
}
fn parse_claude(payload: &Value) -> Result<Quota, String> {
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
        updated_at_ms: chrono::Utc::now().timestamp_millis(),
        error: None,
        available_reset_credits: None,
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
        updated_at_ms: date(&record["ts"]).unwrap_or(0),
        error: None,
        available_reset_credits: None,
    })
}

pub async fn fetch(settings: &Settings, previous: &Quotas) -> Quotas {
    let (codex, claude, grok) = tokio::join!(
        codex(settings),
        async {
            if settings.show_claude {
                claude(settings).await
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
        }
    );
    [("codex", codex), ("claude", claude), ("grok", grok)]
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn codex_uses_window_duration_and_does_not_mix_limit_buckets() {
        let value = json!({"rateLimitsByLimitId": {"codex": {
            "primary": {"usedPercent": 20, "windowDurationMins": 10080, "resetsAt": 1000},
            "secondary": {"usedPercent": 30, "windowDurationMins": 300}
        }, "review": {"primary": {"usedPercent": 99}}}});
        let quota = parse_codex(&value).unwrap();
        assert_eq!(quota.weekly.unwrap().resets_at_ms, Some(1000000));
        assert_eq!(quota.session.unwrap().used_percent, 30.0);
    }
    #[test]
    fn missing_quota_is_not_zero_usage() {
        assert!(parse_codex(&json!({"rateLimits": {}})).is_err());
        assert!(parse_claude(&json!({})).is_err());
        assert!(
            parse_grok(&json!({"ctx":{"config":{"monthlyLimit":{"val":0},"used":{"val":3}}}}))
                .is_err()
        );
    }
    #[test]
    fn optional_claude_windows_remain_absent() {
        let quota = parse_claude(&json!({"seven_day":{"utilization": 45}})).unwrap();
        assert!(quota.session.is_none());
        assert_eq!(quota.weekly.unwrap().used_percent, 45.0);
    }
}
