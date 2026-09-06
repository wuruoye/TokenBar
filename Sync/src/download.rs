//! Materialized remote snapshots and opaque server manifests, matching the macOS v2 client.
use crate::{
    incremental::{
        partition_key, snapshot_partitions, valid_manifest, PartitionManifest, SnapshotPartitions,
    },
    protocol::{normalize_download, DownloadResponse, RemoteSnapshot},
};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

const MAX_PARTITIONS: usize = 100_000;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CachedRemote {
    #[serde(flatten)]
    pub record: RemoteSnapshot,
    pub revision: u64,
    pub manifest: PartitionManifest,
    pub digest: String,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadState {
    pub last_full_at_ms: Option<i64>,
    pub remotes: Vec<CachedRemote>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KnownSnapshot {
    device_id: Uuid,
    revision: u64,
    manifest: PartitionManifest,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryRequest {
    protocol_version: u32,
    known: Vec<KnownSnapshot>,
    pub force_full: bool,
    exclude_device_id: Uuid,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotChange {
    mode: String,
    device: crate::protocol::DeviceDescriptor,
    generated_at_ms: i64,
    received_at_ms: i64,
    revision: u64,
    manifest: PartitionManifest,
    snapshot: Option<Value>,
    upserts: Option<SnapshotPartitions>,
    deletes: Option<Vec<String>>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryResponse {
    protocol_version: u32,
    snapshots: Vec<SnapshotChange>,
    deleted_device_ids: Vec<Uuid>,
}

fn digest(value: &Value) -> Result<String> {
    Ok(format!("{:x}", Sha256::digest(serde_json::to_vec(value)?)))
}
fn validate_record(record: RemoteSnapshot) -> Result<RemoteSnapshot> {
    let response = normalize_download(DownloadResponse {
        protocol_version: 1,
        snapshots: vec![record],
    })?;
    response
        .snapshots
        .into_iter()
        .next()
        .context("missing snapshot")
}
fn matching_keys(snapshot: &Value, manifest: &PartitionManifest) -> Result<bool> {
    Ok(snapshot_partitions(snapshot)?.keys().eq(manifest.keys()))
}

impl DownloadState {
    pub fn validated(mut self, local_id: Uuid) -> Self {
        let mut ids = BTreeSet::new();
        self.remotes.retain(|entry| {
            entry.record.device.id != local_id
                && ids.insert(entry.record.device.id)
                && entry.revision > 0
                && valid_manifest(&entry.manifest)
                && digest(&entry.record.snapshot).is_ok_and(|v| v == entry.digest)
                && validate_record(entry.record.clone()).is_ok()
                && matching_keys(&entry.record.snapshot, &entry.manifest).unwrap_or(false)
        });
        self
    }
    pub fn query(&self, local_id: Uuid, now_ms: i64, force: bool) -> QueryRequest {
        let hash = Sha256::digest(local_id.as_bytes());
        let jitter = u32::from_be_bytes([hash[0], hash[1], hash[2], hash[3]]) % 3_600_000;
        let due = self
            .last_full_at_ms
            .and_then(|last| now_ms.checked_sub(last))
            .is_none_or(|elapsed| elapsed < 0 || elapsed >= 86_400_000 + i64::from(jitter));
        QueryRequest {
            protocol_version: 2,
            force_full: force || due,
            exclude_device_id: local_id,
            known: self
                .remotes
                .iter()
                .map(|e| KnownSnapshot {
                    device_id: e.record.device.id,
                    revision: e.revision,
                    manifest: e.manifest.clone(),
                })
                .collect(),
        }
    }
    pub fn apply(
        &self,
        response: QueryResponse,
        local_id: Uuid,
        force_full: bool,
        now_ms: i64,
    ) -> Result<Self> {
        if response.protocol_version != 2
            || response.snapshots.len() > 10000
            || response.deleted_device_ids.len() > 10000
        {
            bail!("invalid incremental response");
        }
        let mut entries: BTreeMap<_, _> = if force_full {
            BTreeMap::new()
        } else {
            self.remotes
                .iter()
                .map(|entry| (entry.record.device.id, entry.clone()))
                .collect()
        };
        let mut changed = BTreeSet::new();
        for id in response.deleted_device_ids {
            if id == local_id || !changed.insert(id) {
                bail!("invalid deleted device");
            }
            entries.remove(&id);
        }
        for change in response.snapshots {
            let id = change.device.id;
            if id == local_id
                || !changed.insert(id)
                || change.revision == 0
                || !valid_manifest(&change.manifest)
            {
                bail!("invalid changed device");
            }
            let snapshot = match change.mode.as_str() {
                "full" if change.upserts.is_none() && change.deletes.is_none() => {
                    change.snapshot.context("missing full snapshot")?
                }
                "delta" if !force_full && change.snapshot.is_none() => {
                    let previous = entries.get(&id).context("delta has no cached base")?;
                    if change.revision <= previous.revision
                        || change.generated_at_ms < previous.record.generated_at_ms
                    {
                        bail!("stale incremental response");
                    }
                    let upserts = change.upserts.context("missing upserts")?;
                    let deletes = change.deletes.context("missing deletes")?;
                    if upserts.len() > MAX_PARTITIONS || deletes.len() > MAX_PARTITIONS {
                        bail!("too many changes");
                    }
                    let unique: BTreeSet<_> = deletes.iter().collect();
                    if unique.len() != deletes.len()
                        || deletes.iter().any(|k| upserts.contains_key(k))
                    {
                        bail!("conflicting partition changes");
                    }
                    let mut partitions = snapshot_partitions(&previous.record.snapshot)?;
                    for key in deletes {
                        partitions.remove(&key);
                    }
                    partitions.extend(upserts);
                    materialize(partitions)?
                }
                _ => bail!("invalid snapshot mode"),
            };
            let record = validate_record(RemoteSnapshot {
                device: change.device,
                generated_at_ms: change.generated_at_ms,
                received_at_ms: change.received_at_ms,
                snapshot,
            })?;
            if !matching_keys(&record.snapshot, &change.manifest)? {
                bail!("partition manifest does not converge");
            }
            entries.insert(
                id,
                CachedRemote {
                    digest: digest(&record.snapshot)?,
                    record,
                    revision: change.revision,
                    manifest: change.manifest,
                },
            );
        }
        Ok(Self {
            last_full_at_ms: if force_full {
                Some(now_ms)
            } else {
                self.last_full_at_ms
            },
            remotes: entries.into_values().collect(),
        })
    }
    pub fn records(&self) -> Vec<RemoteSnapshot> {
        self.remotes.iter().map(|e| e.record.clone()).collect()
    }
}

fn materialize(mut partitions: SnapshotPartitions) -> Result<Value> {
    if partitions.len() > MAX_PARTITIONS {
        bail!("too many partitions");
    }
    let summary = partitions.remove("summary").context("missing summary")?;
    let summary = summary.as_object().context("invalid summary")?;
    if summary.len() != 3 {
        bail!("invalid summary fields");
    }
    let mut root = summary
        .get("snapshot")
        .and_then(Value::as_object)
        .context("invalid root summary")?
        .clone();
    if ["sessions", "days", "sources", "memoryUsage"]
        .iter()
        .any(|k| root.contains_key(*k))
    {
        bail!("split fields in summary");
    }
    let mut days = vec![];
    let mut sessions = vec![];
    let mut memory_days = vec![];
    let mut source_days = BTreeMap::<String, Vec<Value>>::new();
    for (key, value) in partitions {
        if key.starts_with("day:") {
            let date = value["date"].as_str().context("invalid day identity")?;
            if key != partition_key("day", &[date]) {
                bail!("day key mismatch");
            }
            days.push(value);
        } else if key.starts_with("session:") {
            let id = value["id"].as_str().context("invalid session identity")?;
            let platform = value["platform"].as_str().unwrap_or("");
            if key != partition_key("session", &[platform, id]) {
                bail!("session key mismatch");
            }
            sessions.push(value);
        } else if key.starts_with("source-day:") {
            let object = value.as_object().context("invalid source day")?;
            if object.len() != 2 {
                bail!("invalid source day fields");
            }
            let platform = value["platform"].as_str().context("invalid platform")?;
            let date = value["day"]["date"]
                .as_str()
                .context("invalid source day identity")?;
            if key != partition_key("source-day", &[platform, date]) {
                bail!("source day key mismatch");
            }
            source_days
                .entry(platform.into())
                .or_default()
                .push(value["day"].clone());
        } else if key.starts_with("memory-day:") {
            let date = value["date"]
                .as_str()
                .context("invalid memory day identity")?;
            if key != partition_key("memory-day", &[date]) {
                bail!("memory day key mismatch");
            }
            memory_days.push(value);
        } else {
            bail!("unknown partition kind");
        }
    }
    fn sort_days(days: &mut [Value]) {
        days.sort_by(|a, b| a["date"].as_str().cmp(&b["date"].as_str()));
    }
    sort_days(&mut days);
    sort_days(&mut memory_days);
    sessions.sort_by(|a, b| {
        b["endedAtMs"]
            .as_i64()
            .cmp(&a["endedAtMs"].as_i64())
            .then_with(|| a["id"].as_str().cmp(&b["id"].as_str()))
    });
    root.insert("days".into(), json!(days));
    root.insert("sessions".into(), json!(sessions));
    match summary.get("sources") {
        Some(Value::Array(summaries)) => {
            let mut sources = vec![];
            let mut seen = BTreeSet::new();
            for value in summaries {
                let mut source = value.as_object().context("invalid source")?.clone();
                let platform = source
                    .get("platform")
                    .and_then(Value::as_str)
                    .context("missing platform")?
                    .to_string();
                if source.contains_key("days") || !seen.insert(platform.clone()) {
                    bail!("invalid source summary");
                }
                let mut days = source_days.remove(&platform).unwrap_or_default();
                sort_days(&mut days);
                source.insert("days".into(), json!(days));
                sources.push(Value::Object(source));
            }
            root.insert("sources".into(), json!(sources));
        }
        Some(Value::Null) => {}
        _ => bail!("invalid sources summary"),
    }
    if !source_days.is_empty() {
        bail!("orphan source day");
    }
    match summary.get("memoryUsage") {
        Some(Value::Object(memory)) if !memory.contains_key("days") => {
            let mut memory = memory.clone();
            memory.insert("days".into(), json!(memory_days));
            root.insert("memoryUsage".into(), json!(memory));
        }
        Some(Value::Null) if memory_days.is_empty() => {}
        _ => bail!("invalid memory summary"),
    }
    Ok(Value::Object(root))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn snapshot(at: i64, output: i64) -> Value {
        json!({"schemaVersion":11,"generatedAtMs":at,"timezone":"UTC","today":{"costUsd":1},
            "days":[{"date":"2026-09-06","tokens":{"output":output}}],"sessions":[]})
    }
    fn manifest(snapshot: &Value) -> PartitionManifest {
        snapshot_partitions(snapshot)
            .unwrap()
            .into_keys()
            .map(|key| (key, "a".repeat(64)))
            .collect()
    }
    fn full(snapshot: Value, revision: u64) -> QueryResponse {
        serde_json::from_value(
            json!({"protocolVersion":2,"deletedDeviceIds":[],"snapshots":[{
                "mode":"full","device":{"id":Uuid::from_u128(2),"name":"Mac","os":"macos"},
                "generatedAtMs":snapshot["generatedAtMs"],"receivedAtMs":3000,"revision":revision,
                "manifest":manifest(&snapshot),"snapshot":snapshot
            }]}),
        )
        .unwrap()
    }
    #[test]
    fn replaces_partitions_without_adding_counters_and_preserves_opaque_manifests() {
        let local = Uuid::from_u128(1);
        let old = snapshot(1000, 10);
        let state = DownloadState::default()
            .apply(full(old, 1), local, true, 4000)
            .unwrap();
        let next = snapshot(2000, 15);
        let response = serde_json::from_value(json!({"protocolVersion":2,"deletedDeviceIds":[],"snapshots":[{
            "mode":"delta","device":{"id":Uuid::from_u128(2),"name":"Mac","os":"macos"},
            "generatedAtMs":2000,"receivedAtMs":3000,"revision":2,
            "manifest":manifest(&next),"upserts":snapshot_partitions(&next).unwrap(),"deletes":[]
        }]})).unwrap();
        let replaced = state.apply(response, local, false, 5000).unwrap();
        assert_eq!(
            replaced.records()[0].snapshot["days"][0]["tokens"]["output"],
            15
        );
        assert_eq!(
            state.records()[0].snapshot["days"][0]["tokens"]["output"],
            10
        );
        let query = serde_json::to_value(replaced.query(local, 5001, false)).unwrap();
        assert_eq!(query["known"][0]["manifest"]["summary"], "a".repeat(64));
        assert_eq!(query["forceFull"], false);
        let unchanged = serde_json::from_value(
            json!({"protocolVersion":2,"snapshots":[],"deletedDeviceIds":[]}),
        )
        .unwrap();
        assert_eq!(
            replaced
                .apply(unchanged, local, false, 6000)
                .unwrap()
                .records()
                .len(),
            1
        );
        let deletion = serde_json::from_value(
            json!({"protocolVersion":2,"snapshots":[],"deletedDeviceIds":[Uuid::from_u128(2)]}),
        )
        .unwrap();
        assert!(replaced
            .apply(deletion, local, false, 6000)
            .unwrap()
            .records()
            .is_empty());
    }
    #[test]
    fn rejects_bad_deltas_and_discards_tampered_cached_snapshots() {
        let local = Uuid::from_u128(1);
        let mut state = DownloadState::default()
            .apply(full(snapshot(1000, 10), 1), local, true, 4000)
            .unwrap();
        let mut response = full(snapshot(2000, 20), 2);
        response.snapshots[0].manifest.clear();
        assert!(state.apply(response, local, false, 5000).is_err());
        state.remotes[0].record.snapshot["today"]["costUsd"] = json!(999);
        assert!(state.validated(local).remotes.is_empty());
        let mut partitions = snapshot_partitions(&snapshot(1000, 10)).unwrap();
        partitions.insert(
            partition_key("day", &["wrong-date"]),
            json!({"date":"2026-09-06"}),
        );
        assert!(materialize(partitions).is_err());
    }
    #[test]
    fn calibration_and_deleted_partitions_match_mac_rules() {
        let local = Uuid::from_u128(1);
        let state = DownloadState::default()
            .apply(full(snapshot(1000, 10), 1), local, true, 4000)
            .unwrap();
        assert!(state.query(local, 4000 + 26 * 3600000, false).force_full);
        let mut next = snapshot(2000, 0);
        next["days"] = json!([]);
        let response = serde_json::from_value(
            json!({"protocolVersion":2,"deletedDeviceIds":[],"snapshots":[{
                "mode":"delta","device":{"id":Uuid::from_u128(2),"name":"Mac","os":"macos"},
                "generatedAtMs":2000,"receivedAtMs":3000,"revision":2,"manifest":manifest(&next),
                "upserts":{"summary":snapshot_partitions(&next).unwrap()["summary"]},
                "deletes":[partition_key("day", &["2026-09-06"])]
            }]}),
        )
        .unwrap();
        assert_eq!(
            state.apply(response, local, false, 5000).unwrap().records()[0].snapshot["days"],
            json!([])
        );
    }
}
