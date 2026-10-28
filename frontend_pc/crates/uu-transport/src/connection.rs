//! 连接抽象（§2）：控制流、视频/音频单向流、文件双向流、DATAGRAM。

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use tokio::sync::mpsc;
use uu_proto::{
    decode_len, decode_msg, encode_msg, AudioHeader, ControlMsg, FileHeader, VideoHeader,
    AUDIO_HEADER_LEN, FILE_HEADER_LEN, VIDEO_HEADER_LEN, VIDEO_MAGIC, AUDIO_MAGIC,
};

use crate::error::{Result, TransportError};

/// 单帧最大字节（防御 read_to_end）
const MAX_FRAME: usize = 32 * 1024 * 1024;
/// 单文件 chunk 最大字节
const MAX_CHUNK: usize = uu_proto::FILE_CHUNK_SIZE + 1024;

static NEXT_CONN_ID: AtomicU64 = AtomicU64::new(1);

pub type ConnId = u64;

/// 控制消息发送端（Clone，跨任务共享）
#[derive(Clone)]
pub struct ControlSender {
    tx: mpsc::UnboundedSender<ControlMsg>,
}

impl ControlSender {
    pub fn send(&self, m: ControlMsg) -> Result<()> {
        self.tx.send(m).map_err(|_| TransportError::Other("control stream closed".into()))
    }
}

/// 收到的文件 chunk
#[derive(Debug)]
pub struct FileChunk {
    pub id: u32,
    pub index: u32,
    pub data: Vec<u8>,
}

struct Inner {
    quic: quinn::Connection,
    /// 客户端侧持有 Endpoint 句柄以保活（服务端由 Server 持有）
    _endpoint: Option<quinn::Endpoint>,
    control_tx: ControlSender,
    control_rx: Mutex<Option<mpsc::UnboundedReceiver<ControlMsg>>>,
    video_rx: Mutex<Option<mpsc::UnboundedReceiver<Vec<u8>>>>,
    audio_rx: Mutex<Option<mpsc::UnboundedReceiver<Vec<u8>>>>,
    file_rx: Mutex<Option<mpsc::UnboundedReceiver<FileChunk>>>,
}

/// 一条 QUIC 连接（Arc 内部状态，Clone 廉价）
#[derive(Clone)]
pub struct Connection {
    inner: Arc<Inner>,
    id: ConnId,
    peer_pin: Option<String>,
}

impl Connection {
    pub fn id(&self) -> ConnId {
        self.id
    }

    /// 对端证书 SPKI pin（= device_id），TLS 层校验通过后取得
    pub fn peer_pin(&self) -> Option<&str> {
        self.peer_pin.as_deref()
    }

    pub fn quic(&self) -> &quinn::Connection {
        &self.inner.quic
    }

    pub fn control(&self) -> ControlSender {
        self.inner.control_tx.clone()
    }

    /// 取出控制消息接收端（只能取一次）
    pub fn take_control_rx(&self) -> Option<mpsc::UnboundedReceiver<ControlMsg>> {
        self.inner.control_rx.lock().unwrap().take()
    }

    /// 取出视频帧接收端：每帧完整字节（含 §4 帧头）
    pub fn take_video_rx(&self) -> Option<mpsc::UnboundedReceiver<Vec<u8>>> {
        self.inner.video_rx.lock().unwrap().take()
    }

    pub fn take_audio_rx(&self) -> Option<mpsc::UnboundedReceiver<Vec<u8>>> {
        self.inner.audio_rx.lock().unwrap().take()
    }

    pub fn take_file_rx(&self) -> Option<mpsc::UnboundedReceiver<FileChunk>> {
        self.inner.file_rx.lock().unwrap().take()
    }

    // ---------- 发送 ----------

    /// 发送视频帧：开一条单向流，写 §4 帧头 + Annex-B NAL
    pub async fn send_video_frame(
        &self,
        annexb: &[u8],
        seq: u32,
        pts_us: u64,
        keyframe: bool,
        w: u16,
        h: u16,
    ) -> Result<()> {
        let header = VideoHeader {
            keyframe,
            codec: uu_proto::frames::CODEC_H264_ANNEXB,
            seq,
            pts_us,
            w,
            h,
            len: annexb.len() as u32,
        };
        let mut buf = Vec::with_capacity(VIDEO_HEADER_LEN + annexb.len());
        buf.extend_from_slice(&header.encode());
        buf.extend_from_slice(annexb);
        self.send_uni_frame(buf).await
    }

    /// 发送音频块（§5）
    pub async fn send_audio_frame(&self, opus: &[u8], seq: u32, pts_us: u64) -> Result<()> {
        let header = AudioHeader {
            seq,
            pts_us,
            codec: uu_proto::frames::CODEC_OPUS_48K2CH,
            len: opus.len() as u32,
        };
        let mut buf = Vec::with_capacity(AUDIO_HEADER_LEN + opus.len());
        buf.extend_from_slice(&header.encode());
        buf.extend_from_slice(opus);
        self.send_uni_frame(buf).await
    }

