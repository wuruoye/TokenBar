use std::collections::HashSet;

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use crate::config::tokenbar_sync_device_name;

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_UPLOAD_BYTES: usize = 16 * 1024 * 1024;
const MAX_SNAPSHOT_DEPTH: usize = 100;
const PRIVACY_NULL_FIELDS: [&str; 17] = [
    "promptPreview",
    "outputPreview",
    "sessionPath",
    "title",
    "workspacePath",
    "workspaceLabel",
    "promptText",
    "outputText",
    "rawPrompt",
    "rawOutput",
    "messages",
    "conversation",
    "rawSession",
    "rawSessionFile",
    "sessionFile",
    "sessionContents",
    "cwd",
];
const CREDENTIAL_KEYS: [&str; 21] = [
    "credential",
    "credentials",
    "password",
    "secret",
    "apikey",
    "accesstoken",
    "refreshtoken",
    "authorization",
    "bearertoken",
    "token",
    "authtoken",
    "idtoken",
    "oauthtoken",
    "sessiontoken",
    "providertoken",
    "providercredential",
    "providercredentials",
    "clientsecret",
    "privatekey",
    "cookie",
    "cookies",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DeviceOs {
    Macos,
    Windows,
    Linux,
}

impl DeviceOs {
    pub fn current() -> Result<Self> {
        if cfg!(target_os = "windows") {
            Ok(Self::Windows)
        } else if cfg!(target_os = "linux") {
            Ok(Self::Linux)
        } else if cfg!(target_os = "macos") {
            Ok(Self::Macos)
        } else {
            bail!("unsupported operating system for protocol device.os");
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeviceDescriptor {
    pub id: Uuid,
    pub name: String,
    pub os: DeviceOs,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_version: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UploadEnvelope {
    pub protocol_version: u32,
    pub device: DeviceDescriptor,
    pub generated_at_ms: i64,
    pub snapshot: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DownloadResponse {
    pub protocol_version: u32,
    pub snapshots: Vec<RemoteSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RemoteSnapshot {
    pub device: DeviceDescriptor,
    pub generated_at_ms: i64,
    pub received_at_ms: i64,
    pub snapshot: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SnapshotMetadata {
    pub schema_version: u64,
    pub generated_at_ms: i64,
}

pub fn upload_envelope(snapshot: Value, device: DeviceDescriptor) -> Result<UploadEnvelope> {
    validate_device(&device)?;
    let metadata = validate_snapshot(&snapshot)?;
    let sanitized = sanitize_snapshot(snapshot)?;
    Ok(UploadEnvelope {
        protocol_version: PROTOCOL_VERSION,
        device,
        generated_at_ms: metadata.generated_at_ms,
        snapshot: sanitized,
    })
}

pub fn validate_snapshot(snapshot: &Value) -> Result<SnapshotMetadata> {
    let object = snapshot
        .as_object()
        .context("snapshot must be a JSON object")?;
    let schema_version = object
        .get("schemaVersion")
        .and_then(Value::as_u64)
        .filter(|value| *value > 0)
        .context("snapshot schemaVersion must be positive")?;
    let generated_at_ms = object
        .get("generatedAtMs")
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .context("snapshot generatedAtMs must be positive")?;
    let timezone = object
        .get("timezone")
        .and_then(Value::as_str)
        .filter(|value| {
            !value.trim().is_empty()
                && value.chars().count() <= 128
                && !value.chars().any(char::is_control)
        })
        .context("snapshot timezone must be a nonempty display string")?;
    if timezone != timezone.trim() {
        bail!("snapshot timezone must not have surrounding whitespace");
    }
    if !object.get("today").is_some_and(Value::is_object) {
        bail!("snapshot today must be a JSON object");
    }
    if !object.get("sessions").is_some_and(Value::is_array) {
        bail!("snapshot sessions must be a JSON array");
    }
    if !object.get("days").is_some_and(Value::is_array) {
        bail!("snapshot days must be a JSON array");
    }
    Ok(SnapshotMetadata {
        schema_version,
        generated_at_ms,
    })
}

pub fn validate_upload_envelope(envelope: &UploadEnvelope) -> Result<()> {
    if envelope.protocol_version != PROTOCOL_VERSION {
        bail!("upload protocolVersion must be 1");
    }
    validate_device(&envelope.device)?;
    let metadata = validate_snapshot(&envelope.snapshot)?;
    if envelope.generated_at_ms <= 0 || envelope.generated_at_ms != metadata.generated_at_ms {
        bail!("upload generatedAtMs must be positive and match the snapshot");
    }
    verify_privacy_boundary(&envelope.snapshot, 0)
}

pub fn sanitize_snapshot(mut snapshot: Value) -> Result<Value> {
    if !snapshot.is_object() {
        bail!("snapshot must be a JSON object");
    }
    sanitize_value(&mut snapshot, 0)?;
    verify_privacy_boundary(&snapshot, 0)?;
    Ok(snapshot)
}

pub fn normalize_download(mut response: DownloadResponse) -> Result<DownloadResponse> {
    if response.protocol_version != PROTOCOL_VERSION {
        bail!("download protocolVersion must be 1");
    }
    let mut ids = HashSet::new();
    for item in &mut response.snapshots {
        validate_device(&item.device)?;
        if item.generated_at_ms <= 0 || item.received_at_ms <= 0 {
            bail!("download timestamps must be positive");
        }
        if !ids.insert(item.device.id) {
            bail!("download contains more than one snapshot for a device");
        }
        let metadata = validate_snapshot(&item.snapshot)?;
        if metadata.generated_at_ms != item.generated_at_ms {
            bail!("download generatedAtMs must match the snapshot");
        }
        item.snapshot = sanitize_snapshot(std::mem::take(&mut item.snapshot))?;
    }
    response
        .snapshots
        .sort_by_key(|item| item.device.id.to_string());
    Ok(response)
}

pub fn validate_device(device: &DeviceDescriptor) -> Result<()> {
    if device.id.is_nil() {
        bail!("device id must be a non-nil UUID");
    }
    tokenbar_sync_device_name(&device.name)?;
    if device.client_version.as_ref().is_some_and(|value| {
        value.chars().count() > 80 || value.chars().any(char::is_control)
    }) {
        bail!("device clientVersion must contain at most 80 display characters");
    }
    Ok(())
}

fn sanitize_value(value: &mut Value, depth: usize) -> Result<()> {
    if depth > MAX_SNAPSHOT_DEPTH {
        bail!("snapshot nesting exceeds 100 levels");
    }
    match value {
        Value::Object(map) => {
            let keys = map.keys().cloned().collect::<Vec<_>>();
            for key in keys {
                if is_credential_key(&key) {
                    map.remove(&key);
                    continue;
                }
                let Some(child) = map.get_mut(&key) else {
                    continue;
                };
                if PRIVACY_NULL_FIELDS.contains(&key.as_str()) {
                    *child = Value::Null;
                } else {
                    sanitize_value(child, depth + 1)?;
                }
            }
        }
        Value::Array(values) => {
            for child in values {
                sanitize_value(child, depth + 1)?;
            }
        }
        Value::String(text) if looks_like_absolute_local_path(text) => {
            *value = Value::Null;
        }
        Value::Number(number)
            if number
                .as_u64()
                .is_some_and(|integer| integer > i64::MAX as u64) =>
        {
            bail!("snapshot contains an integer outside the signed 64-bit range");
        }
        _ => {}
    }
    Ok(())
}

fn verify_privacy_boundary(value: &Value, depth: usize) -> Result<()> {
    if depth > MAX_SNAPSHOT_DEPTH {
        bail!("snapshot nesting exceeds 100 levels");
    }
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                if is_credential_key(key) {
                    bail!("sanitization failed for a credential-bearing property");
                }
                if PRIVACY_NULL_FIELDS.contains(&key.as_str()) && !child.is_null() {
                    bail!("sanitization failed for a sensitive ActivitySnapshot field");
                }
                verify_privacy_boundary(child, depth + 1)?;
            }
        }
        Value::Array(values) => {
            for child in values {
                verify_privacy_boundary(child, depth + 1)?;
            }
        }
        Value::String(text) if looks_like_absolute_local_path(text) => {
            bail!("sanitization failed for an absolute local path");
        }
        Value::Number(number)
            if number
                .as_u64()
                .is_some_and(|integer| integer > i64::MAX as u64) =>
        {
            bail!("snapshot contains an integer outside the signed 64-bit range");
        }
        _ => {}
    }
    Ok(())
}

fn is_credential_key(key: &str) -> bool {
    let normalized = key
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .flat_map(char::to_lowercase)
        .collect::<String>();
    CREDENTIAL_KEYS.contains(&normalized.as_str())
}

fn looks_like_absolute_local_path(value: &str) -> bool {
    let bytes = value.as_bytes();
    value.starts_with('/')
        || value.starts_with("\\\\")
        || (bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && matches!(bytes[2], b'/' | b'\\'))
        || value
            .get(..7)
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case("file://"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn recursively_enforces_the_protocol_privacy_boundary() {
        let input = json!({
            "schemaVersion": 91,
            "sessions": [{
                "title": "private title",
                "workspacePath": "C:\\private\\repo",
                "workspaceLabel": "repo",
                "accessToken": "credential",
                "futureAbsolutePath": "D:\\private\\future.json",
                "requests": [{
                    "promptPreview": "private prompt",
                    "outputPreview": "private output",
                    "sessionPath": "C:\\private\\session.jsonl",
                    "contributions": [{
                        "promptPreview": "nested prompt",
                        "outputPreview": "nested output",
                        "sessionPath": "/private/nested.jsonl"
                    }]
                }]
            }]
        });

        let output = sanitize_snapshot(input).unwrap();
        let session = &output["sessions"][0];
        assert!(session["title"].is_null());
        assert!(session["workspacePath"].is_null());
        assert!(session["workspaceLabel"].is_null());
        assert!(session.get("accessToken").is_none());
        assert!(session["futureAbsolutePath"].is_null());
        let request = &session["requests"][0];
        assert!(request["promptPreview"].is_null());
        assert!(request["outputPreview"].is_null());
        assert!(request["sessionPath"].is_null());
        let nested = &request["contributions"][0];
        assert!(nested["promptPreview"].is_null());
        assert!(nested["outputPreview"].is_null());
        assert!(nested["sessionPath"].is_null());
    }

    #[test]
    fn rejects_wide_unsigned_integers() {
        let input = json!({
            "schemaVersion": 91,
            "generatedAtMs": 123,
            "timezone": "UTC",
            "today": {"futureCounter": u64::MAX},
            "sessions": [],
            "days": []
        });
        assert!(sanitize_snapshot(input).is_err());
    }

    #[test]
    fn rejects_non_object_snapshot() {
        assert!(sanitize_snapshot(json!([])).is_err());
    }

    #[test]
    fn envelope_preserves_helper_schema_and_unknown_fields() {
        let device = DeviceDescriptor {
            id: Uuid::new_v4(),
            name: "Test device".to_string(),
            os: DeviceOs::Windows,
            client_version: None,
        };
        let envelope = upload_envelope(
            json!({
                "schemaVersion": 91,
                "generatedAtMs": 123,
                "timezone": "UTC",
                "today": {},
                "sessions": [],
                "days": [],
                "futureSchemaField": {"value": true}
            }),
            device,
        )
        .unwrap();

        assert_eq!(envelope.generated_at_ms, 123);
        assert_eq!(envelope.snapshot["schemaVersion"], 91);
        assert_eq!(envelope.snapshot["futureSchemaField"]["value"], true);
    }

    #[test]
    fn rejects_snapshots_missing_required_activity_shape() {
        let base = json!({
            "schemaVersion": 91,
            "generatedAtMs": 123,
            "timezone": "UTC",
            "today": {},
            "sessions": [],
            "days": []
        });
        assert!(validate_snapshot(&base).is_ok());
        for field in [
            "schemaVersion",
            "generatedAtMs",
            "timezone",
            "today",
            "sessions",
            "days",
        ] {
            let mut invalid = base.clone();
            invalid.as_object_mut().unwrap().remove(field);
            assert!(
                validate_snapshot(&invalid).is_err(),
                "accepted missing {field}"
            );
        }
    }
}
