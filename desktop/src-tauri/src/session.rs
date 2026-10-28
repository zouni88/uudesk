//! 控制端会话编排：配对信令（§8）、打洞/中继、握手、视频接收循环、输入发送。

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};
use tokio::sync::mpsc;
use uu_proto::ControlMsg;
use uu_transport::signaling::{api_pair, api_reflect, api_register, SignalMsg, SignalingClient};
use uu_transport::{connect, connect_pairing, endpoint::RELAY_PORT, punch, relay_connect, Identity};

use crate::conn::{Conn, RelayConn};
use crate::device;
use crate::frame::{self, FramePayload};

/// `uu://status` 事件负载（字段名与前端契约一致）
#[derive(Clone, Serialize)]
pub struct StatusPayload {
    pub connected: bool,
    pub phase: String,
    pub msg: String,
}

pub fn emit_status(app: &AppHandle, connected: bool, phase: &str, msg: &str) {
    let _ = app.emit(
        "uu://status",
        StatusPayload { connected, phase: phase.to_string(), msg: msg.to_string() },
    );
}

/// PeerInfo：连接成功后返回的对端信息
#[derive(Clone, Serialize)]
pub struct PeerInfo {
    pub peer_name: String,
    pub peer_device_id: String,
}

pub(crate) struct ControllerSession {
    conn: Arc<Conn>,
    cancel: Arc<AtomicBool>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

/// Managed 状态：控制端会话 + 被控端监听
#[derive(Default)]
pub struct SessionState {
    pub(crate) controller: Mutex<Option<ControllerSession>>,
    pub(crate) controlled: Mutex<Option<crate::controlled::ControlledSession>>,
}

fn teardown(sess: ControllerSession) {
    sess.cancel.store(true, Ordering::Relaxed);
    sess.conn.close();
    for t in sess.tasks {
        t.abort();
    }
}

fn take_controller(state: &SessionState) -> Option<ControllerSession> {
    state.controller.lock().unwrap_or_else(|e| e.into_inner()).take()
}

fn store_controller(state: &SessionState, sess: ControllerSession) {
    *state.controller.lock().unwrap_or_else(|e| e.into_inner()) = Some(sess);
}

// ---------------- 控制端命令 ----------------

#[tauri::command]
pub async fn remote_connect(
    app: AppHandle,
    state: State<'_, SessionState>,
    server_url: String,
    code: String,
) -> Result<PeerInfo, String> {
    let server = server_url.trim_end_matches('/').to_string();
    let identity = Arc::new(device::load_identity()?);
    let name = device::computer_name();
    if let Some(old) = take_controller(&state) {
        teardown(old);
        emit_status(&app, false, "disconnected", "已断开原有会话");
    }
    let (conn, peer_id) = match connect_flow(&app, &server, &code, &identity, &name).await {
        Ok(v) => v,
        Err(e) => {
            emit_status(&app, false, "error", &e);
            return Err(e);
        }
    };
    match finish_session(&app, &state, conn, identity, &name, peer_id).await {
        Ok(p) => Ok(p),
        Err(e) => {
            emit_status(&app, false, "error", &e);
            Err(e)
        }
    }
}

#[tauri::command]
pub async fn remote_connect_direct(
    app: AppHandle,
    state: State<'_, SessionState>,
    addr: String,
    pin_b32: String,
) -> Result<PeerInfo, String> {
    let sa: SocketAddr = addr.parse().map_err(|e| format!("地址非法 {addr}: {e}"))?;
    let identity = Arc::new(device::load_identity()?);
    let name = device::computer_name();
    if let Some(old) = take_controller(&state) {
        teardown(old);
        emit_status(&app, false, "disconnected", "已断开原有会话");
    }
    emit_status(&app, false, "punching", &format!("直连 {addr}…"));
    let r = if pin_b32.is_empty() {
        connect_pairing(Arc::clone(&identity), sa).await
    } else {
        connect(Arc::clone(&identity), sa, &pin_b32).await
    };
    let conn = match r {
        Ok(c) => Arc::new(Conn::Direct(c)),
        Err(e) => {
            let msg = format!("直连失败: {e}");
            emit_status(&app, false, "error", &msg);
            return Err(msg);
        }
    };
    let fallback = if pin_b32.is_empty() { None } else { Some(pin_b32) };
    match finish_session(&app, &state, conn, identity, &name, fallback).await {
        Ok(p) => Ok(p),
        Err(e) => {
            emit_status(&app, false, "error", &e);
            Err(e)
        }
    }
}

#[tauri::command]
pub async fn remote_disconnect(app: AppHandle, state: State<'_, SessionState>) -> Result<(), String> {
    if let Some(sess) = take_controller(&state) {
        teardown(sess);
    }
    emit_status(&app, false, "disconnected", "已断开");
    Ok(())
}

#[tauri::command]
pub fn remote_input(state: State<'_, SessionState>, json: String) -> Result<(), String> {
    let m: ControlMsg = serde_json::from_str(&json).map_err(|e| format!("控制消息非法: {e}"))?;
    let guard = state.controller.lock().unwrap_or_else(|e| e.into_inner());
    let sess = guard.as_ref().ok_or("当前没有活动会话")?;
    if sess.cancel.load(Ordering::Relaxed) {
        return Err("会话已断开".into());
    }
    sess.conn.send_control(m)
}

#[tauri::command]
pub fn remote_request_keyframe(state: State<'_, SessionState>) -> Result<(), String> {
    let guard = state.controller.lock().unwrap_or_else(|e| e.into_inner());
    let sess = guard.as_ref().ok_or("当前没有活动会话")?;
    sess.conn.send_control(ControlMsg::KeyframeReq)
}

// ---------------- 配对/打洞/中继流程（§8） ----------------

async fn connect_flow(
    app: &AppHandle,
    server: &str,
    code: &str,
    identity: &Arc<Identity>,
    name: &str,
) -> Result<(Arc<Conn>, Option<String>), String> {
    // 1. 注册本机
    emit_status(app, false, "registering", "注册设备…");
    let reg = api_register(server, name, "pc", &identity.device_id, &identity.device_id)
        .await
        .map_err(|e| format!("注册失败: {e}"))?;
    let token = reg
        .get("token")
        .and_then(|t| t.as_str())
        .unwrap_or("")
        .to_string();

    // 2. 信令 WS
    emit_status(app, false, "signaling", "连接信令服务器…");
    let mut sig = SignalingClient::connect(server, if token.is_empty() { None } else { Some(&token) })
        .await
        .map_err(|e| format!("信令连接失败: {e}"))?;

    // 3. 配对码发起邀请，等待接受
    emit_status(app, false, "signaling", &format!("用配对码 {code} 邀请对端…"));
    api_pair(server, code, &identity.device_id)
        .await
        .map_err(|e| format!("配对失败: {e}"))?;
    wait_invite_result(&mut sig).await?;

    // 4. 上报自身 candidates，取得对端地址
    emit_status(app, false, "punching", "交换候选地址…");
    let my_addrs = api_reflect(server).await.unwrap_or_default();
    let _ = sig.send(&SignalMsg::Candidates { peer: String::new(), addrs: my_addrs });
    let (peer_id, peer_addrs) = wait_candidates(&mut sig).await?;

    // 5. 打洞直连
    let mut conn_opt: Option<Conn> = None;
    for a in peer_addrs.iter().take(4) {
        let Ok(sa) = a.parse::<SocketAddr>() else { continue };
        emit_status(app, false, "punching", &format!("尝试直连 {a}…"));
        let _ = punch(sa).await;
        let idc = Arc::clone(identity);
        let pin = peer_id.clone();
        let r = tokio::time::timeout(Duration::from_secs(5), async move {
            match pin {
                Some(p) => connect(idc, sa, &p).await,
                None => connect_pairing(idc, sa).await,
            }
        })
        .await;
        match r {
            Ok(Ok(c)) => {
                conn_opt = Some(Conn::Direct(c));
                break;
            }
            _ => continue,
        }
    }

    // 6. 失败走服务器中继
    let conn = match conn_opt {
        Some(c) => {
            drop(sig);
            c
        }
        None => {
            let peer_for_relay = peer_id
                .clone()
                .ok_or_else(|| "中继需要配对端 device_id，但未取得".to_string())?;
            emit_status(app, false, "relay", "直连失败，改走服务器中继…");
            let _ = sig.send(&SignalMsg::RelayOpen { peer: peer_for_relay.clone() });
            let host = server_host(server)?;
            let sa = tokio::time::timeout(
                Duration::from_secs(5),
                resolve((host.as_str(), RELAY_PORT)),
            )
            .await
            .map_err(|_| "解析服务器中继地址超时".to_string())?
            .map_err(|e| format!("解析服务器中继地址失败: {e}"))?;
            let relay = relay_connect(Arc::clone(identity), sa, &peer_for_relay)
                .await
                .map_err(|e| format!("中继连接失败: {e}"))?;
            drop(sig);
            Conn::Relay(RelayConn::new(relay))
        }
    };
    Ok((Arc::new(conn), peer_id))
}

async fn resolve(addr: (&str, u16)) -> Result<SocketAddr, std::io::Error> {
    let mut it = tokio::net::lookup_host(addr).await?;
    it.next().ok_or_else(|| std::io::Error::new(std::io::ErrorKind::Other, "no dns result"))
}

async fn wait_invite_result(sig: &mut SignalingClient) -> Result<(), String> {
    let r = tokio::time::timeout(Duration::from_secs(60), async {
        loop {
            match sig.rx.recv().await {
                Some((SignalMsg::InviteResult { accept, .. }, _)) => {
                    if accept {
                        return Ok::<(), String>(());
                    }
                    return Err("对端拒绝了连接邀请".to_string());
                }
                Some(_) => continue,
                None => return Err("信令连接中断".to_string()),
            }
        }
    })
    .await;
    r.map_err(|_| "等待对端接受超时".to_string())?
}

async fn wait_candidates(sig: &mut SignalingClient) -> Result<(Option<String>, Vec<String>), String> {
    let r = tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            match sig.rx.recv().await {
                Some((SignalMsg::Candidates { peer, addrs }, _)) => {
                    let pid = if peer.is_empty() { None } else { Some(peer) };
                    return Ok::<_, String>((pid, addrs));
                }
                Some(_) => continue,
                None => return Err("信令连接中断".to_string()),
            }
        }
    })
    .await;
    r.map_err(|_| "等待对端候选地址超时".to_string())?
}

