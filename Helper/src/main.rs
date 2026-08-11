use std::env;
use std::error::Error;
use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Write};
use std::path::PathBuf;

use chrono::{Days, Utc};
use tokenbar_helper::claude::{
    extract_request_detail as extract_claude_request_detail, parse_local_claude_messages,
    LocalParseOptions as ClaudeParseOptions,
};
use tokenbar_helper::codex::{parse_local_codex_messages, LocalParseOptions};
use tokenbar_helper::grok::{
    extract_request_detail as extract_grok_request_detail, load_grok_session_titles,
    parse_local_grok_messages, LocalParseOptions as GrokParseOptions,
};
use serde::Deserialize;
use tokenbar_helper::memory::{load_usage_snapshot, run_receiver, MemoryReceiverConfig, DEFAULT_PORT};
use tokenbar_helper::pricing::{AnthropicPricing, CodexPricing, FastPricingBasis};
use tokenbar_helper::{
    build_snapshot_with_platform_resets, extract_request_detail as extract_codex_request_detail,
    load_claude_session_titles, load_codex_session_titles, normalize_codex_reasoning_usage,
    StatisticsTimeZone,
};

const DEFAULT_DAYS: usize = 30;
const USAGE: &str = "usage: tokenbar-helper [--days COUNT] [--home-dir PATH] [--statistics-timezone utc|local] [--weekly-reset-ms MS] [--claude-weekly-reset-ms MS] [--grok-weekly-reset-ms MS] [--anthropic-pricing-markdown PATH] [--memory-database PATH]\n       tokenbar-helper request-detail [--platform codex|claude|grok] --session-path PATH --start-ms MS --end-ms MS\n       tokenbar-helper memory-receiver --database PATH [--status-file PATH] [--port PORT] [--parent-pid PID]";

#[derive(Debug, PartialEq, Eq)]
struct SnapshotConfig {
    days: usize,
    home_dir: Option<PathBuf>,
    statistics_time_zone: StatisticsTimeZone,
    weekly_reset_ms: Option<i64>,
    claude_weekly_reset_ms: Option<i64>,
    grok_weekly_reset_ms: Option<i64>,
    anthropic_pricing_markdown: Option<PathBuf>,
    memory_database: Option<PathBuf>,
}

