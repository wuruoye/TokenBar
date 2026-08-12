mod collector;
mod config;
mod device;
mod incremental;
mod protocol;
mod storage;
mod sync_client;
mod weekly_resets;

use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use chrono::Utc;
use clap::{Parser, Subcommand};
use serde::Serialize;
use tokenbar_helper::StatisticsTimeZone;

use crate::config::{AppConfig, ConfigOverrides};
use crate::incremental::{IncrementalPlan, UploadMode};
use crate::protocol::{DeviceDescriptor, DeviceOs};
use crate::storage::LastRunStatus;
use crate::sync_client::{Endpoint, SyncClient, SyncError};
use crate::weekly_resets::PlatformWeeklyResets;

#[derive(Debug, Parser)]
#[command(
    version,
    about = "Headless TokenBar activity snapshot sync for Windows"
)]
struct Cli {
    #[arg(long, global = true)]
    config: Option<PathBuf>,
    #[arg(long, global = true)]
    state_dir: Option<PathBuf>,
    #[arg(long, global = true)]
    endpoint: Option<String>,
    #[arg(long, global = true)]
    device_name: Option<String>,
    #[arg(long, global = true)]
    days: Option<usize>,
    #[arg(long, global = true)]
    codex_home: Option<PathBuf>,
    /// Path to the repository-built tokenbar-helper executable.
    #[arg(long, global = true)]
    helper_path: Option<PathBuf>,
    /// Statistics calendar used for daily windows and reset boundaries (default: utc).
    #[arg(long, global = true)]
    statistics_timezone: Option<StatisticsTimeZone>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Build a sanitized protocol-v1 envelope without transmitting it.
    Collect {
        /// Output path. Defaults to <state-dir>/snapshot.json.
        #[arg(long)]
        output: Option<PathBuf>,
    },
    /// Build and upload one sanitized snapshot.
    Upload,
    /// Download the latest snapshot per device and save sanitized JSON.
    Download {
        /// Output path. Defaults to <state-dir>/remote-snapshots.json.
        #[arg(long)]
        output: Option<PathBuf>,
    },
    /// Print the stable local device descriptor as JSON.
    Device,
    /// Print non-secret client status as JSON.
    Status,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ClientStatus {
    client_version: &'static str,
    device: DeviceDescriptor,
    state_dir: PathBuf,
    codex_home: PathBuf,
    helper_path: PathBuf,
    statistics_timezone: StatisticsTimeZone,
    endpoint_configured: bool,
    token_configured: bool,
    last_run: Option<LastRunStatus>,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("tokenbar-sync: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    let config = AppConfig::load(
        cli.config.as_deref(),
        ConfigOverrides {
            endpoint: cli.endpoint,
            device_name: cli.device_name,
            days: cli.days,
            codex_home: cli.codex_home,
            helper_path: cli.helper_path,
            statistics_timezone: cli.statistics_timezone,
            state_dir: cli.state_dir,
        },
    )?;

    match cli.command {
        Command::Collect { output } => collect_command(&config, output),
        Command::Upload => upload_command(&config),
        Command::Download { output } => download_command(&config, output),
        Command::Device => device_command(&config),
        Command::Status => status_command(&config),
    }
}

fn descriptor(config: &AppConfig) -> Result<DeviceDescriptor> {
    let state = device::load_or_create(&config.state_dir)?;
    Ok(DeviceDescriptor {
        id: state.id,
        name: config.device_name.clone(),
        os: DeviceOs::current()?,
        client_version: Some(env!("CARGO_PKG_VERSION").to_string()),
    })
}

fn collect_command(config: &AppConfig, output: Option<PathBuf>) -> Result<()> {
    let resets = prefetch_weekly_resets(config);
    let snapshot = collector::collect(config, resets)?;
    let schema_version = snapshot.schema_version;
    let generated_at_ms = snapshot.generated_at_ms;
    let envelope = protocol::upload_envelope(snapshot.value, descriptor(config)?)?;
    debug_assert_eq!(envelope.generated_at_ms, generated_at_ms);
    let output = output.unwrap_or_else(|| config.state_dir.join("snapshot.json"));
    storage::write_json(&output, &envelope)?;
    println!(
        "sanitized snapshot written: schemaVersion={}, device={}",
        schema_version, envelope.device.id
    );
    Ok(())
}

fn upload_command(config: &AppConfig) -> Result<()> {
    let endpoint = required_endpoint(config)?;
    let token = required_token()?;
    let endpoint_key = endpoint.state_key();
    let client = SyncClient::new(endpoint)?;
    let now_ms = Utc::now().timestamp_millis();
    let resets = fetch_weekly_resets(&client, &token, now_ms);
    let snapshot = collector::collect(config, resets)?;
    let schema_version = snapshot.schema_version;
    let generated_at_ms = snapshot.generated_at_ms;
    let envelope = protocol::upload_envelope(snapshot.value, descriptor(config)?)?;
    debug_assert_eq!(envelope.generated_at_ms, generated_at_ms);
    let attempted_at_ms = Utc::now().timestamp_millis();
    let previous_state = storage::read_incremental_state(&config.state_dir);
    let mut plan = IncrementalPlan::build(
        &envelope,
        previous_state.as_ref(),
        &endpoint_key,
        config.days,
        attempted_at_ms,
    )?;

    let uploaded = match client.upload_v2(&token, &plan.body) {
        Ok(result) => Ok((result.http_status, result.revision, plan.mode.label())),
        Err(SyncError::Conflict) if plan.mode == UploadMode::Delta => {
            plan.force_full();
            client
                .upload_v2(&token, &plan.body)
                .map(|result| (result.http_status, result.revision, plan.mode.label()))
        }
        Err(SyncError::Http(404)) => client
            .upload(&token, &envelope)
            .map(|result| (result.http_status, 0, "v1-full")),
        Err(error) => Err(error),
    };

    match uploaded {
        Ok((http_status, revision, transport)) => {
            if revision > 0 {
                match plan.state_after(
                    endpoint_key,
                    revision,
                    config.days,
                    attempted_at_ms,
                ) {
                    Ok(state) => {
                        if let Err(error) = storage::write_incremental_state(&config.state_dir, &state)
                        {
                            eprintln!(
                                "incremental metadata could not be saved; next run will recalibrate: {error:#}"
                            );
                        }
                    }
                    Err(error) => eprintln!(
                        "incremental metadata was invalid; next run will recalibrate: {error:#}"
                    ),
                }
            }
            storage::write_last_run(
                &config.state_dir,
                &LastRunStatus {
                    attempted_at_ms,
                    succeeded: true,
                    http_status: Some(http_status),
                    category: "success".to_string(),
                    snapshot_schema_version: Some(schema_version),
                },
            )?;
            println!(
                "upload succeeded: HTTP {}, device={}, schemaVersion={}, transport={}",
                http_status, envelope.device.id, schema_version, transport
            );
            Ok(())
        }
        Err(error) => {
            let _ = storage::write_last_run(
                &config.state_dir,
                &LastRunStatus {
                    attempted_at_ms,
                    succeeded: false,
                    http_status: error.http_status(),
                    category: error.category().to_string(),
                    snapshot_schema_version: Some(schema_version),
                },
            );
            Err(error.into())
        }
    }
}

fn download_command(config: &AppConfig, output: Option<PathBuf>) -> Result<()> {
    let endpoint = required_endpoint(config)?;
    let token = required_token()?;
    let client = SyncClient::new(endpoint)?;
    let response = client.download(&token)?;
    let count = response.snapshots.len();
    let output = output.unwrap_or_else(|| config.state_dir.join("remote-snapshots.json"));
    storage::write_json(&output, &response)?;
    println!("download succeeded: {count} device snapshot(s) written");
    Ok(())
}

fn device_command(config: &AppConfig) -> Result<()> {
    let value = descriptor(config)?;
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}

fn status_command(config: &AppConfig) -> Result<()> {
    let status = ClientStatus {
        client_version: env!("CARGO_PKG_VERSION"),
        device: descriptor(config)?,
        state_dir: config.state_dir.clone(),
        codex_home: config.codex_home.clone(),
        helper_path: config.helper_path.clone(),
        statistics_timezone: config.statistics_timezone,
        endpoint_configured: config.endpoint.is_some(),
        token_configured: std::env::var("TOKENBAR_SYNC_TOKEN")
            .is_ok_and(|value| !value.trim().is_empty()),
        last_run: storage::read_last_run(&config.state_dir)?,
    };
    println!("{}", serde_json::to_string_pretty(&status)?);
    Ok(())
}

fn required_endpoint(config: &AppConfig) -> Result<Endpoint> {
    let value = config
        .endpoint
        .as_deref()
        .context("sync endpoint is not configured; use --endpoint or config.json")?;
    Endpoint::parse(value).map_err(Into::into)
}

fn required_token() -> Result<String> {
    let token =
        std::env::var("TOKENBAR_SYNC_TOKEN").context("TOKENBAR_SYNC_TOKEN is not configured")?;
    if token.trim().is_empty() {
        bail!("TOKENBAR_SYNC_TOKEN is not configured");
    }
    Ok(token)
}

fn prefetch_weekly_resets(config: &AppConfig) -> PlatformWeeklyResets {
    let Some(endpoint_value) = config.endpoint.as_deref() else {
        return PlatformWeeklyResets::default();
    };
    let Ok(token) = std::env::var("TOKENBAR_SYNC_TOKEN") else {
        return PlatformWeeklyResets::default();
    };
    if token.trim().is_empty() {
        return PlatformWeeklyResets::default();
    }
    let Ok(endpoint) = Endpoint::parse(endpoint_value) else {
        return PlatformWeeklyResets::default();
    };
    let Ok(client) = SyncClient::new(endpoint) else {
        return PlatformWeeklyResets::default();
    };
    fetch_weekly_resets(&client, &token, Utc::now().timestamp_millis())
}

fn fetch_weekly_resets(
    client: &SyncClient,
    token: &str,
    now_ms: i64,
) -> PlatformWeeklyResets {
    match client.reset_metadata(token) {
        Ok(response) => PlatformWeeklyResets::from_metadata(&response, now_ms),
        Err(SyncError::Http(404)) => match client.download(token) {
            Ok(response) => PlatformWeeklyResets::from_download(&response, now_ms),
            Err(error) => {
                eprintln!(
                    "weekly reset metadata unavailable ({}); continuing without remote resets",
                    error.category()
                );
                PlatformWeeklyResets::default()
            }
        },
        Err(error) => {
            eprintln!(
                "weekly reset metadata unavailable ({}); continuing without remote resets",
                error.category()
            );
            PlatformWeeklyResets::default()
        }
    }
}
