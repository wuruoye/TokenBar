use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use tokenbar_helper::StatisticsTimeZone;

const MAX_CONFIG_BYTES: u64 = 1024 * 1024;
const DEFAULT_DAYS: usize = 30;

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FileConfig {
    endpoint: Option<String>,
    device_name: Option<String>,
    days: Option<usize>,
    codex_home: Option<PathBuf>,
    helper_path: Option<PathBuf>,
    statistics_timezone: Option<StatisticsTimeZone>,
    weekly_reset_ms: Option<i64>,
    state_dir: Option<PathBuf>,
}

#[derive(Debug, Default)]
pub struct ConfigOverrides {
    pub endpoint: Option<String>,
    pub device_name: Option<String>,
    pub days: Option<usize>,
    pub codex_home: Option<PathBuf>,
    pub helper_path: Option<PathBuf>,
    pub statistics_timezone: Option<StatisticsTimeZone>,
    pub state_dir: Option<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub endpoint: Option<String>,
    pub device_name: String,
    pub days: usize,
    pub codex_home: PathBuf,
    pub helper_path: PathBuf,
    pub statistics_timezone: StatisticsTimeZone,
    pub weekly_reset_ms: Option<i64>,
    pub state_dir: PathBuf,
}

impl AppConfig {
    pub fn load(path: Option<&Path>, overrides: ConfigOverrides) -> Result<Self> {
        let file = match path {
            Some(path) => load_file(path)?,
            None => FileConfig::default(),
        };

        let device_name = overrides
            .device_name
            .or(file.device_name)
            .or_else(|| std::env::var("COMPUTERNAME").ok())
            .or_else(|| std::env::var("HOSTNAME").ok())
            .unwrap_or_else(|| "TokenBar device".to_string());
        tokenbar_sync_device_name(&device_name)?;

        let days = overrides.days.or(file.days).unwrap_or(DEFAULT_DAYS);
        if !(1..=3660).contains(&days) {
            bail!("days must be between 1 and 3660");
        }

        let weekly_reset_ms = file.weekly_reset_ms;
        if weekly_reset_ms.is_some_and(|value| value <= 0) {
            bail!("weeklyResetMs must be positive when provided");
        }

        let state_dir = overrides
            .state_dir
            .or(file.state_dir)
            .map(Ok)
            .unwrap_or_else(default_state_dir)?;
        require_absolute("state directory", &state_dir)?;

        let codex_home = overrides
            .codex_home
            .or(file.codex_home)
            .map(Ok)
            .unwrap_or_else(default_codex_home)?;
        require_absolute("Codex home", &codex_home)?;

        let helper_path = overrides
            .helper_path
            .or(file.helper_path)
            .map(Ok)
            .unwrap_or_else(default_helper_path)?;
        require_absolute("TokenBar helper path", &helper_path)?;

        let statistics_timezone = overrides
            .statistics_timezone
            .or(file.statistics_timezone)
            .unwrap_or(StatisticsTimeZone::Utc);

        Ok(Self {
            endpoint: overrides.endpoint.or(file.endpoint),
            device_name,
            days,
            codex_home,
            helper_path,
            statistics_timezone,
            weekly_reset_ms,
            state_dir,
        })
    }
}

fn load_file(path: &Path) -> Result<FileConfig> {
    let metadata = fs::metadata(path)
        .with_context(|| format!("could not inspect config file {}", path.display()))?;
    if metadata.len() > MAX_CONFIG_BYTES {
        bail!("config file exceeds 1 MiB");
    }
    let bytes =
        fs::read(path).with_context(|| format!("could not read config file {}", path.display()))?;
    serde_json::from_slice(&bytes).context("config file is not valid TokenBar Sync JSON")
}

fn default_state_dir() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("LOCALAPPDATA").filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(path).join("TokenBarSync"));
    }
    if let Some(path) = std::env::var_os("XDG_STATE_HOME").filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(path).join("tokenbar-sync"));
    }
    std::env::var_os("HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .map(|path| path.join(".local").join("state").join("tokenbar-sync"))
        .context("could not resolve a default state directory; pass --state-dir")
}

fn default_codex_home() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("CODEX_HOME").filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(path));
    }
    std::env::var_os("USERPROFILE")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
        })
        .map(|path| path.join(".codex"))
        .context("could not resolve the default Codex home; pass --codex-home")
}

fn default_helper_path() -> Result<PathBuf> {
    let executable =
        std::env::current_exe().context("could not resolve the Sync executable path")?;
    let directory = executable
        .parent()
        .context("Sync executable path has no parent directory")?;
    let name = if cfg!(target_os = "windows") {
        "tokenbar-helper.exe"
    } else {
        "tokenbar-helper"
    };
    Ok(directory.join(name))
}

fn require_absolute(label: &str, path: &Path) -> Result<()> {
    if !path.is_absolute() {
        bail!("{label} must be an absolute path");
    }
    Ok(())
}

pub fn tokenbar_sync_device_name(value: &str) -> Result<()> {
    let count = value.chars().count();
    if !(1..=80).contains(&count) || value.trim().is_empty() {
        bail!("device name must contain 1 to 80 display characters");
    }
    if value.chars().any(char::is_control) {
        bail!("device name must not contain control characters");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_name_validation_enforces_display_bounds() {
        assert!(tokenbar_sync_device_name("Windows workstation").is_ok());
        assert!(tokenbar_sync_device_name("").is_err());
        assert!(tokenbar_sync_device_name("\n").is_err());
        assert!(tokenbar_sync_device_name(&"x".repeat(81)).is_err());
    }
}
