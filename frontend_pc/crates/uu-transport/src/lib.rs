//! UUDesk 传输层（QUIC，quinn 实现）：
//! - §1 自签 Ed25519 证书 + SPKI pin（device_id）
//! - §2 流布局：控制流/视频/音频/文件/DATAGRAM
//! - §6 局域网组播发现
//! - §8 信令与配对、打洞、中继接入

pub mod connection;
pub mod crypto;
pub mod der;
pub mod endpoint;
pub mod error;
pub mod identity;
pub mod lan;
pub mod signaling;

pub use connection::{ConnId, Connection, ControlSender, FileChunk, FileSender};
pub use crypto::{server_config, client_config, ALPN};
pub use crypto::PinPolicy;
pub use endpoint::{connect, connect_pairing, connect_with_policy, punch, relay_connect, RelayConnection, Server, RELAY_PORT};
pub use error::{Result, TransportError};
pub use identity::{pin_of_cert, Identity};
pub use lan::{DiscoveredDevice, LanAnnounce, MULTICAST_GROUP, MULTICAST_PORT};
pub use signaling::{SignalMsg, SignalingClient, RawSignal};

// 重新导出常用 proto 类型，方便上层单依赖使用
pub use uu_proto::{ControlMsg, InputEvent};
