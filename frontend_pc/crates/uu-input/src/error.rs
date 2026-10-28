use thiserror::Error;

#[derive(Debug, Error)]
pub enum InputError {
    #[error("enigo init: {0}")]
    Init(String),
    #[error("inject: {0}")]
    Inject(String),
    #[error("invalid: {0}")]
    Invalid(String),
}

pub type Result<T> = std::result::Result<T, InputError>;