    /// 发送整帧字节（调用方已含帧头）——FFI video/audio 通道用
    pub async fn send_uni_frame(&self, frame: Vec<u8>) -> Result<()> {
        let mut stream = self.inner.quic.open_uni().await?;
        stream.write_all(&frame).await?;
        stream.finish()?;
        Ok(())
    }

    /// DATAGRAM（§2，ping/低时延输入）
    pub fn send_datagram(&self, data: Vec<u8>) -> Result<()> {
        self.inner.quic.send_datagram(bytes::Bytes::from(data))?;
        Ok(())
    }

    pub async fn recv_datagram(&self) -> Result<Vec<u8>> {
        Ok(self.inner.quic.read_datagram().await?.to_vec())
    }

    /// 打开一条文件双向流（§7）
    pub async fn open_file_sender(&self) -> Result<FileSender> {
        let (send, _recv) = self.inner.quic.open_bi().await?;
        Ok(FileSender { send })
    }

    pub fn close(&self, error_code: u32, reason: &str) {
        self.inner.quic.close(error_code.into(), reason.as_bytes());
    }

    pub async fn wait_closed(&self) {
        self.inner.quic.closed().await;
    }

    pub fn remote_address(&self) -> std::net::SocketAddr {
        self.inner.quic.remote_address()
    }
}

/// 文件流发送端：按 §7 写 chunk 头 + 数据
pub struct FileSender {
    send: quinn::SendStream,
}

impl FileSender {
    pub async fn send_chunk(&mut self, id: u32, index: u32, data: &[u8]) -> Result<()> {
        let header = FileHeader { id, chunk_index: index, chunk_len: data.len() as u32 };
        self.send.write_all(&header.encode()).await?;
        self.send.write_all(data).await?;
        Ok(())
    }

    pub async fn finish(self) -> Result<()> {
        let mut s = self.send;
        s.finish()?;
        Ok(())
    }
}

// ---------- 内部：通道与任务装配 ----------

pub(crate) struct ConnectionChannels {
    pub control_tx: mpsc::UnboundedSender<ControlMsg>,
    pub control_rx: mpsc::UnboundedReceiver<ControlMsg>,
    pub video_tx: mpsc::UnboundedSender<Vec<u8>>,
    pub video_rx: mpsc::UnboundedReceiver<Vec<u8>>,
    pub audio_tx: mpsc::UnboundedSender<Vec<u8>>,
    pub audio_rx: mpsc::UnboundedReceiver<Vec<u8>>,
    pub file_tx: mpsc::UnboundedSender<FileChunk>,
    pub file_rx: mpsc::UnboundedReceiver<FileChunk>,
}

fn new_channels() -> ConnectionChannels {
    let (control_tx, control_rx) = mpsc::unbounded_channel();
    let (video_tx, video_rx) = mpsc::unbounded_channel();
    let (audio_tx, audio_rx) = mpsc::unbounded_channel();
    let (file_tx, file_rx) = mpsc::unbounded_channel();
    ConnectionChannels {
        control_tx,
        control_rx,
        video_tx,
        video_rx,
        audio_tx,
        audio_rx,
        file_tx,
        file_rx,
    }
}

/// 在控制流上启动读/写任务，替换 ch 中的 control 通道端点
fn setup_control(ch: &mut ConnectionChannels, send: quinn::SendStream, recv: quinn::RecvStream) {
    let (msg_tx, msg_rx) = mpsc::unbounded_channel::<ControlMsg>();
    let (fwd_tx, fwd_rx) = mpsc::unbounded_channel::<ControlMsg>();
    ch.control_tx = msg_tx;
    ch.control_rx = fwd_rx;
    tokio::spawn(control_writer(send, msg_rx));
    tokio::spawn(control_reader(recv, fwd_tx));
}

/// 启动音视频/文件分派任务
fn spawn_media(
    conn: quinn::Connection,
    video_tx: mpsc::UnboundedSender<Vec<u8>>,
    audio_tx: mpsc::UnboundedSender<Vec<u8>>,
    file_tx: mpsc::UnboundedSender<FileChunk>,
) {
    tokio::spawn(async move {
        loop {
            tokio::select! {
                r = conn.accept_uni() => {
                    match r {
                        Ok(mut stream) => {
                            match stream.read_to_end(MAX_FRAME).await {
                                Ok(data) => dispatch_uni(data, &video_tx, &audio_tx),
                                Err(e) => tracing::debug!("uni read err: {e}"),
                            }
                        }
                        Err(e) => {
                            tracing::debug!("accept_uni end: {e}");
                            return;
                        }
                    }
                }
                r = conn.accept_bi() => {
                    match r {
                        Ok((_send, recv)) => {
                            let file_tx = file_tx.clone();
                            tokio::spawn(async move { read_file_stream(recv, file_tx).await });
                        }
                        Err(e) => {
                            tracing::debug!("accept_bi end: {e}");
                            return;
                        }
                    }
                }
            }
        }
    });
}

