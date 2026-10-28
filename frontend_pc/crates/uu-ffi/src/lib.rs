//! uu-ffi：附录 B C ABI（cdylib/staticlib）。
//! 数据/事件回调经 std::sync::mpsc 转发到专用线程，保证 C 回调单线程触发。

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};

use uu_proto::{decode_msg, FileHeader, FILE_HEADER_LEN};
use uu_transport::{connect_with_policy, Connection, FileChunk, Identity, PinPolicy, Server};

/// 通道编号（附录 B）
pub const UU_CH_CONTROL: u8 = 0;
pub const UU_CH_VIDEO: u8 = 1;
pub const UU_CH_AUDIO: u8 = 2;
pub const UU_CH_FILE: u8 = 3;

/// 数据回调：data 仅回调期间有效
pub type UuDataCb = Option<unsafe extern "C" fn(*mut c_void, u8, u64, *const u8, u32)>;
/// 事件回调：event_json = {"t":"connected"|"disconnected"|"error",...}
pub type UuEventCb = Option<unsafe extern "C" fn(*mut c_void, *const c_char)>;

thread_local! {
    static LAST_ERR: Mutex<CString> = Mutex::new(CString::default());
}

fn set_err(s: &str) {
    let c = CString::new(s.to_string()).unwrap_or_default();
    LAST_ERR.with(|e| *e.lock().unwrap() = c);
}

enum CbMsg {
    Data { channel: u8, conn_id: u64, data: Vec<u8> },
    Event(CString),
}

struct Callbacks {
    on_data: UuDataCb,
    on_event: UuEventCb,
    ctx: *mut c_void,
}
unsafe impl Send for Callbacks {}

pub struct FfiCtx {
    rt: tokio::runtime::Runtime,
    identity: Arc<Identity>,
    server: tokio::sync::Mutex<Option<Server>>,
    listen_port: Option<u16>,
    conns: Mutex<HashMap<u64, Connection>>,
    cbs: Arc<Mutex<Option<Callbacks>>>,
    /// std Sender 非 Sync，包 Mutex 使 FfiCtx: Sync
    cb_tx: Mutex<Sender<CbMsg>>,
    closing: Arc<AtomicBool>,
}

fn emit(ctx: &FfiCtx, msg: CbMsg) {
    if let Ok(tx) = ctx.cb_tx.lock() {
        let _ = tx.send(msg);
    }
}

/// 回调分发线程主体
fn cbs_send(cbs: &Arc<Mutex<Option<Callbacks>>>, msg: CbMsg) {
    let guard = cbs.lock().unwrap();
    if let Some(cb) = guard.as_ref() {
        match msg {
            CbMsg::Data { channel, conn_id, ref data } => {
                if let Some(f) = cb.on_data {
                    unsafe { f(cb.ctx, channel, conn_id, data.as_ptr(), data.len() as u32) }
                }
            }
            CbMsg::Event(ref json) => {
                if let Some(f) = cb.on_event {
                    unsafe { f(cb.ctx, json.as_ptr()) }
                }
            }
        }
    }
}

fn event_json(v: serde_json::Value) -> CbMsg {
    CbMsg::Event(CString::new(v.to_string()).unwrap_or_default())
}

/// 为一条连接启动各通道上抛转发任务并发 connected 事件
fn register_conn(ctx: &FfiCtx, conn: Connection) {
    let cid = conn.id();
    ctx.conns.lock().unwrap().insert(cid, conn.clone());
    let tx = ctx.cb_tx.lock().unwrap().clone();
    if let Some(mut rx) = conn.take_control_rx() {
        let t = tx.clone();
        ctx.rt.spawn(async move {
            while let Some(m) = rx.recv().await {
                let data = serde_json::to_vec(&m).unwrap_or_default();
                let _ = t.send(CbMsg::Data { channel: UU_CH_CONTROL, conn_id: cid, data });
            }
        });
    }
    for (rx, ch) in [
        (conn.take_video_rx(), UU_CH_VIDEO),
        (conn.take_audio_rx(), UU_CH_AUDIO),
    ] {
        if let Some(mut rx) = rx {
            let t = tx.clone();
            ctx.rt.spawn(async move {
                while let Some(data) = rx.recv().await {
                    let _ = t.send(CbMsg::Data { channel: ch, conn_id: cid, data });
                }
            });
        }
    }
    if let Some(mut rx) = conn.take_file_rx() {
        let t = tx.clone();
        ctx.rt.spawn(async move {
            while let Some(c) = rx.recv().await {
                let FileChunk { id, index, data } = c;
                let hdr = FileHeader { id, chunk_index: index, chunk_len: data.len() as u32 };
                let mut buf = hdr.encode().to_vec();
                buf.extend_from_slice(&data);
                let _ = t.send(CbMsg::Data { channel: UU_CH_FILE, conn_id: cid, data: buf });
            }
        });
    }
    let peer = conn.peer_pin().unwrap_or("").to_string();
    let _ = tx.send(event_json(
        serde_json::json!({"t":"connected","conn_id":cid,"peer":peer}),
    ));
}

