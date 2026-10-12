use std::collections::HashSet;

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use crate::config::tokenbar_sync_device_name;

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_UPLOAD_BYTES: usize = 16 * 1024 * 1024;
const MAX_SNAPSHOT_DEPTH: usize = 100;
const PRIVACY_NULL_FIELDS: [&str; 16] = [
    "promptPreview",
    "outputPreview",
    "sessionPath",
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
            let is_session = is_activity_session(map);
            let keys = map.keys().cloned().collect::<Vec<_>>();
            for key in keys {
                if is_credential_key(&key) {
                    map.remove(&key);
                    continue;
                }
                let Some(child) = map.get_mut(&key) else {
                    continue;
                };
                if key == "title" && is_session {
                    if !is_valid_session_title(child) {
                        *child = Value::Null;
                    }
                } else if key == "title" || PRIVACY_NULL_FIELDS.contains(&key.as_str()) {
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
            let is_session = is_activity_session(map);
            for (key, child) in map {
                if is_credential_key(key) {
                    bail!("sanitization failed for a credential-bearing property");
                }
                if key == "title" && is_session {
                    if !child.is_null() && !is_valid_session_title(child) {
                        bail!("sanitization failed for a session title");
                    }
                } else if (key == "title" || PRIVACY_NULL_FIELDS.contains(&key.as_str()))
                    && !child.is_null()
                {
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

fn is_activity_session(map: &serde_json::Map<String, Value>) -> bool {
    ["id", "startedAtMs", "endedAtMs", "tokens", "models", "requests"]
        .iter()
        .all(|key| map.contains_key(*key))
}

fn is_valid_session_title(value: &Value) -> bool {
    value.as_str().is_some_and(|title| {
        !title.is_empty()
            && title.len() <= 512
            && !title.bytes().any(|byte| byte < 0x20 || byte == 0x7f)
    })
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
