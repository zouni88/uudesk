//! MockRoomClient：无 LiveKit 原生库时的降级实现。
//! 模拟入会/远端成员/合成视频帧/聊天回显，保证 UI 与 workspace 可编译可演示。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use tokio::sync::mpsc;

use crate::error::{MeetingError, Result};
use crate::room::{JoinOptions, RoomClient, RoomEvent, TrackKind, VideoFrame};

pub struct MockRoomClient {
    ev_tx: mpsc::UnboundedSender<RoomEvent>,
    ev_rx: Option<mpsc::UnboundedReceiver<RoomEvent>>,
    state: Arc<MockState>,
}

struct MockState {
    connected: AtomicBool,
    mic_muted: AtomicBool,
    screen_sharing: AtomicBool,
    identity: std::sync::Mutex<String>,
}

impl MockRoomClient {
    pub fn new() -> Self {
        let (ev_tx, ev_rx) = mpsc::unbounded_channel();
        Self {
            ev_tx,
            ev_rx: Some(ev_rx),
            state: Arc::new(MockState {
                connected: AtomicBool::new(false),
                mic_muted: AtomicBool::new(false),
                screen_sharing: AtomicBool::new(false),
                identity: std::sync::Mutex::new(String::new()),
            }),
        }
    }

    fn self_identity(&self) -> String {
        self.state.identity.lock().unwrap().clone()
    }
}

impl RoomClient for MockRoomClient {
    fn take_events(&mut self) -> Option<mpsc::UnboundedReceiver<RoomEvent>> {
        self.ev_rx.take()
    }

    fn join(&self, opts: JoinOptions) -> Result<()> {
        *self.state.identity.lock().unwrap() = opts.identity.clone();
        let tx = self.ev_tx.clone();
        let state = Arc::clone(&self.state);
        std::thread::spawn(move || {
            let room = opts.room.clone();
            std::thread::sleep(std::time::Duration::from_millis(200));
            state.connected.store(true, Ordering::Relaxed);
            let _ = tx.send(RoomEvent::Connected { room, recording: false });
            let _ = tx.send(RoomEvent::ParticipantJoined {
                identity: "MOCK-PEER-0001".into(),
                display_name: "演示成员".into(),
            });
            let _ = tx.send(RoomEvent::TrackPublished {
                identity: "MOCK-PEER-0001".into(),
                kind: TrackKind::ScreenShare,
                sid: "TR_mock_screen".into(),
            });
            // 合成视频帧：10fps 移动色条，供宫格视图渲染
            let (w, h) = (320u32, 180u32);
            let mut t = 0u32;
            while state.connected.load(Ordering::Relaxed) {
                let mut rgba = vec![0u8; (w * h * 4) as usize];
                for y in 0..h {
                    for x in 0..w {
                        let i = ((y * w + x) * 4) as usize;
                        let bar = (((x + t * 8) / 40) % 5) as u8;
                        rgba[i] = 40 + bar * 40;
                        rgba[i + 1] = 60 + ((y * 8) % 120) as u8;
                        rgba[i + 2] = 200 - bar * 30;
                        rgba[i + 3] = 255;
                    }
                }
                let _ = tx.send(RoomEvent::VideoFrame {
                    identity: "MOCK-PEER-0001".into(),
                    sid: "TR_mock_screen".into(),
                    frame: VideoFrame {
                        width: w,
                        height: h,
                        rgba,
                    },
                });
                t = t.wrapping_add(1);
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            let _ = tx.send(RoomEvent::Disconnected {
                reason: "mock left".into(),
            });
        });
        Ok(())
    }

    fn leave(&self) {
        self.state.connected.store(false, Ordering::Relaxed);
    }

    fn is_connected(&self) -> bool {
        self.state.connected.load(Ordering::Relaxed)
    }

    fn set_mic_muted(&self, muted: bool) -> Result<()> {
        if !self.is_connected() {
            return Err(MeetingError::NotConnected);
        }
        self.state.mic_muted.store(muted, Ordering::Relaxed);
        Ok(())
    }

    fn set_screen_share(&self, on: bool) -> Result<()> {
        if !self.is_connected() {
            return Err(MeetingError::NotConnected);
        }
        self.state.screen_sharing.store(on, Ordering::Relaxed);
        let _ = self.ev_tx.send(RoomEvent::TrackPublished {
            identity: self.self_identity(),
            kind: TrackKind::ScreenShare,
            sid: "TR_local_screen".into(),
        });
        Ok(())
    }

    fn send_chat(&self, text: &str) -> Result<()> {
        if !self.is_connected() {
            return Err(MeetingError::NotConnected);
        }
        let _ = self.ev_tx.send(RoomEvent::Chat {
            identity: self.self_identity(),
            text: text.to_string(),
        });
        Ok(())
    }

    fn raise_hand(&self, raised: bool) -> Result<()> {
        if !self.is_connected() {
            return Err(MeetingError::NotConnected);
        }
        let _ = self.ev_tx.send(RoomEvent::RaiseHand {
            identity: self.self_identity(),
            raised,
        });
        Ok(())
    }

    fn send_reaction(&self, emoji: &str) -> Result<()> {
        if !self.is_connected() {
            return Err(MeetingError::NotConnected);
        }
        let _ = self.ev_tx.send(RoomEvent::Reaction {
            identity: self.self_identity(),
            emoji: emoji.to_string(),
        });
        Ok(())
    }
}
