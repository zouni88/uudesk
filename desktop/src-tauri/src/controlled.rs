//! 被控端：QUIC 监听（§2）、屏幕采集→H.264 编码→§4 帧发送、输入注入（§3.2）。

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tauri::{AppHandle, State};
use uu_proto::ControlMsg;
use uu_screen::{CaptureBackend, VideoEncoder};
use uu_transport::{Connection, Identity, PinPolicy, Server};

use crate::device;
use crate::session::{emit_status, SessionState};

/// 被控端默认监听端口
pub const CONTROLLED_PORT: u16 = 4433;
/// 采集帧率
const FPS: u32 = 30;

pub struct ControlledSession {
    pub endpoint: quinn::Endpoint,
    pub cancel: Arc<AtomicBool>,
    pub tasks: Arc<Mutex<Vec<tokio::task::JoinHandle<()>>>>,
}

fn take_controlled(state: &SessionState) -> Option<ControlledSession> {
    state.controlled.lock().unwrap_or_else(|e| e.into_inner()).take()
}

fn stop_controlled(sess: ControlledSession) {
    sess.cancel.store(true, Ordering::Relaxed);
    let _ = sess.endpoint.close(quinn::VarInt::from_u32(0), b"stop");
    if let Ok(mut g) = sess.tasks.lock() {
        for t in g.drain(..) {
            t.abort();
        }
    }
}

#[tauri::command]
pub async fn controlled_start(app: AppHandle, state: State<'_, SessionState>) -> Result<(), String> {
    if let Some(old) = take_controlled(&state) {
        stop_controlled(old);
    }
    let identity = Arc::new(device::load_identity()?);
    let name = device::computer_name();
    // 预检平台能力：编码/注入不可用则直接返回明确错误，不进入监听
    uu_screen::H264Encoder::new(4_000_000, FPS as f32)
        .map_err(|e| format!("H.264 编码不可用: {e}"))?;
    uu_input::InputInjector::new().map_err(|e| format!("输入注入不可用: {e}"))?;
    uu_screen::XcapCapture
        .monitors()
        .map_err(|e| format!("屏幕采集不可用: {e}"))?;

    let addr: SocketAddr = ([0, 0, 0, 0], CONTROLLED_PORT).into();
    let mut server = Server::bind(Arc::clone(&identity), addr, PinPolicy::AllowAny)
        .map_err(|e| format!("被控监听 {addr} 失败: {e}"))?;
    let endpoint = server.endpoint().clone();
    let cancel = Arc::new(AtomicBool::new(false));
    let tasks: Arc<Mutex<Vec<tokio::task::JoinHandle<()>>>> = Arc::new(Mutex::new(Vec::new()));

    {
        let app = app.clone();
        let identity = Arc::clone(&identity);
        let cancel = Arc::clone(&cancel);
        let tasks = Arc::clone(&tasks);
        tokio::spawn(async move {
            loop {
                if cancel.load(Ordering::Relaxed) {
                    break;
                }
                match server.accept().await {
                    Some(c) => {
                        let h = tokio::spawn(controlled_session(
                            app.clone(),
                            Arc::clone(&identity),
                            name.clone(),
                            c,
                            Arc::clone(&cancel),
                        ));
                        if let Ok(mut g) = tasks.lock() {
                            g.push(h);
                        }
                    }
                    None => break,
                }
            }
        });
    }

    *state.controlled.lock().unwrap_or_else(|e| e.into_inner()) =
        Some(ControlledSession { endpoint, cancel, tasks });
    emit_status(&app, true, "connected", &format!("被控端已监听 :{CONTROLLED_PORT}"));
    Ok(())
}

#[tauri::command]
pub async fn controlled_stop(app: AppHandle, state: State<'_, SessionState>) -> Result<(), String> {
    if let Some(sess) = take_controlled(&state) {
        stop_controlled(sess);
    }
    emit_status(&app, false, "disconnected", "被控端已停止");
    Ok(())
}

