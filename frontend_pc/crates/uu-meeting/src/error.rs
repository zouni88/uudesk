use thiserror::Error;

#[derive(Debug, Error)]
pub enum MeetingError {
    #[error("token http error: {0}")]
    Http(String),
    #[error("not connected")]
    NotConnected,
    #[error("sdk error: {0}")]
    Sdk(String),
    #[error("config io: {0}")]
    ConfigIo(String),
    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, MeetingError>;
