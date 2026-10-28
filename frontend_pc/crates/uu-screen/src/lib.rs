//! 屏幕采集与 H.264 软编解码（uu-proto.md §4）。
//! - `capture`：xcap 采集，trait 封装
//! - `codec`：openh264 编解码（feature `codec`；关闭时提供返回错误的 Stub）

pub mod capture;
pub mod codec;
pub mod error;

pub use capture::{CapturedFrame, CaptureBackend, MonitorInfo, XcapCapture};
pub use codec::{DecodedFrame, EncodedFrame, VideoDecoder, VideoEncoder};
pub use error::{Result, ScreenError};

#[cfg(feature = "codec")]
pub use codec::{H264Decoder, H264Encoder};
