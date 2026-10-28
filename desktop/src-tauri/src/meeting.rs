//! 会中屏幕共享控制（LiveKit data channel `uudesk/control`）：
//! 共享者收到观看方授权的 §3.2 input 事件后，在本机注入。

use uu_proto::InputEvent;
use uu_screen::CaptureBackend;

/// 注入一条 §3.2 input 事件（ev 为 {"t":"input","k":...} 原文，坐标归一化 0.0–1.0）。
#[tauri::command]
pub fn meeting_inject(ev: serde_json::Value) -> Result<(), String> {
    let mut v = ev;
    // 信封字段 t 不属于 InputEvent（internally tagged by k），先剔除避免歧义
    if let Some(obj) = v.as_object_mut() {
        obj.remove("t");
    }
    let input = serde_json::from_value::<InputEvent>(v).map_err(|e| format!("input 事件非法: {e}"))?;
    let (w, h) = primary_screen_size()?;
    // enigo 创建开销小，30Hz 逐条新建可接受
    let mut inj = uu_input::InputInjector::new().map_err(|e| format!("输入注入不可用: {e}"))?;
    inj
        .apply(&input, w, h)
        .map_err(|e| format!("注入失败: {e}"))
}

/// 主屏像素尺寸（取 monitors() 第一个）
fn primary_screen_size() -> Result<(u32, u32), String> {
    let ms = uu_screen::XcapCapture
        .monitors()
        .map_err(|e| format!("屏幕尺寸获取失败: {e}"))?;
    let m = ms.first().ok_or("未找到显示器")?;
    if m.width == 0 || m.height == 0 {
        return Err("屏幕尺寸非法".into());
    }
    Ok((m.width, m.height))
}