/// 单条被控会话：采集编码循环 + 控制消息处理（input 注入 / keyframe_req / 握手）
async fn controlled_session(
    app: AppHandle,
    identity: Arc<Identity>,
    name: String,
    conn: Connection,
    cancel: Arc<AtomicBool>,
) {
    let peer = conn.peer_pin().unwrap_or("").to_string();
    emit_status(&app, true, "connected", &format!("被控会话已建立（对端 {peer}）"));

    let mut control_rx = match conn.take_control_rx() {
        Some(r) => r,
        None => {
            emit_status(&app, false, "error", "控制流不可用");
            return;
        }
    };
    let mut encoder = match uu_screen::H264Encoder::new(4_000_000, FPS as f32) {
        Ok(e) => e,
        Err(e) => {
            emit_status(&app, false, "error", &format!("H.264 编码不可用: {e}"));
            return;
        }
    };
    let mut injector = match uu_input::InputInjector::new() {
        Ok(i) => Some(i),
        Err(e) => {
            emit_status(&app, false, "error", &format!("输入注入不可用: {e}"));
            None
        }
    };

    let _ = conn.control().send(ControlMsg::Hello {
        role: "pc".to_string(),
        device_id: identity.device_id.clone(),
        name: name.clone(),
        proto: uu_proto::PROTO_VERSION,
    });

    let screen_w = Arc::new(AtomicU32::new(0));
    let screen_h = Arc::new(AtomicU32::new(0));
    let mut force_key = true;
    let mut meta_sent = false;
    let mut seq: u32 = 0;
    let start = Instant::now();
    let mut ticker = tokio::time::interval(Duration::from_millis(1000 / FPS as u64));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        tokio::select! {
            m = control_rx.recv() => {
                match m {
                    Some(ControlMsg::Input { ev }) => {
                        if let Some(inj) = &mut injector {
                            let (w, h) = (screen_w.load(Ordering::Relaxed), screen_h.load(Ordering::Relaxed));
                            if w > 0 && h > 0 {
                                if let Err(e) = inj.apply(&ev, w, h) {
                                    tracing::debug!("inject err: {e}");
                                }
                            }
                        }
                    }
                    Some(ControlMsg::KeyframeReq) => {
                        force_key = true;
                    }
                    Some(ControlMsg::Hello { device_id, name: pn, .. }) => {
                        let _ = conn.control().send(ControlMsg::HelloAck { device_id, name: pn });
                    }
                    Some(ControlMsg::Ping { ts, id }) => {
                        let _ = conn.control().send(ControlMsg::Pong { ts, id });
                    }
                    Some(ControlMsg::SessionClose) | None => break,
                    _ => {}
                }
            }
            _ = ticker.tick() => {
                let cap = tokio::task::spawn_blocking(move || {
                    let c = uu_screen::XcapCapture;
                    c.capture(0)
                })
                .await;
                let frame = match cap {
                    Ok(Ok(f)) => f,
                    Ok(Err(e)) => {
                        emit_status(&app, false, "error", &format!("屏幕采集失败: {e}"));
                        break;
                    }
                    Err(_) => break,
                };
                screen_w.store(frame.width as u32, Ordering::Relaxed);
                screen_h.store(frame.height as u32, Ordering::Relaxed);
                if !meta_sent {
                    meta_sent = true;
                    let _ = conn.control().send(ControlMsg::ScreenMeta {
                        w: frame.width as u32,
                        h: frame.height as u32,
                        scale: 1.0,
                        rotation: 0,
                        codec: "h264".to_string(),
                    });
                }
                let pts_us = start.elapsed().as_micros() as u64;
                let encoded = match encoder.encode(&frame.rgba, frame.width, frame.height, force_key, pts_us) {
                    Ok(e) => {
                        force_key = false;
                        e
                    }
                    Err(e) => {
                        tracing::debug!("encode err: {e}");
                        continue;
                    }
                };
                if conn
                    .send_video_frame(&encoded.annexb, seq, pts_us, encoded.keyframe, frame.width, frame.height)
                    .await
                    .is_err()
                {
                    break;
                }
                seq = seq.wrapping_add(1);
            }
        }
    }
    conn.close(0, "controlled session end");
    emit_status(&app, false, "disconnected", "被控会话已结束");
}
