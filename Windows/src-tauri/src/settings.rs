use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct Settings {
    pub refresh_seconds: u64,
    pub recent_limit: usize,
    pub theme: String,
    pub show_claude: bool,
    pub show_grok: bool,
    pub autostart: bool,
    pub codex_home: String,
    pub claude_home: String,
    pub grok_home: String,
    pub codex_binary: String,
    pub memory_enabled: bool,
    pub sync_enabled: bool,
    pub sync_endpoint: String,
    pub sync_device_name: String,
    pub taskbar_enabled: bool,
    pub taskbar_platform: String,
    pub taskbar_position: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            refresh_seconds: 300,
            recent_limit: 10,
            theme: "system".into(),
            show_claude: true,
            show_grok: true,
            autostart: false,
            codex_home: String::new(),
            claude_home: String::new(),
            grok_home: String::new(),
            codex_binary: String::new(),
            memory_enabled: false,
            sync_enabled: false,
            sync_endpoint: String::new(),
            sync_device_name: std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows".into()),
            taskbar_enabled: true,
            taskbar_platform: "all".into(),
            taskbar_position: "right".into(),
        }
    }
}

impl Settings {
    pub fn validate(&self) -> Result<(), String> {
        if !["codex", "claude", "grok", "all"].contains(&self.taskbar_platform.as_str())
            || !["left", "right"].contains(&self.taskbar_position.as_str())
        {
            return Err("任务栏显示设置无效。".into());
        }
        if self.taskbar_enabled
            && ((self.taskbar_platform == "claude" && !self.show_claude)
                || (self.taskbar_platform == "grok" && !self.show_grok))
        {
            return Err("请先开启对应平台的显示，再将它放入任务栏。".into());
        }
        if !(60..=3600).contains(&self.refresh_seconds) || !(5..=100).contains(&self.recent_limit) {
            return Err("刷新间隔须为 60–3600 秒，会话数量须为 5–100。".into());
        }
        if !["system", "dark", "light"].contains(&self.theme.as_str()) {
            return Err("无效的主题。".into());
        }
        for path in [&self.codex_home, &self.claude_home, &self.grok_home] {
            if !path.is_empty() && (!Path::new(path).is_absolute() || !Path::new(path).is_dir()) {
                return Err("数据目录须为存在的绝对路径。".into());
            }
        }
        if !self.codex_binary.is_empty() {
            let path = Path::new(&self.codex_binary);
            if !path.is_absolute()
                || !path.is_file()
                || !path
                    .extension()
                    .is_some_and(|s| s.eq_ignore_ascii_case("exe"))
            {
                return Err("Codex 路径须指向现有的 .exe 文件。".into());
            }
        }
        if self.sync_enabled {
            tokenbar_sync::sync_client::Endpoint::parse(&self.sync_endpoint)
                .map_err(|_| "同步地址须为 HTTPS 服务地址；本机回环地址可使用 HTTP。")?;
            tokenbar_sync::config::tokenbar_sync_device_name(&self.sync_device_name)
                .map_err(|_| "设备名称无效。")?;
        }
        Ok(())
    }

    pub fn root(&self, platform: &str) -> PathBuf {
        let (custom, key, name) = match platform {
            "claude" => (&self.claude_home, "CLAUDE_CONFIG_DIR", ".claude"),
            "grok" => (&self.grok_home, "GROK_HOME", ".grok"),
            _ => (&self.codex_home, "CODEX_HOME", ".codex"),
        };
        if !custom.is_empty() {
            return PathBuf::from(custom);
        }
        std::env::var_os(key)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| user_home().join(name))
    }
}

pub fn user_home() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_default()
}

pub fn load(dir: &Path) -> Result<Settings, String> {
    let path = dir.join("settings.json");
    if !path.exists() {
        return Ok(Settings::default());
    }
    let bytes = std::fs::read(path).map_err(|_| "无法读取设置文件。")?;
    let settings: Settings = serde_json::from_slice(&bytes).map_err(|_| "设置文件格式无效。")?;
    // Paths can become unavailable between launches. Validate those when saving.
    Ok(settings)
}

pub fn save(dir: &Path, settings: &Settings) -> Result<(), String> {
    let data = serde_json::to_vec_pretty(settings).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(dir).map_err(|_| "无法创建设置目录。")?;
    let temp = dir.join("settings.tmp");
    std::fs::write(&temp, data).map_err(|_| "无法写入设置。")?;
    std::fs::rename(temp, dir.join("settings.json")).map_err(|_| "无法保存设置。".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn settings_reject_unbounded_refresh_and_unknown_theme() {
        let mut settings = Settings::default();
        assert!(settings.validate().is_ok());
        settings.refresh_seconds = 0;
        assert!(settings.validate().is_err());
        settings.refresh_seconds = 60;
        settings.theme = "unknown".into();
        assert!(settings.validate().is_err());
    }
    #[test]
    fn settings_replace_existing_file_without_losing_values() {
        let dir = tempfile::tempdir().unwrap();
        let mut settings = Settings::default();
        save(dir.path(), &settings).unwrap();
        settings.show_grok = false;
        save(dir.path(), &settings).unwrap();
        assert!(!load(dir.path()).unwrap().show_grok);
    }
    #[test]
    fn existing_preferences_enable_taskbar_without_resetting_other_settings() {
        let settings: Settings =
            serde_json::from_str(r#"{"refreshSeconds":600,"showClaude":false}"#).unwrap();
        assert!(settings.taskbar_enabled);
        assert_eq!(settings.taskbar_platform, "all");
        assert_eq!(settings.refresh_seconds, 600);
        assert!(!settings.show_claude);
    }
}
