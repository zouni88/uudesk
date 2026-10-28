//! 信令与配对（§8，按 2026-10 更新版规范）：
//! - WS `GET /ws?token=<设备令牌>`
//! - HTTP `POST /api/register`、`POST /api/pair`、`GET /api/reflect`
//! - WS 消息 invite/invite_result/candidates/relay_open/gen_code/revoke_code/code/presence
//! - candidates 前先取自身公网地址（/api/reflect 或 WS `reflect`）

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use url::Url;

use crate::error::{Result, TransportError};

/// 信令消息（信封 {"t":...}）
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum SignalMsg {
    /// 服务端按配对码推给被控端；from=发起方设备名，device_id=发起方 id
    Invite { from: String, code: String, device_id: String },
    /// 被控端应答后服务端转发给控制端
    InviteResult { to: String, accept: bool },
    /// 上报/接收候选公网地址（服务端把 peer 改写为发送方并回填对端地址）
    Candidates { peer: String, addrs: Vec<String> },
    /// 打洞失败后指示双方连服务器 QUIC 端口中继
    RelayOpen { peer: String },
    /// 请求自身公网地址（回复格式见 reflect_result / Unknown 透传）
    Reflect,
    /// 被控端生成 6 位配对码
    GenCode,
    /// 撤销配对码
    RevokeCode { code: String },
    /// 服务端返回配对码
    Code { code: String },
    Presence { device_id: String, online: bool },
    /// 未知类型透传（含 reflect 回复等服务器扩展）
    #[serde(other)]
    Unknown,
}

/// 带原始字段的解析结果（Unknown 也能拿到完整 JSON）
#[derive(Clone, Debug)]
pub struct RawSignal {
    pub kind: String,
    pub fields: Map<String, Value>,
}

fn parse_signal(json: &str) -> (SignalMsg, RawSignal) {
    let v: Value = match serde_json::from_str(json) {
        Ok(v) => v,
        Err(_) => {
            return (SignalMsg::Unknown, RawSignal { kind: String::new(), fields: Map::new() });
        }
    };
    let kind = v.get("t").and_then(|x| x.as_str()).unwrap_or("").to_string();
    let fields = match v.as_object() {
        Some(m) => m.clone(),
        None => Map::new(),
    };
    let msg = serde_json::from_value::<SignalMsg>(v).unwrap_or(SignalMsg::Unknown);
    (msg, RawSignal { kind, fields })
}

/// WS 信令客户端：读写任务分离，消息经通道上抛
pub struct SignalingClient {
    tx: mpsc::UnboundedSender<String>,
    /// 解析后的信令消息
    pub rx: mpsc::UnboundedReceiver<(SignalMsg, RawSignal)>,
}

impl SignalingClient {
    /// 连接 `ws(s)://host/ws?token=...`（token 为空则不带）
    pub async fn connect(server: &str, token: Option<&str>) -> Result<Self> {
        let base = normalize_ws_url(server)?;
        let url = match token {
            Some(t) if !t.is_empty() => format!("{base}/ws?token={t}"),
            _ => format!("{base}/ws"),
        };
        let (ws, _resp) = tokio_tungstenite::connect_async(url.as_str())
            .await
            .map_err(|e| TransportError::Other(format!("ws connect: {e}")))?;
        let (mut write, mut read) = ws.split();
        let (tx, mut urx) = mpsc::unbounded_channel::<String>();
        let (out_tx, out_rx) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Some(j) = urx.recv().await {
                if write.send(Message::Text(j.into())).await.is_err() {
                    return;
                }
            }
        });
        tokio::spawn(async move {
            while let Some(Ok(msg)) = read.next().await {
                match msg {
                    Message::Text(t) => {
                        let (m, raw) = parse_signal(t.as_str());
                        if out_tx.send((m, raw)).is_err() {
                            return;
                        }
                    }
                    Message::Close(_) => return,
                    _ => {}
                }
            }
        });
        Ok(Self { tx, rx: out_rx })
    }

    pub fn send(&self, m: &SignalMsg) -> Result<()> {
        let json = serde_json::to_string(m)
            .map_err(|e| TransportError::Other(format!("signal serialize: {e}")))?;
        self.tx.send(json).map_err(|_| TransportError::Other("ws closed".into()))
    }

    /// 发送任意原始 JSON（服务器扩展消息用）
    pub fn send_raw(&self, v: &Value) -> Result<()> {
        self.tx.send(v.to_string()).map_err(|_| TransportError::Other("ws closed".into()))
    }
}

