//! UUDesk 桌面端（Tauri v2）Rust 后端：
//! 远程控制 IPC 契约 + 事件 `uu://frame` / `uu://status`。

mod conn;
mod controlled;
mod device;
mod frame;
mod meeting;
mod session;

use session::SessionState;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // 单实例：重复启动时聚焦已有窗口，杜绝同设备多窗口同时入会
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.unminimize();
                let _ = w.set_focus();
            }
        }))
        .plugin(tauri_plugin_opener::init())
        .manage(SessionState::default())
        .invoke_handler(tauri::generate_handler![
            device::device_info,
            device::meeting_token,
            device::meeting_egress_start,
            device::meeting_egress_stop,
            session::remote_connect,
            session::remote_connect_direct,
            session::remote_disconnect,
            session::remote_input,
            session::remote_request_keyframe,
            controlled::controlled_start,
            controlled::controlled_stop,
            meeting::meeting_inject,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
