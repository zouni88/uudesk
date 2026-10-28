use thiserror::Error;

#[derive(Debug, Error)]
pub enum ScreenError {
    #[error("capture: {0}")]
    Capture(String),
    #[error("codec: {0}")]
    Codec(String),
    #[error("codec feature not enabled (openh264 unavailable)")]
    CodecUnavailable,
    #[error("invalid frame: {0}")]
    Invalid(String),
}

pub type Result<T> = std::result::Result<T, ScreenError>;
