//! 会议房间抽象（§10）：RoomClient trait + 事件流。
//! 真实实现走 LiveKit（feature `lk-native`），否则用 mock。

use tokio::sync::mpsc;

use crate::error::Result;

/// 会中 data channel topic（§10.2）
pub const TOPIC_CHAT: &str = "lk.chat";
pub const TOPIC_RAISE_HAND: &str = "uudesk/raise-hand";
pub const TOPIC_REACTION: &str = "uudesk/reaction";

/// 远端轨道类型
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrackKind {
    Microphone,
    Camera,
    ScreenShare,
}

/// 供 UI 显示的解码后视频帧（RGBA8）
#[derive(Clone, Debug)]
pub struct VideoFrame {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

#[derive(Clone, Debug)]
pub enum RoomEvent {
    Connected { room: String, recording: bool },
    Disconnected { reason: String },
    ParticipantJoined { identity: String, display_name: String },
    ParticipantLeft { identity: String },
    /// 远端发布轨道（含本地可见的屏幕共享状态变化）
    TrackPublished { identity: String, kind: TrackKind, sid: String },
    TrackUnpublished { identity: String, sid: String },
    /// 解码后的远端视频帧（摄像头/屏幕共享）
    VideoFrame { identity: String, sid: String, frame: VideoFrame },
    /// 远端音频混播由 SDK 直接播放；此事件仅作 UI 说话指示
    Speaking { identity: String, active: bool },
    Chat { identity: String, text: String },
    RaiseHand { identity: String, raised: bool },
    Reaction { identity: String, emoji: String },
    Error { message: String },
}

/// 加入房间所需参数
#[derive(Clone, Debug)]
pub struct JoinOptions {
    /// wss://host:7881（来自 token 响应，§10.1）
    pub server_url: String,
    pub token: String,
    /// 房间号（token 签发对象，§10.1）
    pub room: String,
    /// participant identity = device_id（§10.1）
    pub identity: String,
    pub display_name: String,
    pub can_publish: bool,
}

/// 房间客户端抽象。实现方在内部线程/任务中运行 SDK，
/// 事件经 `events()` 取走的 mpsc 通道上抛。
pub trait RoomClient: Send {
    /// 取事件接收端（只能取一次）
    fn take_events(&mut self) -> Option<mpsc::UnboundedReceiver<RoomEvent>>;
    /// 异步连接：立即返回 Ok，结果经 Connected/Disconnected/Error 事件上报
    fn join(&self, opts: JoinOptions) -> Result<()>;
    fn leave(&self);
    fn is_connected(&self) -> bool;
    /// 麦克风静音开关
    fn set_mic_muted(&self, muted: bool) -> Result<()>;
    /// 屏幕共享开关（复用 uu-screen 采集，§10.2 screen share 语义）
    fn set_screen_share(&self, on: bool) -> Result<()>;
    /// 会中聊天（topic `lk.chat`）
    fn send_chat(&self, text: &str) -> Result<()>;
    /// 举手（topic `uudesk/raise-hand`，payload {"raised":bool}）
    fn raise_hand(&self, raised: bool) -> Result<()>;
    /// 表情反应（topic `uudesk/reaction`，payload {"emoji":"..."}）
    fn send_reaction(&self, emoji: &str) -> Result<()>;
}

/// 按 feature 创建实现
pub fn create_client() -> Box<dyn RoomClient> {
    #[cfg(feature = "lk-native")]
    {
        Box::new(crate::lk::LiveKitRoomClient::new())
    }
    #[cfg(not(feature = "lk-native"))]
    {
        Box::new(crate::mock::MockRoomClient::new())
    }
}
