//! 统一会话传输层：直连 QUIC（uu-transport Connection）与服务器中继（§8 relay）。
//!
//! 中继通道在 relay_hello 之后是一条原始字节管道，本实现用统一信封复用控制流与视频流：
//! `u32 大端长度 + 载荷`，载荷为控制 JSON（§3）或完整视频帧字节（§4，按 magic 0x5556 分派），
//! 与 uu-transport 直连时的分派逻辑一致。

use std::sync::Mutex;

use tokio::sync::mpsc;
use uu_proto::{decode_msg, ControlMsg, VIDEO_MAGIC};
use uu_transport::connection::Connection;
use uu_transport::endpoint::RelayConnection;

/// 单帧最大字节（与 uu-transport 防御上限一致）
const MAX_FRAME: usize = 32 * 1024 * 1024;

/// 中继连接包装：把原始字节管道拆成控制/视频通道
pub struct RelayConn {
    endpoint: quinn::Endpoint,
    raw_tx: mpsc::UnboundedSender<Vec<u8>>,
    control_rx: Mutex<Option<mpsc::UnboundedReceiver<ControlMsg>>>,
    video_rx: Mutex<Option<mpsc::UnboundedReceiver<Vec<u8>>>>,
}

impl RelayConn {
    pub fn new(r: RelayConnection) -> Self {
        let RelayConnection { endpoint, send, recv } = r;
        let (raw_tx, mut raw_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let (ctl_tx, ctl_rx) = mpsc::unbounded_channel::<ControlMsg>();
        let (vid_tx, vid_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        // 写任务：payload → u32 长度前缀 + 字节
        tokio::spawn(async move {
            let mut send = send;
            while let Some(p) = raw_rx.recv().await {
                if send.write_all(&(p.len() as u32).to_be_bytes()).await.is_err() {
                    return;
                }
                if send.write_all(&p).await.is_err() {
                    return;
                }
            }
            let _ = send.finish();
        });
        // 读任务：长度前缀 → 按 magic 分派视频/控制
        tokio::spawn(async move {
            let mut recv = recv;
            let mut lb = [0u8; 4];
            loop {
                if recv.read_exact(&mut lb).await.is_err() {
                    return;
                }
                let n = u32::from_be_bytes(lb) as usize;
                if n == 0 || n > MAX_FRAME {
                    return;
                }
                let mut p = vec![0u8; n];
                if recv.read_exact(&mut p).await.is_err() {
                    return;
                }
                if p.len() >= 2 && u16::from_be_bytes([p[0], p[1]]) == VIDEO_MAGIC {
                    if vid_tx.send(p).is_err() {
                        return;
                    }
                } else {
                    match decode_msg(&p) {
                        Ok(m) => {
                            if ctl_tx.send(m).is_err() {
                                return;
                            }
                        }
                        Err(e) => tracing::debug!("relay control decode err: {e}"),
                    }
                }
            }
        });
        Self { endpoint, raw_tx, control_rx: Mutex::new(Some(ctl_rx)), video_rx: Mutex::new(Some(vid_rx)) }
    }

    fn take_ctl(&self) -> Option<mpsc::UnboundedReceiver<ControlMsg>> {
        self.control_rx.lock().ok().and_then(|mut g| g.take())
    }

    fn take_vid(&self) -> Option<mpsc::UnboundedReceiver<Vec<u8>>> {
        self.video_rx.lock().ok().and_then(|mut g| g.take())
    }
}

/// 会话连接：直连或中继
pub enum Conn {
    Direct(Connection),
    Relay(RelayConn),
}

impl Conn {
    pub fn send_control(&self, m: ControlMsg) -> Result<(), String> {
        match self {
            Conn::Direct(c) => c.control().send(m).map_err(|e| e.to_string()),
            Conn::Relay(r) => {
                let json = serde_json::to_vec(&m).map_err(|e| e.to_string())?;
                r.raw_tx.send(json).map_err(|_| "relay closed".to_string())
            }
        }
    }

    pub fn take_control_rx(&self) -> Option<mpsc::UnboundedReceiver<ControlMsg>> {
        match self {
            Conn::Direct(c) => c.take_control_rx(),
            Conn::Relay(r) => r.take_ctl(),
        }
    }

    pub fn take_video_rx(&self) -> Option<mpsc::UnboundedReceiver<Vec<u8>>> {
        match self {
            Conn::Direct(c) => c.take_video_rx(),
            Conn::Relay(r) => r.take_vid(),
        }
    }

    pub fn close(&self) {
        match self {
            Conn::Direct(c) => c.close(0, "disconnect"),
            Conn::Relay(r) => {
                let _ = r.endpoint.close(quinn::VarInt::from_u32(0), b"disconnect");
                // 关闭写通道，使写任务随流结束退出
                let _ = r.raw_tx.send(Vec::new());
            }
        }
    }
}
