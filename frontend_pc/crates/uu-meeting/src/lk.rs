//! LiveKit 原生实现（feature `lk-native`，§10）。
//! 独立线程 + 自建 tokio runtime 驱动官方 SDK；
//! 命令经 mpsc 下发，事件统一映射为 `RoomEvent` 上抛给 UI。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use futures_util::StreamExt;
use livekit::options::TrackPublishOptions;
use livekit::prelude::*;
use livekit::webrtc::desktop_capturer::{
    DesktopCaptureSourceType, DesktopCapturer, DesktopCapturerOptions,
};
use livekit::webrtc::native::yuv_helper;
use livekit::webrtc::video_frame::{I420Buffer, VideoFormatType, VideoFrame, VideoRotation};
use livekit::webrtc::video_source::native::NativeVideoSource;
use livekit::webrtc::video_source::{RtcVideoSource, VideoResolution};
use livekit::webrtc::video_stream::native::NativeVideoStream;
use tokio::sync::mpsc;

use crate::error::{MeetingError, Result};
use crate::room::{
    JoinOptions, RoomClient, RoomEvent as UiEvent, TrackKind as UiTrackKind,
    VideoFrame as UiVideoFrame, TOPIC_CHAT, TOPIC_RAISE_HAND, TOPIC_REACTION,
};

/// UI 线程 → SDK runtime 的命令
enum Cmd {
    Join(JoinOptions),
    Leave,
    MicMuted(bool),
    Screen(bool),
    Data { topic: String, payload: Vec<u8> },
}

struct ScreenShare {
    sid: TrackSid,
    /// true = 泵帧线程继续运行
    running: Arc<AtomicBool>,
}

fn map_kind(kind: TrackKind, source: TrackSource) -> UiTrackKind {
    match kind {
        TrackKind::Audio => UiTrackKind::Microphone,
        TrackKind::Video => match source {
            TrackSource::Screenshare | TrackSource::ScreenshareAudio => UiTrackKind::ScreenShare,
            _ => UiTrackKind::Camera,
        },
    }
}

struct RoomState {
    room: Room,
    ev_tx: mpsc::UnboundedSender<UiEvent>,
    connected: Arc<AtomicBool>,
    /// ADM 句柄必须保活：远端音频混播 + 本地采集依赖它
    _audio: Option<PlatformAudio>,
    mic_pub: Option<LocalTrackPublication>,
    screen: Option<ScreenShare>,
    speakers: Vec<String>,
    recording: bool,
}

impl RoomState {
    fn send(&self, ev: UiEvent) {
        let _ = self.ev_tx.send(ev);
    }

    /// 连接成功后初始化音频设备；can_publish 时发布麦克风（§10.1）
    async fn setup_audio(&mut self, opts: &JoinOptions) {
        match PlatformAudio::new() {
            Ok(audio) => {
                self._audio = Some(audio);
                if opts.can_publish {
                    let source = self._audio.as_ref().unwrap().rtc_source();
                    let track = LocalAudioTrack::create_audio_track("mic", source);
                    let pub_opts = TrackPublishOptions {
                        source: TrackSource::Microphone,
                        ..Default::default()
                    };
                    match self
                        .room
                        .local_participant()
                        .publish_track(LocalTrack::Audio(track), pub_opts)
                        .await
                    {
                        Ok(p) => self.mic_pub = Some(p),
                        Err(e) => {
                            self.send(UiEvent::Error { message: format!("publish mic: {e}") })
                        }
                    }
                }
            }
            Err(e) => self.send(UiEvent::Error { message: format!("PlatformAudio: {e}") }),
        }
    }

