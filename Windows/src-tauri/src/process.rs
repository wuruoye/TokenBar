use crate::settings::{user_home, Settings};
use std::{path::Path, process::Stdio, time::Duration};
use tokio::{io::AsyncReadExt, process::Command};

pub fn command(path: &Path, settings: &Settings) -> Command {
    let mut command = Command::new(path);
    command
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    command.creation_flags(0x08000000); // CREATE_NO_WINDOW
    command.env_remove("TOKENBAR_SYNC_TOKEN");
    command.env("HOME", user_home());
    command.env("CODEX_HOME", settings.root("codex"));
    command.env("CLAUDE_CONFIG_DIR", settings.root("claude"));
    command.env("GROK_HOME", settings.root("grok"));
    command
}

pub async fn capture(mut command: Command, seconds: u64) -> Result<Vec<u8>, String> {
    command.stdout(Stdio::piped());
    let mut child = command.spawn().map_err(|_| "无法启动本地辅助程序。")?;
    let stdout = child.stdout.take().ok_or("无法读取辅助程序输出。")?;
    let result = tokio::time::timeout(Duration::from_secs(seconds), async {
        let mut bytes = Vec::new();
        stdout
            .take(32 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .await
            .map_err(|_| "读取辅助程序失败。")?;
        if bytes.len() > 32 * 1024 * 1024 {
            return Err("辅助程序输出超过 32 MiB。".to_string());
        }
        let status = child.wait().await.map_err(|_| "无法等待辅助程序退出。")?;
        if !status.success() {
            return Err(format!("辅助程序退出失败（{}）。", status));
        }
        Ok(bytes)
    })
    .await;
    match result {
        Ok(Ok(bytes)) => Ok(bytes),
        other => {
            let _ = child.kill().await;
            let _ = child.wait().await;
            match other {
                Ok(Err(error)) => Err(error),
                _ => Err("本地数据读取超时，请稍后重试。".into()),
            }
        }
    }
}