fn normalize_ws_url(server: &str) -> Result<String> {
    let mut s = server.trim_end_matches('/').to_string();
    if s.starts_with("http://") {
        s = s.replace("http://", "ws://");
    } else if s.starts_with("https://") {
        s = s.replace("https://", "wss://");
    } else if !s.starts_with("ws://") && !s.starts_with("wss://") {
        return Err(TransportError::Other(format!("bad server url: {server}")));
    }
    Ok(s)
}

// ---------------- HTTP API ----------------

/// 极简 HTTP/1.1 JSON 客户端（https 走 tokio-rustls + webpki-roots）
async fn http_json(method: &str, url: &str, body: Option<&Value>) -> Result<Value> {
    let u = Url::parse(url)
        .map_err(|e| TransportError::Other(format!("url parse: {e}")))?;
    let host = u
        .host_str()
        .ok_or_else(|| TransportError::Other("url without host".into()))?
        .to_string();
    let port = u.port_or_known_default().unwrap_or(443);
    let path = match u.query() {
        Some(q) => format!("{}?{}", u.path(), q),
        None => u.path().to_string(),
    };
    let body_str = body.map(|b| b.to_string()).unwrap_or_default();
    let req = format!(
        "{method} {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body_str}",
        body_str.len()
    );

    let tcp = TcpStream::connect((host.as_str(), port)).await?;
    let resp = if u.scheme() == "https" {
        let roots: rustls::RootCertStore =
            webpki_roots::TLS_SERVER_ROOTS.iter().cloned().collect();
        let cfg = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(TransportError::Rustls)?
        .with_root_certificates(roots)
        .with_no_client_auth();
        let name = rustls::pki_types::ServerName::try_from(host.clone())
            .map_err(|_| TransportError::Other(format!("bad server name: {host}")))?;
        let connector = tokio_rustls::TlsConnector::from(Arc::new(cfg));
        let tls = connector.connect(name, tcp).await?;
        exchange(tls, req).await?
    } else {
        exchange(tcp, req).await?
    };
    let text = String::from_utf8_lossy(&resp).to_string();
    let split = text
        .find("\r\n\r\n")
        .ok_or_else(|| TransportError::Other("http response too short".into()))?;
    let head = &text[..split];
    let status_ok = head
        .lines()
        .next()
        .map(|l| l.contains(" 200"))
        .unwrap_or(false);
    let body_json: Value = serde_json::from_str(text[split + 4..].trim())
        .unwrap_or(Value::Null);
    if !status_ok {
        let msg = body_json
            .get("msg")
            .and_then(|m| m.as_str())
            .unwrap_or("http error")
            .to_string();
        return Err(TransportError::Other(format!("http {method} {url}: {msg}")));
    }
    Ok(body_json)
}

/// 在任意 TCP/TLS 流上发送请求并读回全部响应
async fn exchange<S>(mut stream: S, req: String) -> Result<Vec<u8>>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    stream.write_all(req.as_bytes()).await?;
    let mut resp = Vec::new();
    stream.read_to_end(&mut resp).await?;
    Ok(resp)
}

/// `POST /api/register {name, role, device_id, spki_pin}` → `{token, device_id}`
pub async fn api_register(
    server: &str,
    name: &str,
    role: &str,
    device_id: &str,
    spki_pin: &str,
) -> Result<Value> {
    let body = serde_json::json!({
        "name": name, "role": role, "device_id": device_id, "spki_pin": spki_pin,
    });
    http_json("POST", &format!("{}/api/register", server.trim_end_matches('/')), Some(&body)).await
}

/// `POST /api/pair {code, device_id}`：控制端用配对码发起配对
pub async fn api_pair(server: &str, code: &str, device_id: &str) -> Result<Value> {
    let body = serde_json::json!({ "code": code, "device_id": device_id });
    http_json("POST", &format!("{}/api/pair", server.trim_end_matches('/')), Some(&body)).await
}

/// `GET /api/reflect`：取本机公网地址（candidates 上报前调用）
pub async fn api_reflect(server: &str) -> Result<Vec<String>> {
    let v = http_json("GET", &format!("{}/api/reflect", server.trim_end_matches('/')), None).await?;
    Ok(extract_addrs(&v))
}

fn extract_addrs(v: &Value) -> Vec<String> {
    if let Some(arr) = v.get("addrs").and_then(|a| a.as_array()) {
        return arr.iter().filter_map(|x| x.as_str().map(String::from)).collect();
    }
    if let Some(s) = v.as_str() {
        return vec![s.to_string()];
    }
    Vec::new()
}

/// 从 reflect 回复（RawSignal 的 Unknown 透传）中提取地址
pub fn addrs_from_raw(raw: &RawSignal) -> Vec<String> {
    raw.fields
        .get("addrs")
        .and_then(|a| a.as_array())
        .map(|arr| arr.iter().filter_map(|x| x.as_str().map(String::from)).collect())
        .unwrap_or_default()
}