// ---------------- 导出函数（附录 B） ----------------

/// config_json = {device_id?, cert_dir, listen_port|null}
#[no_mangle]
pub extern "C" fn uu_ffi_new(config_json: *const c_char) -> *mut c_void {
    let result = catch_unwind(AssertUnwindSafe(|| -> *mut c_void {
        if config_json.is_null() {
            set_err("config_json null");
            return std::ptr::null_mut();
        }
        let json = unsafe { CStr::from_ptr(config_json) }.to_str().unwrap_or("");
        let cfg: serde_json::Value = serde_json::from_str(json).unwrap_or_default();
        let cert_dir = cfg
            .get("cert_dir")
            .and_then(|v| v.as_str())
            .unwrap_or("./uu_identity")
            .to_string();
        let listen_port = cfg.get("listen_port").and_then(|v| v.as_u64()).map(|p| p as u16);
        let identity = match Identity::load_or_create(std::path::Path::new(&cert_dir)) {
            Ok(i) => Arc::new(i),
            Err(e) => {
                set_err(&format!("identity: {e}"));
                return std::ptr::null_mut();
            }
        };
        let rt = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
            Ok(r) => r,
            Err(e) => {
                set_err(&format!("runtime: {e}"));
                return std::ptr::null_mut();
            }
        };
        let (cb_tx, cb_rx) = channel::<CbMsg>();
        let cbs: Arc<Mutex<Option<Callbacks>>> = Arc::new(Mutex::new(None));
        let cbs2 = Arc::clone(&cbs);
        std::thread::spawn(move || {
            while let Ok(m) = cb_rx.recv() {
                cbs_send(&cbs2, m);
            }
        });
        let ctx = FfiCtx {
            rt,
            identity,
            server: tokio::sync::Mutex::new(None),
            listen_port,
            conns: Mutex::new(HashMap::new()),
            cbs,
            cb_tx: Mutex::new(cb_tx),
            closing: Arc::new(AtomicBool::new(false)),
        };
        Box::into_raw(Box::new(ctx)) as *mut c_void
    }));
    match result {
        Ok(p) => p,
        Err(_) => {
            set_err("panic in uu_ffi_new");
            std::ptr::null_mut()
        }
    }
}

/// 0=成功；若配置了 listen_port 则开始监听并接受连接
#[no_mangle]
pub unsafe extern "C" fn uu_ffi_start(h: *mut c_void) -> c_int {
    if h.is_null() {
        set_err("null handle");
        return -1;
    }
    let ctx = unsafe { &*(h as *const FfiCtx) };
    let result = catch_unwind(AssertUnwindSafe(|| -> c_int {
        if let Some(port) = ctx.listen_port {
            let identity = Arc::clone(&ctx.identity);
            let srv = match Server::bind(
                identity,
                std::net::SocketAddr::from(([0, 0, 0, 0], port)),
                PinPolicy::AllowAny,
            ) {
                Ok(s) => s,
                Err(e) => {
                    set_err(&format!("server bind: {e}"));
                    return -2;
                }
            };
            ctx.rt.block_on(async { *ctx.server.lock().await = Some(srv) });
            let closing = Arc::clone(&ctx.closing);
            // accept 循环需要 'static：用 raw 指针重建引用（free 前句柄有效，
            // 且 free 会先置 closing 并关监听使循环退出）
            struct SendPtr(*const FfiCtx);
            // SAFETY: 句柄生命周期由 uu_ffi_free 保证（先置 closing 并关监听，
            // 等 accept 任务退出后才 drop）
            unsafe impl Send for SendPtr {}
            impl SendPtr {
                fn get(&self) -> *const FfiCtx {
                    self.0
                }
            }
            let ctx_ptr = SendPtr(ctx as *const FfiCtx);
            ctx.rt.spawn(async move {
                let ctx: &FfiCtx = unsafe { &*ctx_ptr.get() };
                loop {
                    if closing.load(Ordering::Relaxed) {
                        break;
                    }
                    let conn_opt = {
                        let mut g = ctx.server.lock().await;
                        match g.as_mut() {
                            Some(s) => s.accept().await,
                            None => break,
                        }
                    };
                    match conn_opt {
                        Some(c) => register_conn(ctx, c),
                        None => break,
                    }
                }
            });
        }
        0
    }));
    match result {
        Ok(v) => v,
        Err(_) => {
            set_err("panic in uu_ffi_start");
            -1
        }
    }
}