fn dispatch_uni(
    data: Vec<u8>,
    video_tx: &mpsc::UnboundedSender<Vec<u8>>,
    audio_tx: &mpsc::UnboundedSender<Vec<u8>>,
) {
    if data.len() < 2 {
        return;
    }
    let magic = u16::from_be_bytes([data[0], data[1]]);
    if magic == VIDEO_MAGIC {
        let _ = video_tx.send(data);
    } else if magic == AUDIO_MAGIC {
        let _ = audio_tx.send(data);
    }
}

async fn read_file_stream(mut recv: quinn::RecvStream, file_tx: mpsc::UnboundedSender<FileChunk>) {
    let mut header = [0u8; FILE_HEADER_LEN];
    loop {
        if recv.read_exact(&mut header).await.is_err() {
            return; // 流结束或出错
        }
        let h = match FileHeader::decode(&header) {
            Ok(h) => h,
            Err(_) => return,
        };
        let n = h.chunk_len as usize;
        if n > MAX_CHUNK {
            return;
        }
        let mut data = vec![0u8; n];
        if recv.read_exact(&mut data).await.is_err() {
            return;
        }
        if file_tx.send(FileChunk { id: h.id, index: h.chunk_index, data }).is_err() {
            return;
        }
    }
}

async fn control_writer(mut send: quinn::SendStream, mut rx: mpsc::UnboundedReceiver<ControlMsg>) {
    while let Some(m) = rx.recv().await {
        let bytes = match encode_msg(&m) {
            Ok(b) => b,
            Err(_) => continue,
        };
        if send.write_all(&bytes).await.is_err() {
            return;
        }
    }
}

async fn control_reader(mut recv: quinn::RecvStream, tx: mpsc::UnboundedSender<ControlMsg>) {
    let mut len_buf = [0u8; 4];
    loop {
        if recv.read_exact(&mut len_buf).await.is_err() {
            return;
        }
        let n = match decode_len(len_buf) {
            Ok(n) => n as usize,
            Err(_) => return,
        };
        let mut buf = vec![0u8; n];
        if recv.read_exact(&mut buf).await.is_err() {
            return;
        }
        match decode_msg(&buf) {
            Ok(m) => {
                if tx.send(m).is_err() {
                    return;
                }
            }
            Err(e) => tracing::debug!("control decode err: {e}"),
        }
    }
}

// ---------- 构造 ----------

/// 客户端侧：打开第一条双向流作为控制流（§2）
pub(crate) async fn new_client_connection(
    quic: quinn::Connection,
    endpoint: quinn::Endpoint,
    peer_pin: Option<String>,
) -> Result<Connection> {
    let mut ch = new_channels();
    let (send, recv) = quic.open_bi().await?;
    setup_control(&mut ch, send, recv);
    spawn_media(quic.clone(), ch.video_tx.clone(), ch.audio_tx.clone(), ch.file_tx.clone());
    let id = NEXT_CONN_ID.fetch_add(1, Ordering::Relaxed);
    Ok(build_conn(quic, Some(endpoint), ch, id, peer_pin))
}

/// 服务端侧：接受第一条双向流作为控制流
pub(crate) async fn new_server_connection(
    quic: quinn::Connection,
    peer_pin: Option<String>,
) -> Result<Connection> {
    let mut ch = new_channels();
    let (send, recv) = quic.accept_bi().await?;
    setup_control(&mut ch, send, recv);
    spawn_media(quic.clone(), ch.video_tx.clone(), ch.audio_tx.clone(), ch.file_tx.clone());
    let id = NEXT_CONN_ID.fetch_add(1, Ordering::Relaxed);
    Ok(build_conn(quic, None, ch, id, peer_pin))
}

fn build_conn(
    quic: quinn::Connection,
    endpoint: Option<quinn::Endpoint>,
    ch: ConnectionChannels,
    id: ConnId,
    peer_pin: Option<String>,
) -> Connection {
    Connection {
        inner: Arc::new(Inner {
            quic,
            _endpoint: endpoint,
            control_tx: ControlSender { tx: ch.control_tx },
            control_rx: Mutex::new(Some(ch.control_rx)),
            video_rx: Mutex::new(Some(ch.video_rx)),
            audio_rx: Mutex::new(Some(ch.audio_rx)),
            file_rx: Mutex::new(Some(ch.file_rx)),
        }),
        id,
        peer_pin,
    }
}
