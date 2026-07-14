use std::env;
use std::error::Error;
use std::ffi::OsString;
use std::io::{self, Write};
use std::path::PathBuf;

use chrono::{Days, Local};
use tokenbar_helper::codex::{parse_local_codex_messages, LocalParseOptions};
use tokenbar_helper::pricing::CodexPricing;
use tokenbar_helper::{
    build_snapshot_with_session_titles, extract_request_detail, load_codex_session_titles,
    normalize_codex_reasoning_usage,
};

const DEFAULT_DAYS: usize = 30;
const USAGE: &str = "usage: tokenbar-helper [--days COUNT] [--home-dir PATH] [--weekly-reset-ms MS]\n       tokenbar-helper request-detail --session-path PATH --start-ms MS --end-ms MS";

#[derive(Debug, PartialEq, Eq)]
struct SnapshotConfig {
    days: usize,
    home_dir: Option<PathBuf>,
    weekly_reset_ms: Option<i64>,
}

impl Default for SnapshotConfig {
    fn default() -> Self {
        Self {
            days: DEFAULT_DAYS,
            home_dir: None,
            weekly_reset_ms: None,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
struct RequestDetailConfig {
    session_path: PathBuf,
    start_ms: i64,
    end_ms: i64,
}

#[derive(Debug, PartialEq, Eq)]
enum Command {
    Snapshot(SnapshotConfig),
    RequestDetail(RequestDetailConfig),
}

fn main() -> Result<(), Box<dyn Error>> {
    match parse_args(env::args_os().skip(1))? {
        Command::Snapshot(config) => run_snapshot(config),
        Command::RequestDetail(config) => {
            let detail =
                extract_request_detail(&config.session_path, config.start_ms, config.end_ms)
                    .map_err(io::Error::other)?;
            write_json(&detail)
        }
    }
}

fn run_snapshot(config: SnapshotConfig) -> Result<(), Box<dyn Error>> {
    let now = Local::now();
    let today = now.date_naive();
    let first_day = today
        .checked_sub_days(Days::new((config.days - 1) as u64))
        .ok_or("day range is too large")?;
    let scan_first_day = config
        .weekly_reset_ms
        .and_then(chrono::DateTime::from_timestamp_millis)
        .map(|timestamp| timestamp.with_timezone(&Local).date_naive())
        .map_or(first_day, |reset_day| first_day.min(reset_day));
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

    let pricing = CodexPricing::bundled();
    let mut messages = parse_local_codex_messages(
        LocalParseOptions {
            home_dir,
            use_env_roots,
            since: Some(scan_first_day.format("%Y-%m-%d").to_string()),
            until: Some(today.format("%Y-%m-%d").to_string()),
        },
        &pricing,
    )
    .map_err(io::Error::other)?;
    normalize_codex_reasoning_usage(&mut messages, |message| {
        pricing.calculate_cost_with_service_tier(
            &message.model_id,
            Some(&message.provider_id),
            &message.tokens,
            message.service_tier,
        )
    });
    let session_titles = session_index_path
        .as_deref()
        .map(|path| load_codex_session_titles(&messages, path))
        .unwrap_or_default();

    let timezone = iana_time_zone::get_timezone().unwrap_or_else(|_| now.offset().to_string());
    let snapshot = build_snapshot_with_session_titles(
        messages,
        today,
        now.timestamp_millis(),
        timezone,
        config.days,
        &session_titles,
        config.weekly_reset_ms,
    )
    .map_err(io::Error::other)?;

    write_json(&snapshot)
}

fn codex_session_index_path(config: &SnapshotConfig) -> Option<PathBuf> {
    if let Some(home_dir) = config.home_dir.as_ref() {
        return Some(home_dir.join(".codex/session_index.jsonl"));
    }
    if let Some(codex_home) = env::var_os("CODEX_HOME") {
        return Some(PathBuf::from(codex_home).join("session_index.jsonl"));
    }
    env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join(".codex/session_index.jsonl"))
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
            Some("--help" | "-h") => {
                return Err(USAGE.to_string());
            }
            Some(value) => return Err(format!("unknown argument: {value}")),
            None => return Err("arguments must be valid UTF-8".to_string()),
        }
    }

    Ok(config)
}

fn parse_request_detail_args(
    args: impl IntoIterator<Item = OsString>,
) -> Result<RequestDetailConfig, String> {
    let mut session_path = None;
    let mut start_ms = None;
    let mut end_ms = None;
    let mut args = args.into_iter();

    while let Some(argument) = args.next() {
        match argument.to_str() {
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
            OsString::from("--weekly-reset-ms"),
            OsString::from("1800000000000"),
        ])
        .unwrap();

        assert_eq!(
            config,
            Command::Snapshot(SnapshotConfig {
                days: 7,
                home_dir: Some(PathBuf::from("/tmp/home")),
                weekly_reset_ms: Some(1_800_000_000_000),
            })
        );
    }

    #[test]
    fn accepts_request_detail_mode() {
        let command = parse_args([
            OsString::from("request-detail"),
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
}
