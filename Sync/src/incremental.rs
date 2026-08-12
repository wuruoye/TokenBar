use std::collections::BTreeMap;

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::protocol::{validate_upload_envelope, DeviceDescriptor, UploadEnvelope};

pub const PROTOCOL_V2: u32 = 2;
const STATE_VERSION: u32 = 1;
const FULL_CALIBRATION_INTERVAL_MS: i64 = 24 * 60 * 60 * 1_000;
const FULL_CALIBRATION_JITTER_MS: u32 = 60 * 60 * 1_000;
const DELTA_FULL_PERCENT: usize = 70;
const MAX_PARTITIONS: usize = 100_000;

pub type PartitionManifest = BTreeMap<String, String>;
type SnapshotPartitions = BTreeMap<String, Value>;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct IncrementalState {
    pub state_version: u32,
    pub endpoint: String,
    pub device_id: Uuid,
    pub revision: u64,
    pub last_full_at_ms: i64,
    pub schema_version: u64,
    pub timezone: String,
    pub collection_days: usize,
    pub manifest: PartitionManifest,
}

impl IncrementalState {
    pub fn is_usable_for(
        &self,
        envelope: &UploadEnvelope,
        endpoint: &str,
        collection_days: usize,
    ) -> bool {
        self.state_version == STATE_VERSION
            && self.endpoint == endpoint
            && self.device_id == envelope.device.id
            && self.revision > 0
            && self.last_full_at_ms > 0
            && self.schema_version == envelope.snapshot["schemaVersion"].as_u64().unwrap_or(0)
            && self.timezone == envelope.snapshot["timezone"].as_str().unwrap_or_default()
            && self.collection_days == collection_days
            && valid_manifest(&self.manifest)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UploadMode {
    Full,
    Delta,
}

impl UploadMode {
    pub fn label(self) -> &'static str {
        match self {
            Self::Full => "v2-full",
            Self::Delta => "v2-delta",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FullUpload {
    protocol_version: u32,
    mode: &'static str,
    device: DeviceDescriptor,
    generated_at_ms: i64,
    snapshot: Value,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeltaUpload {
    protocol_version: u32,
    mode: &'static str,
    device: DeviceDescriptor,
    generated_at_ms: i64,
    base_revision: u64,
    upserts: SnapshotPartitions,
    deletes: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
pub enum V2UploadEnvelope {
    Full(FullUpload),
    Delta(DeltaUpload),
}

impl V2UploadEnvelope {
    pub fn device_id(&self) -> Uuid {
        match self {
            Self::Full(value) => value.device.id,
            Self::Delta(value) => value.device.id,
        }
    }
}

#[derive(Debug, Clone)]
pub struct IncrementalPlan {
    pub body: V2UploadEnvelope,
    pub mode: UploadMode,
    manifest: PartitionManifest,
    full: FullUpload,
    previous_last_full_at_ms: Option<i64>,
}

impl IncrementalPlan {
    pub fn build(
        envelope: &UploadEnvelope,
        state: Option<&IncrementalState>,
        endpoint: &str,
        collection_days: usize,
        now_ms: i64,
    ) -> Result<Self> {
        validate_upload_envelope(envelope)?;
        let partitions = snapshot_partitions(&envelope.snapshot)?;
        let manifest = partition_manifest(&partitions)?;
        let full = FullUpload {
            protocol_version: PROTOCOL_V2,
            mode: "full",
            device: envelope.device.clone(),
            generated_at_ms: envelope.generated_at_ms,
            snapshot: envelope.snapshot.clone(),
        };
        let usable = state.filter(|value| {
            value.is_usable_for(envelope, endpoint, collection_days)
                && !full_calibration_due(value, envelope.device.id, now_ms)
        });
        let Some(previous) = usable else {
            return Ok(Self {
                body: V2UploadEnvelope::Full(full.clone()),
                mode: UploadMode::Full,
                manifest,
                full,
                previous_last_full_at_ms: None,
            });
        };

        let (upserts, deletes) = delta(&partitions, &manifest, &previous.manifest);
        let delta = DeltaUpload {
            protocol_version: PROTOCOL_V2,
            mode: "delta",
            device: envelope.device.clone(),
            generated_at_ms: envelope.generated_at_ms,
            base_revision: previous.revision,
            upserts,
            deletes,
        };
        let delta_bytes = serde_json::to_vec(&delta)?.len();
        let full_bytes = serde_json::to_vec(&full)?.len();
        if delta_bytes * 100 >= full_bytes * DELTA_FULL_PERCENT {
            return Ok(Self {
                body: V2UploadEnvelope::Full(full.clone()),
                mode: UploadMode::Full,
                manifest,
                full,
                previous_last_full_at_ms: Some(previous.last_full_at_ms),
            });
        }
        Ok(Self {
            body: V2UploadEnvelope::Delta(delta),
            mode: UploadMode::Delta,
            manifest,
            full,
            previous_last_full_at_ms: Some(previous.last_full_at_ms),
        })
    }

    pub fn force_full(&mut self) {
        self.body = V2UploadEnvelope::Full(self.full.clone());
        self.mode = UploadMode::Full;
    }

    pub fn state_after(
        &self,
        endpoint: String,
        revision: u64,
        collection_days: usize,
        now_ms: i64,
    ) -> Result<IncrementalState> {
        if revision == 0 || now_ms <= 0 {
            bail!("protocol-v2 upload metadata is invalid");
        }
        let last_full_at_ms = match self.mode {
            UploadMode::Full => now_ms,
            UploadMode::Delta => self
                .previous_last_full_at_ms
                .context("incremental state lost its last full calibration")?,
        };
        Ok(IncrementalState {
            state_version: STATE_VERSION,
            endpoint,
            device_id: self.full.device.id,
            revision,
            last_full_at_ms,
            schema_version: self.full.snapshot["schemaVersion"]
                .as_u64()
                .context("snapshot schemaVersion is invalid")?,
            timezone: self.full.snapshot["timezone"]
                .as_str()
                .context("snapshot timezone is invalid")?
                .to_string(),
            collection_days,
            manifest: self.manifest.clone(),
        })
    }
}

fn full_calibration_due(state: &IncrementalState, device_id: Uuid, now_ms: i64) -> bool {
    let digest = Sha256::digest(device_id.as_bytes());
    let jitter = u32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]])
        % FULL_CALIBRATION_JITTER_MS;
    now_ms
        .checked_sub(state.last_full_at_ms)
        .is_none_or(|elapsed| elapsed >= FULL_CALIBRATION_INTERVAL_MS + i64::from(jitter))
}

fn partition_key(kind: &str, identity: &[&str]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(kind.as_bytes());
    for value in identity {
        hasher.update([0]);
        hasher.update(value.as_bytes());
    }
    format!("{kind}:{:x}", hasher.finalize())
}

fn insert_partition(
    partitions: &mut SnapshotPartitions,
    key: String,
    value: Value,
) -> Result<()> {
    if partitions.insert(key, value).is_some() {
        bail!("snapshot contains a duplicate incremental partition");
    }
    if partitions.len() > MAX_PARTITIONS {
        bail!("snapshot contains too many incremental partitions");
    }
    Ok(())
}

fn snapshot_partitions(snapshot: &Value) -> Result<SnapshotPartitions> {
    let object = snapshot.as_object().context("snapshot must be an object")?;
    let mut root = object.clone();
    for key in ["sessions", "days", "sources", "memoryUsage"] {
        root.remove(key);
    }

    let sources = match object.get("sources") {
        None => Value::Null,
        Some(value) => Value::Array(
            value
                .as_array()
                .context("snapshot sources must be an array")?
                .iter()
                .map(|source| {
                    let mut summary = source
                        .as_object()
                        .context("snapshot source must be an object")?
                        .clone();
                    summary.remove("days");
                    Ok(Value::Object(summary))
                })
                .collect::<Result<Vec<_>>>()?,
        ),
    };
    let memory_summary = match object.get("memoryUsage") {
        None => Value::Null,
        Some(value) => {
            let mut summary = value
                .as_object()
                .context("snapshot memoryUsage must be an object")?
                .clone();
            summary.remove("days");
            Value::Object(summary)
        }
    };
    let mut summary = Map::new();
    summary.insert("snapshot".to_string(), Value::Object(root));
    summary.insert("sources".to_string(), sources);
    summary.insert("memoryUsage".to_string(), memory_summary);
    let mut partitions = SnapshotPartitions::new();
    partitions.insert("summary".to_string(), Value::Object(summary));

    for day in object["days"]
        .as_array()
        .context("snapshot days must be an array")?
    {
        let date = day["date"].as_str().context("snapshot day date is invalid")?;
        insert_partition(
            &mut partitions,
            partition_key("day", &[date]),
            day.clone(),
        )?;
    }
    if let Some(sources) = object.get("sources").and_then(Value::as_array) {
        for source in sources {
            let platform = source["platform"]
                .as_str()
                .context("snapshot source platform is invalid")?;
            let days = source["days"]
                .as_array()
                .context("snapshot source days must be an array")?;
            for day in days {
                let date = day["date"]
                    .as_str()
                    .context("snapshot source day date is invalid")?;
                insert_partition(
                    &mut partitions,
                    partition_key("source-day", &[platform, date]),
                    serde_json::json!({"platform": platform, "day": day}),
                )?;
            }
        }
    }
    for session in object["sessions"]
        .as_array()
        .context("snapshot sessions must be an array")?
    {
        let platform = session.get("platform").and_then(Value::as_str).unwrap_or("");
        let id = session["id"]
            .as_str()
            .context("snapshot session id is invalid")?;
        insert_partition(
            &mut partitions,
            partition_key("session", &[platform, id]),
            session.clone(),
        )?;
    }
    if let Some(days) = object
        .get("memoryUsage")
        .and_then(|value| value.get("days"))
        .and_then(Value::as_array)
    {
        for day in days {
            let date = day["date"]
                .as_str()
                .context("snapshot memory day date is invalid")?;
            insert_partition(
                &mut partitions,
                partition_key("memory-day", &[date]),
                day.clone(),
            )?;
        }
    }
    Ok(partitions)
}

fn partition_manifest(partitions: &SnapshotPartitions) -> Result<PartitionManifest> {
    partitions
        .iter()
        .map(|(key, value)| {
            let encoded = serde_json::to_vec(value)?;
            Ok((key.clone(), format!("{:x}", Sha256::digest(encoded))))
        })
        .collect()
}

fn valid_manifest(manifest: &PartitionManifest) -> bool {
    manifest.len() <= MAX_PARTITIONS
        && manifest.iter().all(|(key, digest)| {
            !key.is_empty()
                && key.len() <= 256
                && digest.len() == 64
                && digest.bytes().all(|value| value.is_ascii_hexdigit() && !value.is_ascii_uppercase())
        })
}

fn delta(
    current: &SnapshotPartitions,
    current_manifest: &PartitionManifest,
    previous_manifest: &PartitionManifest,
) -> (SnapshotPartitions, Vec<String>) {
    let upserts = current
        .iter()
        .filter(|(key, _)| previous_manifest.get(*key) != current_manifest.get(*key))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    let deletes = previous_manifest
        .keys()
        .filter(|key| !current_manifest.contains_key(*key))
        .cloned()
        .collect();
    (upserts, deletes)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::protocol::{DeviceOs, PROTOCOL_VERSION};

    fn envelope(generated_at_ms: i64, sessions: usize) -> UploadEnvelope {
        UploadEnvelope {
            protocol_version: PROTOCOL_VERSION,
            device: DeviceDescriptor {
                id: Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap(),
                name: "Windows test".to_string(),
                os: DeviceOs::Windows,
                client_version: None,
            },
            generated_at_ms,
            snapshot: json!({
                "schemaVersion": 9,
                "generatedAtMs": generated_at_ms,
                "timezone": "UTC",
                "today": {},
                "sessions": (0..sessions).map(|index| json!({
                    "id": format!("session-{index}"),
                    "platform": "codex",
                    "padding": "x".repeat(200),
                })).collect::<Vec<_>>(),
                "days": []
            }),
        }
    }

    #[test]
    fn plans_delta_and_forces_periodic_full_without_persisting_payload() {
        let endpoint = "https://sync.example";
        let first = envelope(100, 20);
        let first_plan = IncrementalPlan::build(&first, None, endpoint, 30, 1_000).unwrap();
        assert_eq!(first_plan.mode, UploadMode::Full);
        let state = first_plan
            .state_after(endpoint.to_string(), 1, 30, 1_000)
            .unwrap();
        assert!(!serde_json::to_value(&state).unwrap().to_string().contains("sessions"));

        let second = envelope(101, 19);
        let delta_plan =
            IncrementalPlan::build(&second, Some(&state), endpoint, 30, 2_000).unwrap();
        assert_eq!(delta_plan.mode, UploadMode::Delta);
        let full_plan = IncrementalPlan::build(
            &second,
            Some(&state),
            endpoint,
            30,
            27 * 60 * 60 * 1_000,
        )
        .unwrap();
        assert_eq!(full_plan.mode, UploadMode::Full);
    }

    #[test]
    fn partition_identity_matches_the_cross_platform_contract() {
        assert_eq!(
            partition_key("day", &["2026-08-12"]),
            "day:3005fa68b64e26319d43538b047a5551c335b79681b787d90f713ef0a2079d03"
        );
    }
}
