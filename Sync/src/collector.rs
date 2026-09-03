use std::ffi::OsString;
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

use anyhow::{bail, Context, Result};
use chrono::Utc;
use serde_json::Value;

use crate::config::AppConfig;
use crate::protocol::validate_snapshot;
use crate::weekly_resets::PlatformWeeklyResets;

const MAX_HELPER_OUTPUT_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug)]
pub struct CollectedSnapshot {
    pub value: Value,
    pub schema_version: u64,
    pub generated_at_ms: i64,
}

pub fn collect(
    config: &AppConfig,
    remote_resets: PlatformWeeklyResets,
) -> Result<CollectedSnapshot> {
    validate_codex_home(&config.codex_home)?;
    if !config.helper_path.is_file() {
        bail!(
            "TokenBar helper executable does not exist: {}",
            config.helper_path.display()
        );
    }

    let generated_at_ms = Utc::now().timestamp_millis();
    let resets = remote_resets.with_codex_fallback(config.weekly_reset_ms, generated_at_ms);
    let arguments = helper_arguments(config, resets)?;
    let mut command = helper_command(&config.helper_path, &arguments);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    command.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
    let mut child = command
        .spawn()
        .context("could not start tokenbar-helper")?;
    let mut stdout = child
        .stdout
        .take()
        .context("tokenbar-helper stdout pipe is unavailable")?;
    let mut output = Vec::new();
    stdout
        .by_ref()
        .take((MAX_HELPER_OUTPUT_BYTES + 1) as u64)
        .read_to_end(&mut output)
        .context("could not read tokenbar-helper output")?;
    if output.len() > MAX_HELPER_OUTPUT_BYTES {
        let _ = child.kill();
        let _ = child.wait();
        bail!("tokenbar-helper output exceeds the 16 MiB client limit");
    }
    let status = child.wait().context("could not reap tokenbar-helper")?;
    if !status.success() {
        bail!(
            "tokenbar-helper failed with exit code {}",
            status.code().unwrap_or(-1)
        );
    }

    let snapshot: Value = serde_json::from_slice(&output)
        .context("tokenbar-helper output is not valid JSON")?;
    let metadata = validate_snapshot(&snapshot)
        .context("tokenbar-helper output is not a valid ActivitySnapshot")?;
    if config.statistics_timezone.as_str() == "utc"
        && snapshot.get("timezone").and_then(Value::as_str) != Some("UTC")
    {
        bail!("tokenbar-helper did not honor --statistics-timezone utc");
    }
    Ok(CollectedSnapshot {
        value: snapshot,
        schema_version: metadata.schema_version,
        generated_at_ms: metadata.generated_at_ms,
    })
}

fn helper_command(helper_path: &Path, arguments: &[OsString]) -> Command {
    let mut command = Command::new(helper_path);
    command.args(arguments);
    command.env_remove("TOKENBAR_SYNC_TOKEN");
    command
}

fn helper_arguments(config: &AppConfig, resets: PlatformWeeklyResets) -> Result<Vec<OsString>> {
    let parent = config
        .codex_home
        .parent()
        .context("Codex home has no parent directory")?;
    let mut arguments = vec![
        OsString::from("--days"),
        OsString::from(config.days.to_string()),
        OsString::from("--home-dir"),
        parent.as_os_str().to_owned(),
        OsString::from("--statistics-timezone"),
        OsString::from(config.statistics_timezone.as_str()),
    ];
    append_reset_arguments(&mut arguments, resets);
    Ok(arguments)
}

fn append_reset_arguments(arguments: &mut Vec<OsString>, resets: PlatformWeeklyResets) {
    for (flag, value) in [
        ("--weekly-reset-ms", resets.codex),
        ("--claude-weekly-reset-ms", resets.claude),
        ("--grok-weekly-reset-ms", resets.grok),
        ("--antigravity-weekly-reset-ms", resets.antigravity),
    ] {
        if let Some(value) = value {
            arguments.push(OsString::from(flag));
            arguments.push(OsString::from(value.to_string()));
        }
    }
}

fn validate_codex_home(path: &Path) -> Result<()> {
    if !path.is_dir() {
        bail!(
            "Codex home does not exist or is not a directory: {}",
            path.display()
        );
    }
    let is_dot_codex = path
        .file_name()
        .and_then(|value| value.to_str())
        .is_some_and(|value| value.eq_ignore_ascii_case(".codex"));
    if !is_dot_codex {
        bail!(
            "this MVP requires the Codex data root to be a directory named .codex; got {}",
            path.display()
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_every_platform_reset_to_exact_helper_flags() {
        let mut arguments = Vec::new();
        append_reset_arguments(
            &mut arguments,
            PlatformWeeklyResets {
                codex: Some(11),
                claude: Some(22),
                grok: Some(33),
                antigravity: Some(44),
            },
        );
        assert_eq!(
            arguments,
            vec![
                OsString::from("--weekly-reset-ms"),
                OsString::from("11"),
                OsString::from("--claude-weekly-reset-ms"),
                OsString::from("22"),
                OsString::from("--grok-weekly-reset-ms"),
                OsString::from("33"),
                OsString::from("--antigravity-weekly-reset-ms"),
                OsString::from("44"),
            ]
        );
    }

    #[test]
    fn omits_helper_reset_flags_when_metadata_is_missing() {
        let mut arguments = Vec::new();
        append_reset_arguments(&mut arguments, PlatformWeeklyResets::default());
        assert!(arguments.is_empty());
    }

    #[test]
    fn helper_process_does_not_inherit_the_bearer_token() {
        let command = helper_command(Path::new("tokenbar-helper"), &[]);
        assert!(command
            .get_envs()
            .any(|(key, value)| key == "TOKENBAR_SYNC_TOKEN" && value.is_none()));
    }
}