fn server_host(server: &str) -> Result<String, String> {
    let s = server
        .trim_start_matches("https://")
        .trim_start_matches("http://")
        .trim_start_matches("wss://")
        .trim_start_matches("ws://");
    let host = s.split('/').next().unwrap_or(s).split(':').next().unwrap_or(s);
    if host.is_empty() {
        return Err(format!("无法从服务器地址取主机名: {server}"));
    }
    Ok(host.to_string())
}

// ---------------- 握手 + 会话装配 ----------------

async fn finish_session(
    app: &AppHandle,
    state: &SessionState,
    conn: Arc<Conn>,
    identity: Arc<Identity>,
    name: &str,
    fallback_peer: Option<String>,
) -> Result<PeerInfo, String> {
    let mut control_rx = conn
        .take_control_rx()
        .ok_or_else(|| "控制流不可用".to_string())?;
    emit_status(app, false, "handshake", "会话握手中…");
    let peer = match handshake(&conn, &mut control_rx, &identity, name, fallback_peer).await {
        Ok(p) => p,
        Err(e) => {
            conn.close();
            return Err(e);
        }
    };
    let video_rx = conn
        .take_video_rx()
        .ok_or_else(|| "视频流通道不可用".to_string())?;

    let cancel = Arc::new(AtomicBool::new(false));
    let mut tasks = Vec::new();
    tasks.push(tokio::spawn(video_loop(
        app.clone(),
        Arc::clone(&conn),
        video_rx,
        Arc::clone(&cancel),
    )));
    tasks.push(tokio::spawn(control_loop(
        app.clone(),
        Arc::clone(&conn),
        control_rx,
        Arc::clone(&cancel),
    )));
    store_controller(state, ControllerSession { conn, cancel, tasks });
    emit_status(app, true, "connected", &format!("已连接 {}", peer.peer_name));
    Ok(peer)
}