impl Default for SnapshotConfig {
    fn default() -> Self {
        Self {
            days: DEFAULT_DAYS,
            home_dir: None,
            statistics_time_zone: StatisticsTimeZone::default(),
            weekly_reset_ms: None,
            claude_weekly_reset_ms: None,
            grok_weekly_reset_ms: None,
            anthropic_pricing_markdown: None,
            memory_database: None,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
struct RequestDetailConfig {
    platform: String,
    session_path: PathBuf,
    start_ms: i64,
    end_ms: i64,
}

#[derive(Debug, PartialEq, Eq)]
enum Command {
    Snapshot(SnapshotConfig),
    RequestDetail(RequestDetailConfig),
    MemoryReceiver(MemoryReceiverConfig),
}

#[derive(Debug, Deserialize)]
struct CodexAuthConfig {
    auth_mode: Option<String>,
}

fn main() -> Result<(), Box<dyn Error>> {
    match parse_args(env::args_os().skip(1))? {
        Command::Snapshot(config) => run_snapshot(config),
        Command::RequestDetail(config) => {
            let detail = match config.platform.as_str() {
                "codex" => {
                    extract_codex_request_detail(
                        &config.session_path,
                        config.start_ms,
                        config.end_ms,
                    )
                }
                "claude" => {
                    extract_claude_request_detail(
                        &config.session_path,
                        config.start_ms,
                        config.end_ms,
                    )
                }
                "grok" => extract_grok_request_detail(
                    &config.session_path,
                    config.start_ms,
                    config.end_ms,
                ),
                platform => Err(format!("unsupported request-detail platform: {platform}")),
            }
            .map_err(io::Error::other)?;
            write_json(&detail)
        }
        Command::MemoryReceiver(config) => run_receiver(config).map_err(io::Error::other).map_err(Into::into),
    }
}

fn run_snapshot(config: SnapshotConfig) -> Result<(), Box<dyn Error>> {
    let generated_at_ms = Utc::now().timestamp_millis();
    let today = config
        .statistics_time_zone
        .date_at_ms(generated_at_ms)
        .ok_or("the current time is outside the supported range")?;
    let first_day = today
        .checked_sub_days(Days::new((config.days - 1) as u64))
        .ok_or("day range is too large")?;
    let scan_first_day = [
        config.weekly_reset_ms,
        config.claude_weekly_reset_ms,
        config.grok_weekly_reset_ms,
    ]
        .into_iter()
        .flatten()
        .filter_map(|timestamp| config.statistics_time_zone.date_at_ms(timestamp))
        .fold(first_day, |earliest, reset_day| earliest.min(reset_day));
    // Parsers perform an inexpensive date prefilter before returning timestamped
    // rows. Scan one boundary day on either side, then recompute every row's date
    // below so UTC and local mode stay correct even on Windows where TZ is ignored.
    let parse_first_day = scan_first_day
        .checked_sub_days(Days::new(1))
        .unwrap_or(scan_first_day);
    let parse_last_day = today.checked_add_days(Days::new(1)).unwrap_or(today);
    let session_index_path = codex_session_index_path(&config);
    let home_dir = config
        .home_dir
        .as_ref()
        .map(|path| {
            path.to_str()
                .map(str::to_string)
                .ok_or("home directory is not valid UTF-8")
        })
        .transpose()?;
    let use_env_roots = home_dir.is_none();

    let pricing = CodexPricing::with_fast_pricing(codex_fast_pricing_basis(&config));
    let mut codex_messages = parse_local_codex_messages(
        LocalParseOptions {
            home_dir: home_dir.clone(),
            use_env_roots,
            since: Some(parse_first_day.format("%Y-%m-%d").to_string()),
            until: Some(parse_last_day.format("%Y-%m-%d").to_string()),
        },
        &pricing,
    )
    .map_err(io::Error::other)?;
    normalize_codex_reasoning_usage(&mut codex_messages, |message| {
        pricing.calculate_token_costs_with_service_tier(
            &message.model_id,
            Some(&message.provider_id),
            &message.tokens,
            message.service_tier,
        )
    });
    let mut session_titles = session_index_path
        .as_deref()
        .map(|path| load_codex_session_titles(&codex_messages, path))
        .unwrap_or_default();
    let anthropic_pricing = config
        .anthropic_pricing_markdown
        .as_deref()
        .and_then(|path| AnthropicPricing::from_official_markdown_file(path, today).ok())
        .unwrap_or_else(|| AnthropicPricing::bundled_for_date(today));
    let claude_messages = parse_local_claude_messages(
        ClaudeParseOptions {
            home_dir: home_dir.clone(),
            use_env_roots,
            since: Some(parse_first_day.format("%Y-%m-%d").to_string()),
            until: Some(parse_last_day.format("%Y-%m-%d").to_string()),
        },
        &anthropic_pricing,
    )
    .map_err(io::Error::other)?;
    session_titles.extend(load_claude_session_titles(&claude_messages));
    let grok_messages = parse_local_grok_messages(GrokParseOptions {
        home_dir,
        use_env_roots,
        since: Some(parse_first_day.format("%Y-%m-%d").to_string()),
        until: Some(parse_last_day.format("%Y-%m-%d").to_string()),
    })
    .map_err(io::Error::other)?;
    session_titles.extend(load_grok_session_titles(&grok_messages));
    let mut messages = codex_messages;
    messages.extend(claude_messages);
    messages.extend(grok_messages);
    config
        .statistics_time_zone
        .normalize_message_dates(&mut messages);

    let timezone = config.statistics_time_zone.snapshot_name();
    let mut weekly_resets = std::collections::HashMap::new();
    if let Some(timestamp) = config.weekly_reset_ms {
        weekly_resets.insert("codex".to_string(), timestamp);
    }
    if let Some(timestamp) = config.claude_weekly_reset_ms {
        weekly_resets.insert("claude".to_string(), timestamp);
    }
    if let Some(timestamp) = config.grok_weekly_reset_ms {
        weekly_resets.insert("grok".to_string(), timestamp);
    }
    let mut snapshot = build_snapshot_with_platform_resets(
        messages,
        today,
        generated_at_ms,
        timezone,
        config.days,
        &session_titles,
        &weekly_resets,
    )
    .map_err(io::Error::other)?;
    if let Some(database_path) = config.memory_database.as_deref() {
        snapshot.memory_usage = load_usage_snapshot(
            database_path,
            today,
            generated_at_ms,
            config.days,
        )
        .map_err(io::Error::other)?;
    }

    write_json(&snapshot)
}

fn codex_session_index_path(config: &SnapshotConfig) -> Option<PathBuf> {
    codex_home_path(config).map(|path| path.join("session_index.jsonl"))
}

fn codex_home_path(config: &SnapshotConfig) -> Option<PathBuf> {
    if let Some(home_dir) = config.home_dir.as_ref() {
        return Some(home_dir.join(".codex"));
    }
    if let Some(codex_home) = env::var_os("CODEX_HOME") {
        return Some(PathBuf::from(codex_home));
    }
    env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join(".codex"))
}

fn codex_fast_pricing_basis(config: &SnapshotConfig) -> FastPricingBasis {
    codex_home_path(config)
        .and_then(|path| File::open(path.join("auth.json")).ok())
        .and_then(|file| serde_json::from_reader::<_, CodexAuthConfig>(file).ok())
        .and_then(|auth| auth.auth_mode)
        .and_then(|mode| fast_pricing_basis_for_auth_mode(&mode))
        .unwrap_or_default()
}

fn fast_pricing_basis_for_auth_mode(auth_mode: &str) -> Option<FastPricingBasis> {
    match auth_mode.trim().to_ascii_lowercase().as_str() {
        "chatgpt" => Some(FastPricingBasis::ChatGptSubscription),
        "api" | "api-key" | "api_key" | "apikey" => Some(FastPricingBasis::ApiPriority),
        _ => None,
    }
}

fn write_json(value: &impl serde::Serialize) -> Result<(), Box<dyn Error>> {
    let stdout = io::stdout();
    let mut output = stdout.lock();
    serde_json::to_writer(&mut output, value)?;
    writeln!(output)?;
    Ok(())
}

fn parse_args(args: impl IntoIterator<Item = OsString>) -> Result<Command, String> {
    let mut args = args.into_iter();
    let Some(first) = args.next() else {
        return Ok(Command::Snapshot(SnapshotConfig::default()));
    };

    if first.to_str() == Some("request-detail") {
        return parse_request_detail_args(args).map(Command::RequestDetail);
    }
    if first.to_str() == Some("memory-receiver") {
        return parse_memory_receiver_args(args).map(Command::MemoryReceiver);
    }

    parse_snapshot_args(std::iter::once(first).chain(args)).map(Command::Snapshot)
}

fn parse_snapshot_args(args: impl IntoIterator<Item = OsString>) -> Result<SnapshotConfig, String> {
    let mut config = SnapshotConfig::default();
    let mut args = args.into_iter();

    while let Some(argument) = args.next() {
        match argument.to_str() {
            Some("--days") => {
                let value = args.next().ok_or("--days requires a value")?;
                let value = value.to_str().ok_or("--days must be valid UTF-8")?;
                config.days = value
                    .parse::<usize>()
                    .map_err(|_| "--days must be a positive integer")?;
                if config.days == 0 {
                    return Err("--days must be a positive integer".to_string());
                }
            }
            Some("--home-dir") => {
                let value = args.next().ok_or("--home-dir requires a path")?;
                config.home_dir = Some(PathBuf::from(value));
            }
            Some("--statistics-timezone") => {
                let value = args
                    .next()
                    .ok_or("--statistics-timezone requires a value")?;
                let value = value
                    .to_str()
                    .ok_or("--statistics-timezone must be valid UTF-8")?;
                config.statistics_time_zone = value
                    .parse()
                    .map_err(|_| "--statistics-timezone must be utc or local".to_string())?;
            }
            Some("--weekly-reset-ms") => {
                let value = args.next().ok_or("--weekly-reset-ms requires a value")?;
                let value = value
                    .to_str()
                    .ok_or("--weekly-reset-ms must be valid UTF-8")?;
                config.weekly_reset_ms = Some(
                    value
                        .parse::<i64>()
                        .map_err(|_| "--weekly-reset-ms must be an integer")?,
                );
            }
            Some("--claude-weekly-reset-ms") => {
                let value = args
                    .next()
                    .ok_or("--claude-weekly-reset-ms requires a value")?;
                let value = value
                    .to_str()
                    .ok_or("--claude-weekly-reset-ms must be valid UTF-8")?;
                config.claude_weekly_reset_ms = Some(
                    value
                        .parse::<i64>()
                        .map_err(|_| "--claude-weekly-reset-ms must be an integer")?,
                );
            }
            Some("--grok-weekly-reset-ms") => {
                let value = args
                    .next()
                    .ok_or("--grok-weekly-reset-ms requires a value")?;
                let value = value
                    .to_str()
                    .ok_or("--grok-weekly-reset-ms must be valid UTF-8")?;
                config.grok_weekly_reset_ms = Some(
                    value
                        .parse::<i64>()
                        .map_err(|_| "--grok-weekly-reset-ms must be an integer")?,
                );
            }
            Some("--memory-database") => {
                let value = args.next().ok_or("--memory-database requires a path")?;
                config.memory_database = Some(PathBuf::from(value));
            }
            Some("--anthropic-pricing-markdown") => {
                let value = args
                    .next()
                    .ok_or("--anthropic-pricing-markdown requires a path")?;
                config.anthropic_pricing_markdown = Some(PathBuf::from(value));
            }
            Some("--help" | "-h") => {
                return Err(USAGE.to_string());
            }
            Some(value) => return Err(format!("unknown argument: {value}")),
            None => return Err("arguments must be valid UTF-8".to_string()),
        }
    }

    Ok(config)
}

fn parse_memory_receiver_args(
    args: impl IntoIterator<Item = OsString>,
) -> Result<MemoryReceiverConfig, String> {
    let mut database_path = None;
    let mut status_path = None;
    let mut port = DEFAULT_PORT;
    let mut parent_pid = None;
    let mut args = args.into_iter();
    while let Some(argument) = args.next() {
        match argument.to_str() {
            Some("--database") => {
                database_path = Some(PathBuf::from(
                    args.next().ok_or("--database requires a path")?,
                ));
            }
            Some("--status-file") => {
                status_path = Some(PathBuf::from(
                    args.next().ok_or("--status-file requires a path")?,
                ));
            }
            Some("--port") => {
                let value = args.next().ok_or("--port requires a value")?;
                let value = value.to_str().ok_or("--port must be valid UTF-8")?;
                port = value
                    .parse::<u16>()
                    .map_err(|_| "--port must be between 1 and 65535")?;
                if port == 0 {
                    return Err("--port must be between 1 and 65535".to_string());
                }
            }
            Some("--parent-pid") => {
                let value = args.next().ok_or("--parent-pid requires a value")?;
                let value = value
                    .to_str()
                    .ok_or("--parent-pid must be valid UTF-8")?;
                parent_pid = Some(
                    value
                        .parse::<u32>()
                        .map_err(|_| "--parent-pid must be a positive integer")?,
                );
                if parent_pid == Some(0) {
                    return Err("--parent-pid must be a positive integer".to_string());
                }
            }
            Some("--help" | "-h") => return Err(USAGE.to_string()),
            Some(value) => return Err(format!("unknown memory-receiver argument: {value}")),
            None => return Err("arguments must be valid UTF-8".to_string()),
        }
    }
    Ok(MemoryReceiverConfig {
        database_path: database_path.ok_or("memory-receiver requires --database")?,
        status_path,
        port,
        parent_pid,
    })
}

fn parse_request_detail_args(
    args: impl IntoIterator<Item = OsString>,
) -> Result<RequestDetailConfig, String> {
    let mut platform = "codex".to_string();
    let mut session_path = None;
    let mut start_ms = None;
    let mut end_ms = None;
    let mut args = args.into_iter();

    while let Some(argument) = args.next() {
        match argument.to_str() {
            Some("--platform") => {
                let value = args.next().ok_or("--platform requires a value")?;
                let value = value.to_str().ok_or("--platform must be valid UTF-8")?;
                if !matches!(value, "codex" | "claude" | "grok") {
                    return Err("--platform must be codex, claude, or grok".to_string());
                }
                platform = value.to_string();
            }
            Some("--session-path") => {
                let value = args.next().ok_or("--session-path requires a path")?;
                session_path = Some(PathBuf::from(value));
            }
            Some("--start-ms") => {
                let value = args.next().ok_or("--start-ms requires a value")?;
                let value = value.to_str().ok_or("--start-ms must be valid UTF-8")?;
                start_ms = Some(
                    value
                        .parse::<i64>()
                        .map_err(|_| "--start-ms must be an integer")?,
                );
            }
            Some("--end-ms") => {
                let value = args.next().ok_or("--end-ms requires a value")?;
                let value = value.to_str().ok_or("--end-ms must be valid UTF-8")?;
                end_ms = Some(
                    value
                        .parse::<i64>()
                        .map_err(|_| "--end-ms must be an integer")?,
                );
            }
            Some("--help" | "-h") => return Err(USAGE.to_string()),
            Some(value) => return Err(format!("unknown request-detail argument: {value}")),
            None => return Err("arguments must be valid UTF-8".to_string()),
        }
    }

    let config = RequestDetailConfig {
        platform,
        session_path: session_path.ok_or("request-detail requires --session-path")?,
        start_ms: start_ms.ok_or("request-detail requires --start-ms")?,
        end_ms: end_ms.ok_or("request-detail requires --end-ms")?,
    };
    if config.start_ms > config.end_ms {
        return Err("request start must not be after request end".to_string());
    }
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, NaiveDate};

    #[test]
    fn zero_arguments_use_the_thirty_day_default() {
        assert_eq!(
            parse_args(Vec::<OsString>::new()).unwrap(),
            Command::Snapshot(SnapshotConfig::default())
        );
    }

    #[test]
    fn accepts_development_overrides() {
        let config = parse_args([
            OsString::from("--days"),
            OsString::from("7"),
            OsString::from("--home-dir"),
            OsString::from("/tmp/home"),
            OsString::from("--statistics-timezone"),
            OsString::from("utc"),
            OsString::from("--weekly-reset-ms"),
            OsString::from("1800000000000"),
            OsString::from("--claude-weekly-reset-ms"),
            OsString::from("1799000000000"),
            OsString::from("--grok-weekly-reset-ms"),
            OsString::from("1798000000000"),
            OsString::from("--anthropic-pricing-markdown"),
            OsString::from("/tmp/anthropic-pricing.md"),
        ])
        .unwrap();

        assert_eq!(
            config,
            Command::Snapshot(SnapshotConfig {
                days: 7,
                home_dir: Some(PathBuf::from("/tmp/home")),
                statistics_time_zone: StatisticsTimeZone::Utc,
                weekly_reset_ms: Some(1_800_000_000_000),
                claude_weekly_reset_ms: Some(1_799_000_000_000),
                grok_weekly_reset_ms: Some(1_798_000_000_000),
                anthropic_pricing_markdown: Some(PathBuf::from("/tmp/anthropic-pricing.md")),
                memory_database: None,
            })
        );
    }

    #[test]
    fn utc_statistics_timezone_uses_the_timestamp_utc_date() {
        let timestamp = DateTime::parse_from_rfc3339("2026-08-11T00:30:00Z")
            .unwrap()
            .timestamp_millis();

        assert_eq!(
            StatisticsTimeZone::Utc.date_at_ms(timestamp),
            NaiveDate::from_ymd_opt(2026, 8, 11)
        );
        assert_eq!(StatisticsTimeZone::Utc.snapshot_name(), "UTC");
    }

    #[test]
    fn rejects_unknown_statistics_timezone() {
        let error = parse_args([
            OsString::from("--statistics-timezone"),
            OsString::from("mars"),
        ])
        .unwrap_err();

        assert_eq!(error, "--statistics-timezone must be utc or local");
    }

    #[test]
    fn accepts_memory_receiver_mode() {
        let command = parse_args([
            OsString::from("memory-receiver"),
            OsString::from("--database"),
            OsString::from("/tmp/memory.sqlite"),
            OsString::from("--status-file"),
            OsString::from("/tmp/memory-status.json"),
            OsString::from("--port"),
            OsString::from("5318"),
            OsString::from("--parent-pid"),
            OsString::from("123"),
        ])
        .unwrap();

        assert_eq!(
            command,
            Command::MemoryReceiver(MemoryReceiverConfig {
                database_path: PathBuf::from("/tmp/memory.sqlite"),
                status_path: Some(PathBuf::from("/tmp/memory-status.json")),
                port: 5318,
                parent_pid: Some(123),
            })
        );
    }

    #[test]
    fn accepts_request_detail_mode() {
        let command = parse_args([
            OsString::from("request-detail"),
            OsString::from("--platform"),
            OsString::from("claude"),
            OsString::from("--session-path"),
            OsString::from("/tmp/session.jsonl"),
            OsString::from("--start-ms"),
            OsString::from("1000"),
            OsString::from("--end-ms"),
            OsString::from("2000"),
        ])
        .unwrap();

        assert_eq!(
            command,
            Command::RequestDetail(RequestDetailConfig {
                platform: "claude".to_string(),
                session_path: PathBuf::from("/tmp/session.jsonl"),
                start_ms: 1000,
                end_ms: 2000,
            })
        );
    }

    #[test]
    fn request_detail_requires_all_arguments_and_an_ordered_range() {
        let missing = parse_args([
            OsString::from("request-detail"),
            OsString::from("--session-path"),
            OsString::from("/tmp/session.jsonl"),
        ])
        .unwrap_err();
        assert_eq!(missing, "request-detail requires --start-ms");

        let reversed = parse_args([
            OsString::from("request-detail"),
            OsString::from("--session-path"),
            OsString::from("/tmp/session.jsonl"),
            OsString::from("--start-ms"),
            OsString::from("2"),
            OsString::from("--end-ms"),
            OsString::from("1"),
        ])
        .unwrap_err();
        assert_eq!(reversed, "request start must not be after request end");
    }

    #[test]
    fn maps_codex_auth_mode_to_the_matching_fast_pricing_basis() {
        assert_eq!(
            fast_pricing_basis_for_auth_mode("chatgpt"),
            Some(FastPricingBasis::ChatGptSubscription)
        );
        assert_eq!(
            fast_pricing_basis_for_auth_mode("apikey"),
            Some(FastPricingBasis::ApiPriority)
        );
        assert_eq!(fast_pricing_basis_for_auth_mode("future-mode"), None);
    }
}
