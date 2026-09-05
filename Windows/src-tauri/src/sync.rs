use crate::settings::Settings;
use serde::{Deserialize, Serialize};
use std::path::Path;
use tokenbar_helper::ActivitySnapshot;
use tokenbar_sync::{
    device,
    protocol::{self, DeviceDescriptor, DeviceOs},
    sync_client::{Endpoint, SyncClient},
};
use zeroize::{Zeroize, Zeroizing};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Remote {
    pub device_id: String,
    pub device_name: String,
    pub snapshot: ActivitySnapshot,
}

#[cfg(windows)]
fn crypt(input: &[u8], protect: bool) -> Result<Vec<u8>, String> {
    use windows_sys::Win32::{
        Foundation::LocalFree,
        Security::Cryptography::{
            CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
        },
    };
    if input.is_empty() || input.len() > 65536 {
        return Err("同步凭据大小无效。".into());
    }
    let source = CRYPT_INTEGER_BLOB {
        cbData: input.len() as u32,
        pbData: input.as_ptr() as *mut _,
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    // DPAPI binds the encrypted token to the current Windows user.
    unsafe {
        let ok = if protect {
            CryptProtectData(
                &source,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &source,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };
        if ok == 0 {
            return Err("Windows 无法保护或解密同步凭据。".into());
        }
        let bytes = std::slice::from_raw_parts_mut(output.pbData, output.cbData as usize);
        let copy = bytes.to_vec();
        bytes.zeroize();
        LocalFree(output.pbData.cast());
        Ok(copy)
    }
}
#[cfg(not(windows))]
fn crypt(_: &[u8], _: bool) -> Result<Vec<u8>, String> {
    Err("同步凭据存储需要 Windows DPAPI。".into())
}

pub fn save_token(dir: &Path, token: String) -> Result<(), String> {
    let token = Zeroizing::new(token);
    if !(32..=512).contains(&token.len())
        || !token.is_ascii()
        || token.chars().any(char::is_whitespace)
    {
        return Err("同步访问令牌须为 32–512 个不含空白的 ASCII 字符。".into());
    }
    let protected = crypt(token.as_bytes(), true)?;
    let temp = dir.join("sync-token.tmp");
    std::fs::write(&temp, protected).map_err(|_| "无法保存同步凭据。")?;
    std::fs::rename(temp, dir.join("sync-token.protected")).map_err(|_| "无法保存同步凭据。".into())
}
pub fn has_token(dir: &Path) -> bool {
    dir.join("sync-token.protected").is_file()
}

pub fn round(
    dir: &Path,
    settings: &Settings,
    snapshot: &ActivitySnapshot,
) -> Result<Vec<Remote>, String> {
    let protected = std::fs::read(dir.join("sync-token.protected"))
        .map_err(|_| "请在设置中填写同步访问令牌。")?;
    let bytes = Zeroizing::new(crypt(&protected, false)?);
    let token = std::str::from_utf8(&bytes).map_err(|_| "同步凭据无效。")?;
    let local = device::load_or_create(dir).map_err(|_| "无法读取本机设备标识。")?;
    let client =
        SyncClient::new(Endpoint::parse(&settings.sync_endpoint).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
    let descriptor = DeviceDescriptor {
        id: local.id,
        name: settings.sync_device_name.clone(),
        os: DeviceOs::Windows,
        client_version: Some(env!("CARGO_PKG_VERSION").into()),
    };
    let envelope = protocol::upload_envelope(
        serde_json::to_value(snapshot).map_err(|_| "无法编码统计数据。")?,
        descriptor,
    )
    .map_err(|_| "统计数据未通过同步校验。")?;
    client
        .upload(token, &envelope)
        .map_err(|e| format!("同步上传失败：{e}"))?;
    let response = client
        .download(token)
        .map_err(|e| format!("同步下载失败：{e}"))?;
    let remotes = response
        .snapshots
        .into_iter()
        .filter(|row| row.device.id != local.id)
        .filter_map(|row| {
            let snapshot: ActivitySnapshot = serde_json::from_value(row.snapshot).ok()?;
            if snapshot.schema_version != tokenbar_helper::SCHEMA_VERSION
                || snapshot.timezone != "UTC"
            {
                return None;
            }
            Some(Remote {
                device_id: row.device.id.to_string(),
                device_name: row.device.name,
                snapshot,
            })
        })
        .collect();
    Ok(remotes)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(windows)]
    #[test]
    fn dpapi_round_trip_and_disk_never_contain_plaintext() {
        let dir = tempfile::tempdir().unwrap();
        let token = "test-only-credential-12345678901234567890";
        save_token(dir.path(), token.into()).unwrap();
        let bytes = std::fs::read(dir.path().join("sync-token.protected")).unwrap();
        assert!(!bytes
            .windows(token.len())
            .any(|window| window == token.as_bytes()));
        assert_eq!(crypt(&bytes, false).unwrap(), token.as_bytes());
    }
    #[test]
    fn invalid_token_is_not_saved() {
        let dir = tempfile::tempdir().unwrap();
        assert!(save_token(dir.path(), "short".into()).is_err());
        assert!(!has_token(dir.path()));
    }
}