async fn handshake(
    conn: &Conn,
    rx: &mut mpsc::UnboundedReceiver<ControlMsg>,
    identity: &Identity,
    name: &str,
    fallback_peer: Option<String>,
) -> Result<PeerInfo, String> {
    conn.send_control(ControlMsg::Hello {
        role: "pc".to_string(),
        device_id: identity.device_id.clone(),
        name: name.to_string(),
        proto: uu_proto::PROTO_VERSION,
    })?;
    let res = tokio::time::timeout(Duration::from_secs(10), async {
        let mut peer_role = String::new();
        let mut dev = String::new();
        let mut nm = String::new();
        loop {
            match rx.recv().await {
                Some(ControlMsg::Hello { role, device_id, name: pn, .. }) => {
                    peer_role = role;
                    if dev.is_empty() {
                        dev = device_id;
                    }
                    if nm.is_empty() {
                        nm = pn;
                    }
                }
                Some(ControlMsg::HelloAck { device_id, name: pn }) => {
                    dev = device_id;
                    nm = pn;
                    break;
                }
                Some(ControlMsg::Error { code, msg }) => {
                    return Err(format!("对端错误 {code}: {msg}"));
                }
                Some(_) => {}
                None => return Err("控制流中断".to_string()),
            }
        }
        Ok::<_, String>((peer_role, dev, nm))
    })
    .await;
    let (peer_role, mut peer_device_id, peer_name) =
        res.map_err(|_| "等待对端握手超时".to_string())??;
    if peer_device_id.is_empty() {
        peer_device_id = fallback_peer.unwrap_or_default();
    }
    let mode = if peer_role == "phone" { "control_phone" } else { "view_pc" };
    conn.send_control(ControlMsg::SessionOpen { mode: mode.to_string(), caps: Vec::new() })?;
    if mode == "control_phone" {
        let _ = conn.send_control(ControlMsg::CapStart);
    }
    Ok(PeerInfo { peer_name, peer_device_id })
}

