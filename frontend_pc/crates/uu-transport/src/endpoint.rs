//! QUIC Endpoint 装配：服务端监听与客户端连接（§1/§2）。

use std::any::Any;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use rustls::pki_types::CertificateDer;

use crate::connection::{new_client_connection, new_server_connection, Connection};
use crate::crypto::{client_config, server_config, PinPolicy};
use crate::error::{Result, TransportError};
use crate::identity::{pin_of_cert, Identity};

/// 中继服务器 QUIC 端口（§8）
pub const RELAY_PORT: u16 = 8443;

pub fn transport_config() -> Arc<quinn::TransportConfig> {
    let mut tc = quinn::TransportConfig::default();
    tc.datagram_receive_buffer_size(Some(65536));
    tc.max_concurrent_uni_streams(quinn::VarInt::from_u32(128));
    tc.max_concurrent_bidi_streams(quinn::VarInt::from_u32(32));
    tc.keep_alive_interval(Some(Duration::from_secs(10)));
    Arc::new(tc)
}

/// 从连接的 peer_identity 提取对端证书并算 pin
fn peer_pin(conn: &quinn::Connection) -> Option<String> {
    let identity: Box<dyn Any> = conn.peer_identity()?;
    let chain = identity.downcast_ref::<Vec<CertificateDer<'static>>>()?;
    let leaf = chain.first()?;
    pin_of_cert(leaf.as_ref()).ok()
}

/// QUIC 服务端
pub struct Server {
    endpoint: quinn::Endpoint,
    #[allow(dead_code)]
    identity: Arc<Identity>,
}

impl Server {
    /// 监听 addr；policy 控制是否仅接受已配对 pin
    pub fn bind(identity: Arc<Identity>, addr: SocketAddr, policy: PinPolicy) -> Result<Server> {
        let rustls_cfg = server_config(&identity, policy)?;
        let crypto = Arc::new(quinn::crypto::rustls::QuicServerConfig::try_from(rustls_cfg)?);
        let mut sc = quinn::ServerConfig::with_crypto(crypto);
        sc.transport_config(transport_config());
        let endpoint = quinn::Endpoint::server(sc, addr)?;
        Ok(Self { endpoint, identity })
    }

    pub fn local_addr(&self) -> Result<SocketAddr> {
        Ok(self.endpoint.local_addr()?)
    }

    pub fn endpoint(&self) -> &quinn::Endpoint {
        &self.endpoint
    }

    /// 接受一条新连接并完成控制流装配；失败返回 None（已记录）
    pub async fn accept(&mut self) -> Option<Connection> {
        let incoming = self.endpoint.accept().await?;
        let quic = match incoming.accept() {
            Ok(connecting) => connecting.await.ok()?,
            Err(_) => return None,
        };
        let pin = peer_pin(&quic);
        match new_server_connection(quic, pin).await {
            Ok(c) => Some(c),
            Err(e) => {
                tracing::warn!("server control stream setup failed: {e}");
                None
            }
        }
    }

    /// 主动关闭监听
    pub fn close(&self) {
        self.endpoint
            .close(quinn::VarInt::from_u32(0), b"shutdown");
    }
}

/// 客户端连接。`policy` 为 Pinned(pin) 时做 TLS 层 SPKI 校验。
pub async fn connect_with_policy(
    identity: Arc<Identity>,
    addr: SocketAddr,
    policy: PinPolicy,
) -> Result<Connection> {
    let rustls_cfg = client_config(&identity, policy)?;
    let crypto = Arc::new(quinn::crypto::rustls::QuicClientConfig::try_from(rustls_cfg)?);
    let mut cc = quinn::ClientConfig::new(crypto);
    cc.transport_config(transport_config());
    let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse().unwrap())?;
    endpoint.set_default_client_config(cc);
    let connecting = endpoint.connect(addr, "uudesk.local")?;
    let quic = connecting.await?;
    let pin = peer_pin(&quic);
    new_client_connection(quic, endpoint, pin).await
}

/// 以已配对 pin 连接（常规模式）
pub async fn connect(identity: Arc<Identity>, addr: SocketAddr, peer_pin_b32: &str) -> Result<Connection> {
    let mut set = std::collections::HashSet::new();
    set.insert(peer_pin_b32.to_string());
    connect_with_policy(identity, addr, PinPolicy::Pinned(set)).await
}

/// 配对模式连接（接受任意证书，仅用于首次交换 pin）
pub async fn connect_pairing(identity: Arc<Identity>, addr: SocketAddr) -> Result<Connection> {
    connect_with_policy(identity, addr, PinPolicy::AllowAny).await
}

/// NAT 打洞：向目标地址主动发一个 UDP 包（§8 candidates 后双方互打）
pub async fn punch(addr: SocketAddr) -> Result<()> {
    let sock = tokio::net::UdpSocket::bind("0.0.0.0:0").await?;
    // 发一个非法 QUIC long-header 包，仅用于打洞；对端 quinn 会忽略
    let _ = sock.send_to(b"uu-holepunch", addr).await;
    Ok(())
}

/// 中继连接句柄：持有 Endpoint 保活 + 已发送 relay_hello 的双向流
pub struct RelayConnection {
    pub endpoint: quinn::Endpoint,
    pub send: quinn::SendStream,
    pub recv: quinn::RecvStream,
}

/// 中继连接：连服务器 QUIC 端口（默认 8443，ALPN uudesk/1），
/// 打开双向流并发送 relay_hello（§8），之后原始字节双向转发。
pub async fn relay_connect(
    identity: Arc<Identity>,
    server_addr: SocketAddr,
    peer_device_id: &str,
) -> Result<RelayConnection> {
    let rustls_cfg = client_config(&identity, PinPolicy::AllowAny)?;
    let crypto = Arc::new(quinn::crypto::rustls::QuicClientConfig::try_from(rustls_cfg)?);
    let mut cc = quinn::ClientConfig::new(crypto);
    cc.transport_config(transport_config());
    let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse().unwrap())?;
    endpoint.set_default_client_config(cc);
    let connecting = endpoint.connect(server_addr, "uudesk.local")?;
    let quic = connecting.await?;
    let (mut send, recv) = quic.open_bi().await?;
    let hello = serde_json::json!({
        "t": "relay_hello",
        "peer": peer_device_id,
        "device_id": identity.device_id,
    });
    let json = serde_json::to_vec(&hello)
        .map_err(|e| TransportError::Other(format!("relay_hello json: {e}")))?;
    send.write_all(&(json.len() as u32).to_be_bytes()).await?;
    send.write_all(&json).await?;
    Ok(RelayConnection { endpoint, send, recv })
}
