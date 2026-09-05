use std::fs::{self, File};
use std::io::{BufReader, BufWriter, Write};
use std::path::Path;

use anyhow::{Context, Result};
use serde::{de::DeserializeOwned, Deserialize, Serialize};

const LAST_RUN_FILE: &str = "last-run.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LastRunStatus {
    pub attempted_at_ms: i64,
    pub succeeded: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub http_status: Option<u16>,
    pub category: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot_schema_version: Option<u64>,
}

pub fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("could not create output directory {}", parent.display()))?;
    }
    let file = File::create(path)
        .with_context(|| format!("could not create JSON output {}", path.display()))?;
    let mut writer = BufWriter::new(file);
    serde_json::to_writer_pretty(&mut writer, value).context("could not encode JSON output")?;
    writer
        .write_all(b"\n")
        .context("could not finish JSON output")?;
    writer.flush().context("could not flush JSON output")?;
    Ok(())
}

pub fn read_json<T: DeserializeOwned>(path: &Path) -> Result<T> {
    let file =
        File::open(path).with_context(|| format!("could not open JSON file {}", path.display()))?;
    serde_json::from_reader(BufReader::new(file)).context("JSON file has an invalid schema")
}

pub fn write_last_run(state_dir: &Path, status: &LastRunStatus) -> Result<()> {
    write_json(&state_dir.join(LAST_RUN_FILE), status)
}

pub fn read_last_run(state_dir: &Path) -> Result<Option<LastRunStatus>> {
    let path = state_dir.join(LAST_RUN_FILE);
    if !path.exists() {
        return Ok(None);
    }
    read_json(&path).map(Some)
}