    /// libwebrtc DesktopCapturer 采集屏幕 → BGRA/ARGB 转 I420 → 视频源（§10.2）
    async fn start_screen(&mut self) -> std::result::Result<(), String> {
        if self.screen.is_some() {
            return Ok(());
        }
        let mut capturer = DesktopCapturer::new(DesktopCapturerOptions::new(
            DesktopCaptureSourceType::Screen,
        ))
        .ok_or_else(|| "DesktopCapturer unavailable".to_string())?;
        let sources = capturer.get_source_list();
        let first = sources.into_iter().next().ok_or_else(|| "no screen source".to_string())?;

        let source = NativeVideoSource::new(
            VideoResolution { width: 1920, height: 1080 },
            true,
        );
        let cb_source = source.clone();
        let running = Arc::new(AtomicBool::new(true));
        let running_t = Arc::clone(&running);
        std::thread::Builder::new()
            .name("lk-screen-capture".into())
            .spawn(move || {
                capturer.start_capture(Some(first), move |res| {
                    let Ok(df) = res else { return };
                    let w = df.width().max(0) as u32;
                    let h = df.height().max(0) as u32;
                    if w == 0 || h == 0 {
                        return;
                    }
                    let mut buf = I420Buffer::new(w, h);
                    {
                        let (dy, du, dv) = buf.data_mut();
                        let cw = (w + 1) / 2;
                        yuv_helper::argb_to_i420(
                            df.data(),
                            df.stride(),
                            dy,
                            w,
                            du,
                            cw,
                            dv,
                            cw,
                            w as i32,
                            h as i32,
                        );
                    }
                    let vf = VideoFrame::new(VideoRotation::VideoRotation0, buf);
                    cb_source.capture_frame(&vf);
                });
                // 15fps 泵帧
                while running_t.load(Ordering::Relaxed) {
                    capturer.capture_frame();
                    std::thread::sleep(Duration::from_millis(66));
                }
            })
            .map_err(|e| format!("spawn capture thread: {e}"))?;

        let track = LocalVideoTrack::create_video_track("screen", RtcVideoSource::Native(source));
        let pub_opts = TrackPublishOptions {
            source: TrackSource::Screenshare,
            ..Default::default()
        };
        match self
            .room
            .local_participant()
            .publish_track(LocalTrack::Video(track), pub_opts)
            .await
        {
            Ok(p) => {
                let sid = p.sid();
                self.send(UiEvent::TrackPublished {
                    identity: self.room.local_participant().identity().to_string(),
                    kind: UiTrackKind::ScreenShare,
                    sid: sid.to_string(),
                });
                self.screen = Some(ScreenShare { sid, running });
                Ok(())
            }
            Err(e) => {
                running.store(false, Ordering::Relaxed);
                Err(format!("publish screen: {e}"))
            }
        }
    }

    async fn stop_screen(&mut self) {
        if let Some(ss) = self.screen.take() {
            ss.running.store(false, Ordering::Relaxed);
            let _ = self.room.local_participant().unpublish_track(&ss.sid).await;
        }
    }

    async fn handle_cmd(&mut self, cmd: Cmd) {
        match cmd {
            Cmd::MicMuted(muted) => {
                if let Some(p) = self.mic_pub.as_ref() {
                    if muted {
                        p.mute();
                    } else {
                        p.unmute();
                    }
                }
            }
            Cmd::Screen(on) => {
                if on {
                    if let Err(e) = self.start_screen().await {
                        self.send(UiEvent::Error { message: e });
                    }
                } else {
                    self.stop_screen().await;
                }
            }
            Cmd::Data { topic, payload } => {
                let packet = DataPacket {
                    payload,
                    topic: Some(topic),
                    reliable: true,
                    destination_identities: Vec::new(),
                };
                if let Err(e) = self.room.local_participant().publish_data(packet).await {
                    self.send(UiEvent::Error { message: e.to_string() });
                }
            }
            _ => {}
        }
    }

    async fn shutdown(&mut self) {
        self.stop_screen().await;
        let _ = self.room.close().await;
    }

