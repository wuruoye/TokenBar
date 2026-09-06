//! Independent upload/download outcomes and encrypted, endpoint-scoped sync state.
use crate::{
    settings::Settings,
    sync::{crypt, Remote},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{fs, io::Write, path::Path};
use tokenbar_helper::ActivitySnapshot;
use tokenbar_sync::{
    device,
    download::DownloadState,
    incremental::{IncrementalPlan, IncrementalState, UploadMode},
    protocol::{self, DeviceDescriptor, DeviceOs, RemoteSnapshot},
    sync_client::{Endpoint, SyncClient, SyncError},
};
use zeroize::Zeroizing;

const MAX_CACHE: u64 = 64 * 1024 * 1024;
const CACHE_FILE: &str = "sync-state.protected";
#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Cache {
    version: u32,
    endpoint: String,
    device_id: String,
    credential_fingerprint: String,
    upload: Option<IncrementalState>,
    download: DownloadState,
    legacy: bool,
    legacy_remotes: Vec<RemoteSnapshot>,
}
impl Cache {
    fn records(&self) -> Vec<RemoteSnapshot> {
        if self.legacy {
            self.legacy_remotes.clone()
        } else {
            self.download.records()
        }
    }
}
pub struct Outcome {
    pub remotes: Vec<Remote>,
    pub status: String,
}

fn read_token(dir: &Path) -> Result<Zeroizing<Vec<u8>>, String> {
    let path = dir.join("sync-token.protected");
    if fs::metadata(&path)
        .map_err(|_| "请在设置中填写同步访问令牌。")?
        .len()
        > 65536
    {
        return Err("同步凭据大小无效。".into());
    }
    let protected = fs::read(path).map_err(|_| "无法读取同步凭据。")?;
    let token = Zeroizing::new(crypt(&protected, false)?);
    if !(32..=512).contains(&token.len())
        || !token.is_ascii()
        || token
            .iter()
            .any(|c| c.is_ascii_whitespace() || c.is_ascii_control())
    {
        return Err("同步凭据无效。".into());
    }
    Ok(token)
}
fn load(dir: &Path, endpoint: &str, local: &device::DeviceState, fingerprint: &str) -> Cache {
    let valid = || -> Option<Cache> {
        let path = dir.join(CACHE_FILE);
        if fs::metadata(&path).ok()?.len() > MAX_CACHE + 65536 {
            return None;
        }
        let bytes = Zeroizing::new(crypt(&fs::read(path).ok()?, false).ok()?);
        if bytes.len() > MAX_CACHE as usize {
            return None;
        }
        let mut value: Cache = serde_json::from_slice(&bytes).ok()?;
        if value.version != 1
            || value.endpoint != endpoint
            || value.device_id != local.id.to_string()
            || value.credential_fingerprint != fingerprint
        {
            return None;
        }
        value.download = value.download.validated(local.id);
        if value.legacy {
            value.legacy_remotes = protocol::normalize_download(protocol::DownloadResponse {
                protocol_version: 1,
                snapshots: value.legacy_remotes,
            })
            .ok()?
            .snapshots;
            value.legacy_remotes.retain(|r| r.device.id != local.id);
        }
        Some(value)
    };
    valid().unwrap_or_else(|| Cache {
        version: 1,
        endpoint: endpoint.into(),
        device_id: local.id.to_string(),
        credential_fingerprint: fingerprint.into(),
        ..Default::default()
    })
}
fn save(dir: &Path, cache: &Cache) -> Result<(), String> {
    let bytes = Zeroizing::new(serde_json::to_vec(cache).map_err(|_| "无法编码同步缓存。")?);
    if bytes.len() > MAX_CACHE as usize {
        return Err("同步缓存超过 64 MiB。".into());
    }
    let protected = crypt(&bytes, true)?;
    let temp = dir.join(format!(
        "sync-state.{}.{}.tmp",
        std::process::id(),
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default()
    ));
    let result = (|| -> std::io::Result<()> {
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temp)?;
        file.write_all(&protected)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temp, dir.join(CACHE_FILE))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result.map_err(|_| "无法保存同步缓存，下次会重新完整同步。".into())
}
fn visible(records: Vec<RemoteSnapshot>) -> Vec<Remote> {
    records
        .into_iter()
        .filter_map(|row| {
            let snapshot: ActivitySnapshot = serde_json::from_value(row.snapshot).ok()?;
            (snapshot.schema_version > 0 && snapshot.timezone == "UTC").then(|| Remote {
                device_id: row.device.id.to_string(),
                device_name: row.device.name,
                snapshot,
            })
        })
        .collect()
}
pub fn cached_remotes(dir: &Path, settings: &Settings) -> Vec<Remote> {
    if !settings.sync_enabled {
        return vec![];
    }
    let Ok(token) = read_token(dir) else {
        return vec![];
    };
    let Ok(local) = device::load_or_create(dir) else {
        return vec![];
    };
    let Ok(endpoint) = Endpoint::parse(&settings.sync_endpoint) else {
        return vec![];
    };
    let fingerprint = format!("{:x}", Sha256::digest(&token));
    visible(load(dir, &endpoint.state_key(), &local, &fingerprint).records())
}

