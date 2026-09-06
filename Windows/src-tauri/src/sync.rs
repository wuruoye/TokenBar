use serde::{Deserialize, Serialize};
use std::path::Path;
use tokenbar_helper::ActivitySnapshot;
use zeroize::{Zeroize, Zeroizing};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Remote {
    pub device_id: String,
    pub device_name: String,
    pub snapshot: ActivitySnapshot,
}

#[cfg(windows)]
pub(super) fn crypt(input: &[u8], protect: bool) -> Result<Vec<u8>, String> {
    use windows_sys::Win32::{
        Foundation::LocalFree,
        Security::Cryptography::{
            CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
        },
    };
    if input.is_empty() || input.len() > 65 * 1024 * 1024 {
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
pub(super) fn crypt(_: &[u8], _: bool) -> Result<Vec<u8>, String> {
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

pub fn displayed_today(dashboard: &crate::Dashboard, platform: &str) -> Option<i64> {
    let local = dashboard.snapshot.as_ref()?;
    let latest = local.days.iter().map(|day| day.date.as_str()).max();
    let mut snapshots = vec![local];
    if latest.is_some() && dashboard.settings.sync_enabled && dashboard.settings.sync_all_devices {
        let mut ids = std::collections::HashSet::new();
        snapshots.extend(dashboard.remote_snapshots.iter().filter(|remote| ids.insert(&remote.device_id)
            && remote.snapshot.timezone == local.timezone && remote.snapshot.schema_version > 0
            && remote.snapshot.days.iter().map(|day| day.date.as_str()).max() == latest).map(|r| &r.snapshot));
    }
    let totals: Vec<_> = snapshots.iter().filter_map(|snapshot| snapshot.sources.iter().find(|s| s.platform == platform)).collect();
    if totals.is_empty() { return None; }
    Some(totals.into_iter().fold(0i64, |sum, source| {
        let t = &source.today.tokens;
        sum.saturating_add(t.input).saturating_add(t.output).saturating_add(t.cache_read)
            .saturating_add(t.cache_write).saturating_add(t.reasoning)
    }))
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