    /// 返回 false 表示会话应结束
    fn handle_lk_event(&mut self, ev: livekit::RoomEvent) -> bool {
        use livekit::RoomEvent as Lk;
        match ev {
            Lk::Connected { participants_with_tracks } => {
                self.connected.store(true, Ordering::Relaxed);
                self.send(UiEvent::Connected {
                    room: self.room.name(),
                    recording: self.recording,
                });
                for (p, pubs) in participants_with_tracks {
                    self.send(UiEvent::ParticipantJoined {
                        identity: p.identity().to_string(),
                        display_name: p.name(),
                    });
                    let identity = p.identity().to_string();
                    for pub_ in pubs {
                        self.send(UiEvent::TrackPublished {
                            identity: identity.clone(),
                            kind: map_kind(pub_.kind(), pub_.source()),
                            sid: pub_.sid().to_string(),
                        });
                    }
                }
            }
            Lk::ParticipantConnected(p) => {
                self.send(UiEvent::ParticipantJoined {
                    identity: p.identity().to_string(),
                    display_name: p.name(),
                });
            }
            Lk::ParticipantDisconnected(p) => {
                self.send(UiEvent::ParticipantLeft { identity: p.identity().to_string() });
            }
            Lk::TrackPublished { publication, participant } => {
                self.send(UiEvent::TrackPublished {
                    identity: participant.identity().to_string(),
                    kind: map_kind(publication.kind(), publication.source()),
                    sid: publication.sid().to_string(),
                });
            }
            Lk::TrackUnpublished { publication, participant } => {
                self.send(UiEvent::TrackUnpublished {
                    identity: participant.identity().to_string(),
                    sid: publication.sid().to_string(),
                });
            }
            Lk::TrackSubscribed { track, publication, participant } => {
                if let RemoteTrack::Video(video) = &track {
                    let identity = participant.identity().to_string();
                    let sid = publication.sid().to_string();
                    let ev_tx = self.ev_tx.clone();
                    let mut stream = NativeVideoStream::new(video.rtc_track());
                    tokio::spawn(async move {
                        while let Some(frame) = stream.next().await {
                            let w = frame.buffer.width();
                            let h = frame.buffer.height();
                            if w == 0 || h == 0 {
                                continue;
                            }
                            let mut rgba = vec![0u8; (w * h * 4) as usize];
                            frame.buffer.to_argb(
                                VideoFormatType::RGBA,
                                &mut rgba,
                                w * 4,
                                w as i32,
                                h as i32,
                            );
                            let _ = ev_tx.send(UiEvent::VideoFrame {
                                identity: identity.clone(),
                                sid: sid.clone(),
                                frame: UiVideoFrame { width: w, height: h, rgba },
                            });
                        }
                    });
                }
            }
            Lk::ActiveSpeakersChanged { speakers } => {
                let cur: Vec<String> =
                    speakers.iter().map(|s| s.identity().to_string()).collect();
                for id in &cur {
                    if !self.speakers.contains(id) {
                        self.send(UiEvent::Speaking { identity: id.clone(), active: true });
                    }
                }
                for id in &self.speakers {
                    if !cur.contains(id) {
                        self.send(UiEvent::Speaking { identity: id.clone(), active: false });
                    }
                }
                self.speakers = cur;
            }
            Lk::DataReceived { payload, topic, participant, .. } => {
                let Some(topic) = topic else { return true };
                let Some(p) = participant else { return true };
                let identity = p.identity().to_string();
                let text = String::from_utf8_lossy(&payload).to_string();
                match topic.as_str() {
                    TOPIC_CHAT => self.send(UiEvent::Chat { identity, text }),
                    TOPIC_RAISE_HAND => {
                        let raised = serde_json::from_str::<serde_json::Value>(&text)
                            .ok()
                            .and_then(|v| v.get("raised").and_then(|r| r.as_bool()))
                            .unwrap_or(false);
                        self.send(UiEvent::RaiseHand { identity, raised });
                    }
                    TOPIC_REACTION => {
                        let emoji = serde_json::from_str::<serde_json::Value>(&text)
                            .ok()
                            .and_then(|v| {
                                v.get("emoji").and_then(|e| e.as_str()).map(str::to_string)
                            })
                            .unwrap_or_else(|| "👍".into());
                        self.send(UiEvent::Reaction { identity, emoji });
                    }
                    _ => {}
                }
            }
            Lk::ChatMessage { message, participant } => {
                // 兼容 SDK 层 chat（lk.chat 由服务端转成 ChatMessage 事件）
                let identity = participant
                    .map(|p| p.identity().to_string())
                    .unwrap_or_else(|| self.room.local_participant().identity().to_string());
                self.send(UiEvent::Chat { identity, text: message.message });
            }
            Lk::RoomUpdated { room } => {
                if room.active_recording != self.recording {
                    self.recording = room.active_recording;
                    self.send(UiEvent::Connected { room: room.name, recording: self.recording });
                }
            }
            Lk::Disconnected { reason } => {
                self.connected.store(false, Ordering::Relaxed);
                self.send(UiEvent::Disconnected { reason: format!("{reason:?}") });
                return false;
            }
            Lk::ConnectionStateChanged(ConnectionState::Disconnected) => {
                self.connected.store(false, Ordering::Relaxed);
                self.send(UiEvent::Disconnected { reason: "connection closed".into() });
                return false;
            }
            _ => {}
        }
        true
    }
}

pub struct LiveKitRoomClient {
    ev_rx: Option<mpsc::UnboundedReceiver<UiEvent>>,
    cmd_tx: mpsc::UnboundedSender<Cmd>,
    connected: Arc<AtomicBool>,
}

