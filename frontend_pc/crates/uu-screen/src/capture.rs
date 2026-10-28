//! 屏幕采集（§4）：trait 封装 + xcap 实现。

use crate::error::{Result, ScreenError};

/// 显示器信息（对应 §3 ScreenMeta 消息字段）
#[derive(Debug, Clone)]
pub struct MonitorInfo {
    pub id: u32,
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub scale_factor: f32,
    pub rotation: f32,
    pub is_primary: bool,
}

/// 一次采集结果：RGBA8 像素
#[derive(Debug, Clone)]
pub struct CapturedFrame {
    pub width: u16,
    pub height: u16,
    pub rgba: Vec<u8>,
}

/// 采集后端抽象（便于替换为 DXGI 等更快实现）
pub trait CaptureBackend: Send {
    fn monitors(&self) -> Result<Vec<MonitorInfo>>;
    /// 按 `monitors()` 顺序采集第 index 个显示器
    fn capture(&self, index: usize) -> Result<CapturedFrame>;
}

/// xcap 采集后端
pub struct XcapCapture;

fn conv<T>(r: std::result::Result<T, xcap::XCapError>) -> Result<T> {
    r.map_err(|e| ScreenError::Capture(e.to_string()))
}

impl CaptureBackend for XcapCapture {
    fn monitors(&self) -> Result<Vec<MonitorInfo>> {
        let ms = conv(xcap::Monitor::all())?;
        Ok(ms
            .iter()
            .map(|m| MonitorInfo {
                id: m.id(),
                name: m.name().to_string(),
                x: m.x(),
                y: m.y(),
                width: m.width(),
                height: m.height(),
                scale_factor: m.scale_factor(),
                rotation: m.rotation(),
                is_primary: m.is_primary(),
            })
            .collect())
    }

    fn capture(&self, index: usize) -> Result<CapturedFrame> {
        let ms = conv(xcap::Monitor::all())?;
        let m = ms
            .get(index)
            .ok_or_else(|| ScreenError::Invalid(format!("monitor index {index}")))?;
        let img = conv(m.capture_image())?;
        Ok(CapturedFrame {
            width: img.width() as u16,
            height: img.height() as u16,
            rgba: img.into_raw(),
        })
    }
}
