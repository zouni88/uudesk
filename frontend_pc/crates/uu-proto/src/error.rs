use thiserror::Error;

/// 协议版本号（§0）
pub const PROTO_VERSION: u32 = 1;

#[derive(Debug, Error)]
pub enum ProtoError {
    #[error("magic mismatch, got 0x{0:04X}")]
    BadMagic(u16),
    #[error("buffer too short: need {need} bytes, got {got}")]
    TooShort { need: usize, got: usize },
    #[error("length prefix too large: {0}")]
    LenTooLarge(u32),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("unknown message type: {0}")]
    UnknownType(String),
}
