//! 设备身份与会议令牌（§1/§8/§10.1）。

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use uu_transport::Identity;

#[derive(Clone, Serialize)]
pub struct DeviceInfo {
    pub device_id: String,
    pub name: String,
}

/// 身份目录：%APPDATA%/uudesk/identity（与 uu-app 相同方式）
pub fn identity_dir() -> PathBuf {
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
    dir.join("identity")
}

/// 计算机名（Windows: COMPUTERNAME）
pub fn computer_name() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "pc".to_string())
}

pub fn load_identity() -> Result<Identity, String> {
    Identity::load_or_create(&identity_dir())
        .map_err(|e| format!("加载设备身份失败: {e}"))
}

#[tauri::command]
pub fn device_info() -> DeviceInfo {
    match load_identity() {
        Ok(i) => DeviceInfo { device_id: i.device_id, name: computer_name() },
        Err(e) => {
            eprintln!("{e}");
            DeviceInfo { device_id: String::new(), name: computer_name() }
        }
    }
}

// ---------------- 会议令牌（§10.1） ----------------

#[derive(Serialize)]
struct TokenReq<'a> {
    room: &'a str,
    identity: &'a str,
    name: &'a str,
    can_publish: bool,
}

#[derive(Clone, Deserialize, Serialize)]
pub struct TokenResp {
    pub token: String,
    pub server_url: String,
}

/// POST {server}/api/meeting/token（reqwest 绕开 WebView CORS）
#[tauri::command]
pub async fn meeting_token(
    server_url: String,
    room: String,
    identity: String,
    name: String,
    can_publish: bool,
) -> Result<TokenResp, String> {
    let url = format!("{}/api/meeting/token", server_url.trim_end_matches('/'));
    let client = reqwest::Client::builder()
        .build()
        .map_err(|e| format!("http client: {e}"))?;
    let body = TokenReq { room: &room, identity: &identity, name: &name, can_publish };
    let resp = client
        .post(&url)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("请求会议令牌失败: {e}"))?;
    let status = resp.status();
    let json: serde_json::Value = resp.json().await.map_err(|e| format!("令牌响应解析失败: {e}"))?;
    if !status.is_success() {
        let msg = json
            .get("msg")
            .and_then(|m| m.as_str())
            .unwrap_or("服务器返回错误");
        return Err(format!("获取会议令牌失败({}): {msg}", status.as_u16()));
    }
    let out: Result<TokenResp, String> =
        serde_json::from_value(json).map_err(|e| format!("令牌响应字段不符: {e}"));
    out
}

/// POST {server}{path}（reqwest 绕开 WebView CORS），非 2xx 抽取 msg 返回错误。
async fn meeting_post(
    server_url: &str,
    path: &str,
    body: serde_json::Value,
) -> Result<serde_json::Value, String> {
    let url = format!("{}{}", server_url.trim_end_matches('/'), path);
    let client = reqwest::Client::builder()
        .build()
        .map_err(|e| format!("http client: {e}"))?;
    let resp = client
        .post(&url)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("请求失败: {e}"))?;
    let status = resp.status();
    let json: serde_json::Value = resp.json().await.map_err(|e| format!("响应解析失败: {e}"))?;
    if !status.is_success() {
        let msg = json
            .get("msg")
            .and_then(|m| m.as_str())
            .unwrap_or("服务器返回错误");
        return Err(format!("请求失败({}): {msg}", status.as_u16()));
    }
    Ok(json)
}

/// POST /api/meeting/egress/start 开始房间录制（后端已实现 RoomComposite MP4）。
#[tauri::command]
pub async fn meeting_egress_start(
    server_url: String,
    room: String,
) -> Result<serde_json::Value, String> {
    meeting_post(
        &server_url,
        "/api/meeting/egress/start",
        serde_json::json!({ "room": room }),
    )
    .await
}

/// POST /api/meeting/egress/stop 停止当前房间录制。
#[tauri::command]
pub async fn meeting_egress_stop(
    server_url: String,
    room: String,
) -> Result<serde_json::Value, String> {
    meeting_post(
        &server_url,
        "/api/meeting/egress/stop",
        serde_json::json!({ "room": room }),
    )
    .await
}
