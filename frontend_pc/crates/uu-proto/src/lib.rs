//! UUDesk 协议数据层（纯数据，无网络）。
//! 对应 uu-proto.md §3~§7 与 §9。

pub mod codec;
pub mod control;
pub mod error;
pub mod frames;

pub use codec::{decode_len, encode_len, encode_msg, MAX_CONTROL_LEN};
pub use control::{decode_msg, ControlMsg, InputEvent};
pub use error::{ProtoError, PROTO_VERSION};
pub use frames::{
    AudioHeader, FileHeader, VideoHeader, AUDIO_HEADER_LEN, AUDIO_MAGIC, FILE_CHUNK_SIZE,
    FILE_HEADER_LEN, FILE_MAGIC, VIDEO_HEADER_LEN, VIDEO_MAGIC,
};
pub use frames::{CODEC_H264_ANNEXB, CODEC_OPUS_48K2CH};

/// §9 错误码常量
pub mod codes {
    pub const ERR_PROTO_VERSION: u32 = 1001;
    pub const ERR_SPKI_PIN: u32 = 1002;
    pub const ERR_PAIR_CODE: u32 = 2001;
    pub const ERR_USER_REJECTED: u32 = 2002;
    pub const ERR_SCREEN_UNAUTHORIZED: u32 = 3001;
    pub const ERR_ACCESSIBILITY_OFF: u32 = 3002;
    pub const ERR_FILE_INTERRUPTED: u32 = 4001;
    pub const ERR_TARGET_OFFLINE: u32 = 4004;
    pub const ERR_SIGNAL_INVALID: u32 = 4005;
}