// ---------------- 视频接收循环 ----------------

async fn video_loop(
    app: AppHandle,
    conn: Arc<Conn>,
    mut rx: mpsc::UnboundedReceiver<Vec<u8>>,
    cancel: Arc<AtomicBool>,
) {
    let mut decoder = match uu_screen::H264Decoder::new() {
        Ok(d) => d,
        Err(e) => {
            emit_status(&app, false, "error", &format!("H.264 解码不可用: {e}"));
            return;
        }
    };
    use uu_screen::VideoDecoder;
    let mut last_seq: Option<u32> = None;
    let mut have_key = false;
    let mut gap_req = std::time::Instant::now();
    while let Some(data) = rx.recv().await {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        let Some((hdr, nal)) = frame::parse_video_frame(&data) else {
            continue;
        };
        // 丢帧检测：跳号则请求 IDR，并丢弃直到下一个关键帧
        if let Some(ls) = last_seq {
            if hdr.seq != ls.wrapping_add(1) {
                have_key = false;
                if gap_req.elapsed() > Duration::from_millis(500) {
                    gap_req = std::time::Instant::now();
                    let _ = conn.send_control(ControlMsg::KeyframeReq);
                }
            }
        }
        last_seq = Some(hdr.seq);
        if !have_key && !hdr.keyframe {
            continue;
        }
        match decoder.decode(nal) {
            Ok(Some(df)) => {
                have_key = true;
                let jpeg = match frame::encode_jpeg(&df.rgba, df.width, df.height) {
                    Ok(j) => j,
                    Err(_) => continue,
                };
                let _ = app.emit(
                    "uu://frame",
                    FramePayload {
                        seq: hdr.seq,
                        key: hdr.keyframe,
                        w: df.width,
                        h: df.height,
                        ts_us: hdr.pts_us,
                        jpeg_b64: base64::engine::general_purpose::STANDARD.encode(&jpeg),
                    },
                );
            }
            Ok(None) => {}
            Err(_) => {
                have_key = false;
                let _ = conn.send_control(ControlMsg::KeyframeReq);
            }
        }
    }
}

// ---------------- 控制消息接收循环 ----------------

async fn control_loop(
    app: AppHandle,
    conn: Arc<Conn>,
    mut rx: mpsc::UnboundedReceiver<ControlMsg>,
    cancel: Arc<AtomicBool>,
) {
    while let Some(m) = rx.recv().await {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        match m {
            ControlMsg::Ping { ts, id } => {
                let _ = conn.send_control(ControlMsg::Pong { ts, id });
            }
            ControlMsg::Hello { device_id, name, .. } => {
                let _ = conn.send_control(ControlMsg::HelloAck { device_id, name });
            }
            ControlMsg::Error { code, msg } => {
                emit_status(&app, false, "error", &format!("对端错误 {code}: {msg}"));
            }
            ControlMsg::SessionClose => break,
            _ => {}
        }
    }
    if !cancel.load(Ordering::Relaxed) {
        cancel.store(true, Ordering::Relaxed);
        emit_status(&app, false, "disconnected", "会话已结束");
    }
}