/// 返回 conn_id；0 表示失败（用 uu_ffi_last_error 取原因）
#[no_mangle]
pub unsafe extern "C" fn uu_ffi_connect(
    h: *mut c_void,
    addr: *const c_char,
    peer_pin_b32: *const c_char,
) -> u64 {
    if h.is_null() || addr.is_null() {
        set_err("null arg");
        return 0;
    }
    let addr_s = unsafe { CStr::from_ptr(addr) }.to_str().unwrap_or("");
    let pin_s = if peer_pin_b32.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(peer_pin_b32) }.to_str().unwrap_or("")
    };
    let ctx = unsafe { &*(h as *const FfiCtx) };
    let sa: std::net::SocketAddr = match addr_s.parse() {
        Ok(s) => s,
        Err(e) => {
            set_err(&format!("bad addr {addr_s}: {e}"));
            return 0;
        }
    };
    let identity = Arc::clone(&ctx.identity);
    let policy = if pin_s.is_empty() {
        PinPolicy::AllowAny
    } else {
        let mut set = std::collections::HashSet::new();
        set.insert(pin_s.to_string());
        PinPolicy::Pinned(set)
    };
    match ctx.rt.block_on(connect_with_policy(identity, sa, policy)) {
        Ok(conn) => {
            let cid = conn.id();
            register_conn(ctx, conn);
            cid
        }
        Err(e) => {
            set_err(&format!("connect: {e}"));
            0
        }
    }
}

/// control=裸 JSON；video/audio/file=帧字节（含帧头）
#[no_mangle]
pub unsafe extern "C" fn uu_ffi_send(
    h: *mut c_void,
    conn_id: u64,
    channel: u8,
    data: *const u8,
    len: u32,
) -> c_int {
    if h.is_null() || data.is_null() {
        set_err("null arg");
        return -1;
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, len as usize) }.to_vec();
    let ctx = unsafe { &*(h as *const FfiCtx) };
    let conn = match ctx.conns.lock().unwrap().get(&conn_id) {
        Some(c) => c.clone(),
        None => {
            set_err(&format!("unknown conn_id {conn_id}"));
            return -2;
        }
    };
    let r = ctx.rt.block_on(async {
        match channel {
            UU_CH_CONTROL => match decode_msg(&bytes) {
                Ok(m) => conn.control().send(m),
                Err(e) => Err(uu_transport::TransportError::Proto(e)),
            },
            UU_CH_VIDEO | UU_CH_AUDIO => conn.send_uni_frame(bytes).await,
            UU_CH_FILE => match FileHeader::decode(&bytes) {
                Ok(hdr) => {
                    let mut sender = conn.open_file_sender().await?;
                    sender.send_chunk(hdr.id, hdr.chunk_index, &bytes[FILE_HEADER_LEN..]).await?;
                    sender.finish().await
                }
                Err(e) => Err(uu_transport::TransportError::Proto(e)),
            },
            _ => Err(uu_transport::TransportError::Other(format!("bad channel {channel}"))),
        }
    });
    match r {
        Ok(()) => 0,
        Err(e) => {
            set_err(&format!("send: {e}"));
            -3
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn uu_ffi_set_callbacks(
    h: *mut c_void,
    on_data: UuDataCb,
    on_event: UuEventCb,
    ctx: *mut c_void,
) {
    if h.is_null() {
        return;
    }
    let ffi = unsafe { &*(h as *const FfiCtx) };
    *ffi.cbs.lock().unwrap() = Some(Callbacks { on_data, on_event, ctx });
}

#[no_mangle]
pub unsafe extern "C" fn uu_ffi_close(h: *mut c_void, conn_id: u64) {
    if h.is_null() {
        return;
    }
    let ffi = unsafe { &*(h as *const FfiCtx) };
    if let Some(conn) = ffi.conns.lock().unwrap().remove(&conn_id) {
        conn.close(0, "closed by ffi");
        emit(
            ffi,
            event_json(serde_json::json!({"t":"disconnected","conn_id":conn_id})),
        );
    }
}

#[no_mangle]
pub unsafe extern "C" fn uu_ffi_free(h: *mut c_void) {
    if h.is_null() {
        return;
    }
    let ctx = unsafe { Box::from_raw(h as *mut FfiCtx) };
    ctx.closing.store(true, Ordering::Relaxed);
    // 关闭监听使 accept 循环退出，再关闭全部连接
    ctx.rt.block_on(async {
        if let Some(s) = ctx.server.lock().await.take() {
            s.close();
        }
    });
    let conns: Vec<Connection> = ctx.conns.lock().unwrap().values().cloned().collect();
    for c in conns {
        c.close(0, "freed");
    }
    // drop(ctx) 释放 cb_tx 与 runtime；runtime 析构等待转发任务随
    // 连接关闭自然结束，分发线程随后因通道断开而退出（分离线程）
    drop(ctx);
}

/// UTF-8，线程局部；返回指针在本线程下次 set 前有效
#[no_mangle]
pub extern "C" fn uu_ffi_last_error(_h: *mut c_void) -> *const c_char {
    LAST_ERR.with(|e| e.lock().unwrap().as_ptr())
}
