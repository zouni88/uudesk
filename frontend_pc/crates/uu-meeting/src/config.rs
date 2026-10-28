//! 会议本地配置（服务器地址/房间号/显示名），持久化到平台配置目录。

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MeetingConfig {
    /// 信令服务器基址，如 `http://127.0.0.1:8080`（取 token 用，§10.1）
    pub signaling_url: String,
    /// 房间号
    pub room: String,
    /// 显示名（LiveKit participant name）
    pub display_name: String,
}

impl Default for MeetingConfig {
    fn default() -> Self {
        Self {
            signaling_url: "http://127.0.0.1:8080".into(),
            room: "demo".into(),
            display_name: String::new(),
        }
    }
}

impl MeetingConfig {
    /// 配置文件路径：%APPDATA%/uudesk/meeting_config.json（Windows）
    /// 或 ~/.config/uudesk/meeting_config.json，兜底当前目录。
    pub fn config_path() -> PathBuf {
        let dir = if cfg!(windows) {
            std::env::var("APPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from("."))
                .join("uudesk")
        } else {
            std::env::var("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".config")))
                .unwrap_or_else(|_| PathBuf::from("."))
                .join("uudesk")
        };
        dir.join("meeting_config.json")
    }

    pub fn load() -> Self {
        let path = Self::config_path();
        std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) -> std::result::Result<(), crate::error::MeetingError> {
        let path = Self::config_path();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let s = serde_json::to_string_pretty(self)
            .map_err(|e| crate::error::MeetingError::ConfigIo(e.to_string()))?;
        std::fs::write(&path, s).map_err(|e| crate::error::MeetingError::ConfigIo(e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_serde_roundtrip() {
        let c = MeetingConfig {
            signaling_url: "https://example.com".into(),
            room: "r1".into(),
            display_name: "pc-a".into(),
        };
        let s = serde_json::to_string(&c).unwrap();
        let c2: MeetingConfig = serde_json::from_str(&s).unwrap();
        assert_eq!(c, c2);
    }
}
