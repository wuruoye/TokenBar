#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod windows_runner {
    use std::fs;
    use std::io;
    use std::os::windows::fs::MetadataExt;
    use std::os::windows::process::CommandExt;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::{ptr, slice};

    use anyhow::{bail, Context, Result};
    use serde::Deserialize;
    use uuid::Uuid;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };
    use windows_sys::Win32::System::Threading::CREATE_NO_WINDOW;
    use zeroize::{Zeroize, Zeroizing};

    const MARKER_FILE: &str = ".tokenbar-sync-install.json";
    const TOKEN_FILE: &str = "token.protected";
    const CLIENT_FILE: &str = "tokenbar-sync-background.exe";
    const CONFIG_FILE: &str = "config.json";
    const TASK_NAME: &str = "TokenBarSync";
    const MAX_MARKER_BYTES: u64 = 64 * 1024;
    const MAX_PROTECTED_TOKEN_BYTES: u64 = 64 * 1024;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;

    #[derive(Debug, Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct InstallMarker {
        schema_version: u32,
        install_id: Uuid,
        user_sid: String,
        install_root: PathBuf,
        task_name: String,
        task_executable: PathBuf,
        task_arguments: String,
    }

    struct DpapiBuffer {
        ptr: *mut u8,
        len: usize,
    }

    impl DpapiBuffer {
        fn from_blob(blob: CRYPT_INTEGER_BLOB) -> Result<Self> {
            let len = usize::try_from(blob.cbData).context("DPAPI output length is invalid")?;
            if blob.pbData.is_null() {
                bail!("DPAPI returned an invalid token buffer");
            }
            let buffer = Self {
                ptr: blob.pbData,
                len,
            };
            if len == 0 || len > MAX_PROTECTED_TOKEN_BYTES as usize {
                bail!("DPAPI returned an invalid token buffer");
            }
            Ok(buffer)
        }

        fn as_slice(&self) -> &[u8] {
            unsafe { slice::from_raw_parts(self.ptr, self.len) }
        }
    }

    impl Drop for DpapiBuffer {
        fn drop(&mut self) {
            unsafe {
                ptr::write_bytes(self.ptr, 0, self.len);
                LocalFree(self.ptr.cast());
            }
        }
    }

    pub fn run() -> Result<i32> {
        let self_path = std::env::current_exe().context("could not locate task runner")?;
        let install_root = self_path
            .parent()
            .context("task runner has no installation directory")?
            .to_path_buf();
        reject_reparse_point(&install_root)?;

        let marker_path = install_root.join(MARKER_FILE);
        let marker: InstallMarker = read_bounded_json(&marker_path, MAX_MARKER_BYTES)?;
        validate_marker(&marker, &install_root, &self_path)?;

        let token_path = install_root.join(TOKEN_FILE);
        let client_path = install_root.join(CLIENT_FILE);
        let config_path = install_root.join(CONFIG_FILE);
        require_file(&client_path)?;
        require_file(&config_path)?;

        let mut token = decrypt_token(&token_path)?;
        let mut command = Command::new(&client_path);
        command
            .arg("--config")
            .arg(&config_path)
            .arg("--state-dir")
            .arg(&install_root)
            .arg("upload")
            .current_dir(&install_root)
            .env("TOKENBAR_SYNC_TOKEN", token.as_str())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW);

        let child = command.spawn();
        drop(command);
        token.zeroize();

        let mut child = child.context("could not start TokenBar Sync client")?;
        let status = child
            .wait()
            .context("could not wait for TokenBar Sync client")?;
        Ok(status.code().unwrap_or(1))
    }

    fn reject_reparse_point(path: &Path) -> Result<()> {
        let metadata = fs::symlink_metadata(path)
            .with_context(|| format!("could not inspect install directory {}", path.display()))?;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            bail!("install directory must not be a reparse point");
        }
        Ok(())
    }

    fn read_bounded_json<T: for<'de> Deserialize<'de>>(path: &Path, maximum: u64) -> Result<T> {
        let metadata =
            fs::metadata(path).with_context(|| format!("could not inspect {}", path.display()))?;
        if !metadata.is_file() || metadata.len() == 0 || metadata.len() > maximum {
            bail!("{} has an invalid size", path.display());
        }
        let bytes = fs::read(path).with_context(|| format!("could not read {}", path.display()))?;
        serde_json::from_slice(&bytes)
            .with_context(|| format!("{} has an invalid schema", path.display()))
    }

    fn validate_marker(
        marker: &InstallMarker,
        install_root: &Path,
        self_path: &Path,
    ) -> Result<()> {
        if marker.schema_version != 2
            || marker.install_id.is_nil()
            || marker.user_sid.trim().is_empty()
            || marker.task_name != TASK_NAME
            || !marker.task_arguments.is_empty()
        {
            bail!("install marker ownership check failed");
        }
        if !same_path(&marker.install_root, install_root)?
            || !same_path(&marker.task_executable, self_path)?
        {
            bail!("install marker path check failed");
        }
        Ok(())
    }

    fn same_path(left: &Path, right: &Path) -> Result<bool> {
        let left = fs::canonicalize(left)
            .with_context(|| format!("could not resolve {}", left.display()))?;
        let right = fs::canonicalize(right)
            .with_context(|| format!("could not resolve {}", right.display()))?;
        Ok(left
            .to_string_lossy()
            .eq_ignore_ascii_case(&right.to_string_lossy()))
    }

    fn require_file(path: &Path) -> Result<()> {
        let metadata = fs::metadata(path)
            .with_context(|| format!("required file is missing: {}", path.display()))?;
        if !metadata.is_file() {
            bail!("required path is not a file: {}", path.display());
        }
        Ok(())
    }

    fn decrypt_token(path: &Path) -> Result<Zeroizing<String>> {
        let metadata =
            fs::metadata(path).with_context(|| format!("could not inspect {}", path.display()))?;
        if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_PROTECTED_TOKEN_BYTES
        {
            bail!("protected token has an invalid size");
        }
        let mut protected = fs::read(path).context("could not read protected token")?;
        let input_length =
            u32::try_from(protected.len()).context("protected token is too large")?;
        let input = CRYPT_INTEGER_BLOB {
            cbData: input_length,
            pbData: protected.as_mut_ptr(),
        };
        let mut output = CRYPT_INTEGER_BLOB::default();
        let success = unsafe {
            CryptUnprotectData(
                &input,
                ptr::null_mut(),
                ptr::null(),
                ptr::null(),
                ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };
        protected.zeroize();
        if success == 0 {
            return Err(io::Error::last_os_error()).context("DPAPI could not decrypt token");
        }

        let output = DpapiBuffer::from_blob(output)?;
        if !valid_token(output.as_slice()) {
            bail!("decrypted token is invalid");
        }
        // `valid_token` proves the bytes are printable ASCII, hence valid UTF-8. Moving the
        // allocation directly into `String` avoids making a second plaintext-token copy.
        let token = unsafe { String::from_utf8_unchecked(output.as_slice().to_vec()) };
        Ok(Zeroizing::new(token))
    }

    fn valid_token(value: &[u8]) -> bool {
        (32..=512).contains(&value.len()) && value.iter().all(|byte| (33..=126).contains(byte))
    }

    #[cfg(test)]
    mod tests {
        use super::valid_token;

        #[test]
        fn token_validation_matches_installer_contract() {
            assert!(valid_token(&[b'a'; 32]));
            assert!(valid_token(&[b'z'; 512]));
            assert!(!valid_token(&[b'a'; 31]));
            assert!(!valid_token(&[b'a'; 513]));
            assert!(!valid_token(b"contains whitespace but is long enough"));
            assert!(!valid_token(&[0; 64]));
        }
    }
}

#[cfg(windows)]
fn main() {
    let exit_code = windows_runner::run().unwrap_or(2);
    std::process::exit(exit_code);
}

#[cfg(not(windows))]
fn main() {
    eprintln!("tokenbar-sync-task is only supported on Windows");
    std::process::exit(2);
}
