//! UUDesk 多人会议（uu-proto.md §10）：自托管 LiveKit 媒体面。
//! - `room`：RoomClient trait 与事件模型（聊天/举手/反应 topic 见 §10.2）
//! - `token`：经 Go 信令服务器取 LiveKit JWT（§10.1）
//! - `config`：服务器地址/房间号本地持久化
//! - feature `lk-native`：官方 livekit SDK 真实实现；关闭时用 `mock` 降级

pub mod config;
pub mod error;
pub mod mock;
pub mod room;
pub mod token;

#[cfg(feature = "lk-native")]
pub mod lk;

pub use config::MeetingConfig;
pub use error::{MeetingError, Result};
pub use room::{
    create_client, JoinOptions, RoomClient, RoomEvent, TrackKind, VideoFrame, TOPIC_CHAT,
    TOPIC_RAISE_HAND, TOPIC_REACTION,
};
pub use token::{fetch_token, TokenResponse};