pub fn round(
    dir: &Path,
    settings: &Settings,
    snapshot: Option<&ActivitySnapshot>,
) -> Result<Outcome, String> {
    crate::diagnostics::record("sync-stage", serde_json::json!({"stage":"start"}));
    let bytes = read_token(dir)?;
    let token = std::str::from_utf8(&bytes).map_err(|_| "同步凭据无效。")?;
    let local = device::load_or_create(dir).map_err(|_| "无法读取本机设备标识。")?;
    let endpoint = Endpoint::parse(&settings.sync_endpoint).map_err(|e| e.to_string())?;
    let endpoint_key = endpoint.state_key();
    let fingerprint = format!("{:x}", Sha256::digest(&bytes));
    let client = SyncClient::new(endpoint).map_err(|e| e.to_string())?;
    let mut cache = load(dir, &endpoint_key, &local, &fingerprint);
    crate::diagnostics::record("sync-stage", serde_json::json!({
        "stage":"client-ready", "hasSnapshot":snapshot.is_some(),
    }));
    let now = chrono::Utc::now().timestamp_millis();
    let descriptor = DeviceDescriptor {
        id: local.id,
        name: settings.sync_device_name.clone(),
        os: DeviceOs::Windows,
        client_version: Some(env!("CARGO_PKG_VERSION").into()),
    };
    let mut legacy = false;
    let mut transport = "skipped";
    let upload = snapshot.map(|snapshot| -> Result<(), String> {
        // Always receives the fresh local helper snapshot; merged display data is never uploaded.
        let envelope = protocol::upload_envelope(
            serde_json::to_value(snapshot).map_err(|_| "无法编码统计数据。")?,
            descriptor,
        )
        .map_err(|_| "本机统计未通过同步校验。")?;
        let mut plan =
            IncrementalPlan::build(&envelope, cache.upload.as_ref(), &endpoint_key, 30, now)
                .map_err(|_| "无法准备上传记录。")?;
        crate::diagnostics::record("sync-stage", serde_json::json!({
            "stage":"upload-start", "mode":plan.mode.label(),
        }));
        let mut uploaded = client.upload_v2(token, &plan.body);
        crate::diagnostics::record("sync-stage", serde_json::json!({
            "stage":"upload-returned", "ok":uploaded.is_ok(),
        }));
        if matches!(uploaded, Err(SyncError::Conflict)) && plan.mode == UploadMode::Delta {
            plan.force_full();
            crate::diagnostics::record("sync-stage", serde_json::json!({
                "stage":"upload-retry-full",
            }));
            uploaded = client.upload_v2(token, &plan.body);
            crate::diagnostics::record("sync-stage", serde_json::json!({
                "stage":"upload-retry-returned", "ok":uploaded.is_ok(),
            }));
        }
        match uploaded {
            Ok(result) => {
                transport = plan.mode.label();
                cache.upload = Some(
                    plan.state_after(endpoint_key.clone(), result.revision, 30, now)
                        .map_err(|_| "上传成功，但校验信息无效。")?,
                );
                Ok(())
            }
            Err(SyncError::Http(404)) => {
                legacy = true;
                transport = "v1-full";
                cache.upload = None;
                client
                    .upload(token, &envelope)
                    .map(|_| ())
                    .map_err(|e| e.to_string())
            }
            Err(error) => Err(error.to_string()),
        }
    });
    let mut download_mode = "v2";
    let download = (|| -> Result<(), String> {
        crate::diagnostics::record("sync-stage", serde_json::json!({"stage":"download-start"}));
        if !legacy {
            let query = cache.download.query(local.id, now, false);
            match client.query_v2(token, &query) {
                Ok(response) => {
                    crate::diagnostics::record("sync-stage", serde_json::json!({"stage":"download-returned"}));
                    let applied = cache
                        .download
                        .apply(response, local.id, query.force_full, now);
                    let next = match applied {
                        Ok(next) => next,
                        Err(_) if !query.force_full => {
                            crate::diagnostics::record("sync-stage", serde_json::json!({
                                "stage":"download-retry-full",
                            }));
                            let query = cache.download.query(local.id, now, true);
                            let full = client.query_v2(token, &query).map_err(|e| e.to_string())?;
                            cache
                                .download
                                .apply(full, local.id, true, now)
                                .map_err(|_| "完整下载记录校验失败。")?
                        }
                        Err(_) => return Err("下载记录校验失败。".into()),
                    };
                    cache.download = next;
                    cache.legacy = false;
                    cache.legacy_remotes.clear();
                    return Ok(());
                }
                Err(SyncError::Http(404)) => {}
                Err(SyncError::InvalidV2Response) if !query.force_full => {
                    crate::diagnostics::record("sync-stage", serde_json::json!({
                        "stage":"download-invalid-retry-full",
                    }));
                    let full_query = cache.download.query(local.id, now, true);
                    let full = client
                        .query_v2(token, &full_query)
                        .map_err(|e| e.to_string())?;
                    cache.download = cache
                        .download
                        .apply(full, local.id, true, now)
                        .map_err(|_| "完整下载记录校验失败。")?;
                    cache.legacy = false;
                    cache.legacy_remotes.clear();
                    return Ok(());
                }
                Err(error) => return Err(error.to_string()),
            }
        }
        download_mode = "v1";
        let response = client.download(token).map_err(|e| e.to_string())?;
        cache.legacy = true;
        cache.legacy_remotes = response
            .snapshots
            .into_iter()
            .filter(|row| row.device.id != local.id)
            .collect();
        cache.download = DownloadState::default();
        Ok(())
    })();
    let remotes = visible(cache.records());
    let mut messages = vec![
        match &upload {
            Some(Ok(())) => "上传成功".into(),
            Some(Err(error)) => format!("上传失败：{error}"),
            None => "本机统计未就绪，已跳过上传".into(),
        },
        match &download {
            Ok(()) => format!("下载成功 · {} 台其他设备", remotes.len()),
            Err(error) => format!("下载失败：{error} · 保留上次记录"),
        },
    ];
    if let Err(error) = save(dir, &cache) {
        messages.push(error);
    }
    crate::diagnostics::record("sync-stage", serde_json::json!({"stage":"cache-saved"}));
    crate::diagnostics::record(
        "sync-finished",
        serde_json::json!({"uploadSuccess":upload.as_ref().map(|r|r.is_ok()),
        "downloadSuccess":download.is_ok(),"uploadTransport":transport,"downloadTransport":download_mode,"remoteDevices":remotes.len()}),
    );
    Ok(Outcome {
        remotes,
        status: messages.join(" · "),
    })
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;
    use serde_json::{json, Value};
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
        time::Duration,
    };

    fn snapshot(at: i64) -> ActivitySnapshot {
        tokenbar_helper::build_snapshot(
            vec![],
            chrono::NaiveDate::from_ymd_opt(2026, 9, 6).unwrap(),
            at,
            "UTC".into(),
            30,
        )
        .unwrap()
    }
    fn server(responses: Vec<(u16, Value)>) -> (String, thread::JoinHandle<Vec<(String, Value)>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let handle = thread::spawn(move || {
            let mut requests = vec![];
            for (status, body) in responses {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut data = Vec::new();
                let mut buffer = [0u8; 4096];
                let header_end = loop {
                    let n = stream.read(&mut buffer).unwrap();
                    assert!(n > 0);
                    data.extend_from_slice(&buffer[..n]);
                    if let Some(index) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                        break index + 4;
                    }
                };
                let headers = String::from_utf8_lossy(&data[..header_end]).to_string();
                assert!(headers
                    .to_lowercase()
                    .contains("authorization: bearer test-only-sync-credential-1234567890"));
                let length = headers
                    .lines()
                    .find_map(|line| {
                        line.to_lowercase()
                            .strip_prefix("content-length:")
                            .map(|v| v.trim().parse::<usize>().unwrap())
                    })
                    .unwrap_or(0);
                while data.len() < header_end + length {
                    let n = stream.read(&mut buffer).unwrap();
                    assert!(n > 0);
                    data.extend_from_slice(&buffer[..n]);
                }
                let payload = if length == 0 {
                    Value::Null
                } else {
                    serde_json::from_slice(&data[header_end..header_end + length]).unwrap()
                };
                requests.push((headers.lines().next().unwrap().to_string(), payload));
                let encoded = serde_json::to_vec(&body).unwrap();
                write!(stream,"HTTP/1.1 {status} Test\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",encoded.len()).unwrap();
                stream.write_all(&encoded).unwrap();
            }
            requests
        });
        (endpoint, handle)
    }
    #[test]
    fn sync_round_keeps_download_independent_and_restores_encrypted_cache() {
        let dir = tempfile::tempdir().unwrap();
        let remote_dir = tempfile::tempdir().unwrap();
        let local = device::load_or_create(dir.path()).unwrap();
        let remote = device::load_or_create(remote_dir.path()).unwrap();
        let descriptor = DeviceDescriptor {
            id: remote.id,
            name: "Remote Mac integration fixture".into(),
            os: DeviceOs::Macos,
            client_version: None,
        };
        let envelope = protocol::upload_envelope(
            serde_json::to_value(snapshot(2000)).unwrap(),
            descriptor.clone(),
        )
        .unwrap();
        let manifest = IncrementalPlan::build(&envelope, None, "test", 30, 3000)
            .unwrap()
            .state_after("test".into(), 1, 30, 3000)
            .unwrap()
            .manifest;
        let full = json!({"protocolVersion":2,"deletedDeviceIds":[],"snapshots":[{"mode":"full","device":descriptor,
            "generatedAtMs":2000,"receivedAtMs":3000,"revision":1,"manifest":manifest,"snapshot":envelope.snapshot}]});
        let uploaded = |revision| json!({"protocolVersion":2,"revision":revision,"status":"updated","receivedAtMs":3000});
        let (endpoint, thread) = server(vec![
            (200, uploaded(1)),
            (200, full.clone()),
            (409, json!({})),
            (200, uploaded(2)),
            (
                200,
                json!({"protocolVersion":2,"snapshots":[],"deletedDeviceIds":[]}),
            ),
            (500, json!({})),
            (200, json!({})),
            (200, full),
            (500, json!({})),
        ]);
        let settings = Settings {
            sync_enabled: true,
            sync_endpoint: endpoint,
            sync_device_name: "Local fixture".into(),
            ..Settings::default()
        };
        crate::sync::save_token(dir.path(), "test-only-sync-credential-1234567890".into()).unwrap();
        let first = round(dir.path(), &settings, Some(&snapshot(1000))).unwrap();
        assert_eq!(first.remotes.len(), 1);
        let second = round(dir.path(), &settings, Some(&snapshot(1001))).unwrap();
        assert_eq!(second.remotes.len(), 1);
        let partial = round(dir.path(), &settings, Some(&snapshot(1002))).unwrap();
        assert!(partial.status.contains("上传失败"));
        assert!(partial.status.contains("下载成功"));
        let offline = round(dir.path(), &settings, None).unwrap();
        assert_eq!(offline.remotes.len(), 1);
        assert!(offline.status.contains("保留上次"));
        assert_eq!(cached_remotes(dir.path(), &settings).len(), 1);
        let mut encrypted = fs::read(dir.path().join(CACHE_FILE)).unwrap();
        assert!(!encrypted
            .windows(b"Remote Mac integration fixture".len())
            .any(|v| v == b"Remote Mac integration fixture"));
        let middle = encrypted.len() / 2;
        encrypted[middle] ^= 1;
        fs::write(dir.path().join(CACHE_FILE), encrypted).unwrap();
        assert!(cached_remotes(dir.path(), &settings).is_empty());
        let requests = thread.join().unwrap();
        assert_eq!(requests[0].1["mode"], "full");
        assert_eq!(requests[0].1["device"]["id"], local.id.to_string());
        assert_eq!(requests[1].1["excludeDeviceId"], local.id.to_string());
        assert_eq!(requests[2].1["mode"], "delta");
        assert_eq!(requests[3].1["mode"], "full");
        assert_eq!(requests[4].1["known"][0]["revision"], 1);
        assert_eq!(requests[7].1["forceFull"], true);
    }
    #[test]
    fn falls_back_to_v1_and_scopes_cache_to_credentials() {
        let dir = tempfile::tempdir().unwrap();
        let remote_dir = tempfile::tempdir().unwrap();
        let id = device::load_or_create(remote_dir.path()).unwrap().id;
        let record = RemoteSnapshot {
            device: DeviceDescriptor {
                id,
                name: "Mac".into(),
                os: DeviceOs::Macos,
                client_version: None,
            },
            generated_at_ms: 2000,
            received_at_ms: 3000,
            snapshot: serde_json::to_value(snapshot(2000)).unwrap(),
        };
        let (endpoint, thread) = server(vec![
            (404, json!({})),
            (200, json!({})),
            (200, json!({"protocolVersion":1,"snapshots":[record]})),
        ]);
        let settings = Settings {
            sync_enabled: true,
            sync_endpoint: endpoint,
            sync_device_name: "Local fixture".into(),
            ..Settings::default()
        };
        crate::sync::save_token(dir.path(), "test-only-sync-credential-1234567890".into()).unwrap();
        assert_eq!(
            round(dir.path(), &settings, Some(&snapshot(1000)))
                .unwrap()
                .remotes
                .len(),
            1
        );
        crate::sync::save_token(dir.path(), "different-sync-credential-1234567890".into()).unwrap();
        assert!(cached_remotes(dir.path(), &settings).is_empty());
        let requests = thread.join().unwrap();
        assert!(requests[1].0.starts_with("PUT /v1/snapshots/"));
        assert!(requests[2].0.starts_with("GET /v1/snapshots "));
    }
}
