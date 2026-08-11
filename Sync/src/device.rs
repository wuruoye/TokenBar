use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

const DEVICE_FILE: &str = "device.json";
const MAX_DEVICE_FILE_BYTES: u64 = 64 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeviceState {
    pub id: Uuid,
    pub created_at_ms: i64,
}

pub fn load_or_create(state_dir: &Path) -> Result<DeviceState> {
    fs::create_dir_all(state_dir)
        .with_context(|| format!("could not create state directory {}", state_dir.display()))?;
    let path = state_dir.join(DEVICE_FILE);
    if path.exists() {
        return read_state(&path);
    }

    let state = DeviceState {
        id: Uuid::new_v4(),
        created_at_ms: Utc::now().timestamp_millis(),
    };
    if state.created_at_ms <= 0 {
        bail!("system clock did not produce a positive timestamp");
    }

    let temporary = temporary_path(state_dir);
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .with_context(|| {
            format!(
                "could not create temporary device state {}",
                temporary.display()
            )
        })?;
    serde_json::to_writer_pretty(&mut file, &state).context("could not encode device state")?;
    file.write_all(b"\n")
        .context("could not finish device state")?;
    file.sync_all().context("could not flush device state")?;
    drop(file);

    match fs::rename(&temporary, &path) {
        Ok(()) => Ok(state),
        Err(_) if path.exists() => {
            let _ = fs::remove_file(&temporary);
            read_state(&path)
        }
        Err(error) => {
            let _ = fs::remove_file(&temporary);
            Err(error).with_context(|| format!("could not install device state {}", path.display()))
        }
    }
}

fn read_state(path: &Path) -> Result<DeviceState> {
    let metadata = fs::metadata(path)
        .with_context(|| format!("could not inspect device state {}", path.display()))?;
    if metadata.len() > MAX_DEVICE_FILE_BYTES {
        bail!("device state exceeds 64 KiB");
    }
    let bytes = fs::read(path)
        .with_context(|| format!("could not read device state {}", path.display()))?;
    let state: DeviceState =
        serde_json::from_slice(&bytes).context("device state is not valid JSON")?;
    if state.id.is_nil() || state.created_at_ms <= 0 {
        bail!("device state contains an invalid id or timestamp");
    }
    Ok(state)
}

fn temporary_path(state_dir: &Path) -> PathBuf {
    state_dir.join(format!(".device-{}.tmp", Uuid::new_v4()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_uuid_is_stable_across_reads() {
        let directory = tempfile::tempdir().unwrap();
        let first = load_or_create(directory.path()).unwrap();
        let second = load_or_create(directory.path()).unwrap();
        assert_eq!(first.id, second.id);
        assert!(!first.id.is_nil());
    }
}