impl LiveKitRoomClient {
    pub fn new() -> Self {
        let (ev_tx, ev_rx) = mpsc::unbounded_channel();
        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<Cmd>();
        let connected = Arc::new(AtomicBool::new(false));
        let connected_thread = Arc::clone(&connected);

        std::thread::Builder::new()
            .name("lk-runtime".into())
            .spawn(move || {
                let rt = tokio::runtime::Builder::new_multi_thread()
                    .enable_all()
                    .build()
                    .expect("tokio runtime");
                rt.block_on(async move {
                    loop {
                        // 会话外：只接受 Join / Leave
                        let Some(cmd) = cmd_rx.recv().await else { break };
                        let Cmd::Join(opts) = cmd else { continue };

                        match Room::connect(
                            &opts.server_url,
                            &opts.token,
                            RoomOptions::default(),
                        )
                        .await
                        {
                            Err(e) => {
                                let _ = ev_tx.send(UiEvent::Error {
                                    message: e.to_string(),
                                });
                            }
                            Ok((room, mut lk_rx)) => {
                                let mut st = RoomState {
                                    room,
                                    ev_tx: ev_tx.clone(),
                                    connected: Arc::clone(&connected_thread),
                                    _audio: None,
                                    mic_pub: None,
                                    screen: None,
                                    speakers: Vec::new(),
                                    recording: false,
                                };
                                st.setup_audio(&opts).await;

                                // 会话内：事件与命令合流
                                let leave_requested = loop {
                                    tokio::select! {
                                        biased;
                                        ev = lk_rx.recv() => {
                                            match ev {
                                                Some(ev) => {
                                                    if !st.handle_lk_event(ev) {
                                                        break false;
                                                    }
                                                }
                                                None => break false,
                                            }
                                        }
                                        c = cmd_rx.recv() => {
                                            match c {
                                                None => break false,
                                                Some(Cmd::Leave) => break true,
                                                Some(Cmd::Join(_)) => {}
                                                Some(c) => st.handle_cmd(c).await,
                                            }
                                        }
                                    }
                                };

                                st.shutdown().await;
                                connected_thread.store(false, Ordering::Relaxed);
                                if leave_requested {
                                    let _ = ev_tx.send(UiEvent::Disconnected {
                                        reason: "client leave".into(),
                                    });
                                }
                            }
                        }
                    }
                });
            })
            .expect("spawn lk-runtime thread");

        Self { ev_rx: Some(ev_rx), cmd_tx, connected }
    }

    fn cmd(&self, c: Cmd) -> Result<()> {
        self.cmd_tx
            .send(c)
            .map_err(|e| MeetingError::Sdk(format!("lk cmd channel closed: {e}")))
    }

    fn require_connected(&self) -> Result<()> {
        if self.connected.load(Ordering::Relaxed) {
            Ok(())
        } else {
            Err(MeetingError::NotConnected)
        }
    }
}

impl RoomClient for LiveKitRoomClient {
    fn take_events(&mut self) -> Option<mpsc::UnboundedReceiver<UiEvent>> {
        self.ev_rx.take()
    }

    fn join(&self, opts: JoinOptions) -> Result<()> {
        self.cmd(Cmd::Join(opts))
    }

    fn leave(&self) {
        let _ = self.cmd(Cmd::Leave);
    }

    fn is_connected(&self) -> bool {
        self.connected.load(Ordering::Relaxed)
    }

    fn set_mic_muted(&self, muted: bool) -> Result<()> {
        self.require_connected()?;
        self.cmd(Cmd::MicMuted(muted))
    }

    fn set_screen_share(&self, on: bool) -> Result<()> {
        self.require_connected()?;
        self.cmd(Cmd::Screen(on))
    }

    fn send_chat(&self, text: &str) -> Result<()> {
        self.require_connected()?;
        self.cmd(Cmd::Data {
            topic: TOPIC_CHAT.into(),
            payload: text.as_bytes().to_vec(),
        })
    }

    fn raise_hand(&self, raised: bool) -> Result<()> {
        self.require_connected()?;
        let payload = serde_json::json!({ "raised": raised }).to_string();
        self.cmd(Cmd::Data {
            topic: TOPIC_RAISE_HAND.into(),
            payload: payload.into_bytes(),
        })
    }

    fn send_reaction(&self, emoji: &str) -> Result<()> {
        self.require_connected()?;
        let payload = serde_json::json!({ "emoji": emoji }).to_string();
        self.cmd(Cmd::Data {
            topic: TOPIC_REACTION.into(),
            payload: payload.into_bytes(),
        })
    }
}
