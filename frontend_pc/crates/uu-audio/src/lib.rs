//! 音频采集/编解码（uu-proto.md §5，Opus 48kHz/2ch）。
//! 本 crate 目前仅提供 trait 接口与骨架实现：
//! - feature `backend` 打开通用 cpal/opus 原生后端（需 C 工具链，默认关闭）
//! - 骨架实现返回 [`AudioError::Unavailable`]，上层据此发 §3.1 `error` 消息

use thiserror::Error;

#[derive(Debug, Error)]
pub enum AudioError {
    #[error("audio backend unavailable (feature `backend` not enabled)")]
    Unavailable,
    #[error("device: {0}")]
    Device(String),
    #[error("codec: {0}")]
    Codec(String),
}

pub type Result<T> = std::result::Result<T, AudioError>;

/// 采样规格（§5）：48kHz 双声道 S16 交织
pub const SAMPLE_RATE: u32 = 48_000;
pub const CHANNELS: u16 = 2;
/// Opus 帧时长（ms）
pub const FRAME_MS: u32 = 20;

/// 采集回调：一段交织 PCM
pub type PcmSink = std::sync::mpsc::Sender<Vec<i16>>;

/// 音频采集（发送端：被控/控制端麦克风）
pub trait AudioCapture: Send {
    fn start(&mut self, sink: PcmSink) -> Result<()>;
    fn stop(&mut self) -> Result<()>;
}

/// 音频播放（接收端）
pub trait AudioRenderer: Send {
    fn start(&mut self) -> Result<()>;
    fn push_pcm(&mut self, samples: &[i16]) -> Result<()>;
    fn stop(&mut self) -> Result<()>;
}

/// Opus 编码（48k/2ch/20ms 帧）
pub trait OpusEncoder: Send {
    fn encode(&mut self, pcm: &[i16]) -> Result<Vec<u8>>;
}

/// Opus 解码：返回交织 PCM
pub trait OpusDecoder: Send {
    fn decode(&mut self, packet: &[u8]) -> Result<Vec<i16>>;
}

// ---------------- 骨架实现 ----------------

pub struct StubCapture;

impl AudioCapture for StubCapture {
    fn start(&mut self, _sink: PcmSink) -> Result<()> {
        Err(AudioError::Unavailable)
    }
    fn stop(&mut self) -> Result<()> {
        Err(AudioError::Unavailable)
    }
}

pub struct StubRenderer;

impl AudioRenderer for StubRenderer {
    fn start(&mut self) -> Result<()> {
        Err(AudioError::Unavailable)
    }
    fn push_pcm(&mut self, _samples: &[i16]) -> Result<()> {
        Err(AudioError::Unavailable)
    }
    fn stop(&mut self) -> Result<()> {
        Err(AudioError::Unavailable)
    }
}

pub struct StubOpusEncoder;

impl OpusEncoder for StubOpusEncoder {
    fn encode(&mut self, _pcm: &[i16]) -> Result<Vec<u8>> {
        Err(AudioError::Unavailable)
    }
}

pub struct StubOpusDecoder;

impl OpusDecoder for StubOpusDecoder {
    fn decode(&mut self, _packet: &[u8]) -> Result<Vec<i16>> {
        Err(AudioError::Unavailable)
    }
}
