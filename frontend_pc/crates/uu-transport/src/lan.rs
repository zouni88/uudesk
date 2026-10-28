//! 局域网发现（§6）：UDP 组播 239.255.77.233:37723 通告/监听。

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tokio::net::UdpSocket;
use tokio::sync::mpsc;

use crate::error::{Result, TransportError};

pub const MULTICAST_GROUP: Ipv4Addr = Ipv4Addr::new(239, 255, 77, 233);
pub const MULTICAST_PORT: u16 = 37723;
/// 通告间隔（§6：每 3 秒）
pub const ANNOUNCE_INTERVAL: Duration = Duration::from_secs(3);
/// 缓存超时（§6：10 秒）
pub const CACHE_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct LanAnnounce {
    pub svc: String,
    pub v: u32,
    pub device_id: String,
    pub role: String,
    pub name: String,
    pub quic_port: u16,
    pub ts: u64,
}

#[derive(Clone, Debug)]
pub struct DiscoveredDevice {
    pub device_id: String,
    pub role: String,
    pub name: String,
    /// 通告来源地址（QUIC 直连目标）
    pub addr: SocketAddr,
    pub last_seen: Instant,
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

/// 启动通告任务：每 3s 向组播组发送本机信息。
/// 返回 JoinHandle，drop 不影响；abort 即停止。
pub fn spawn_announcer(
    device_id: String,
    role: String,
    name: String,
    quic_port: u16,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let sock = match UdpSocket::bind("0.0.0.0:0").await {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!("lan announcer bind failed: {e}");
                return;
            }
        };
        let dst = SocketAddr::new(IpAddr::V4(MULTICAST_GROUP), MULTICAST_PORT);
        loop {
            let a = LanAnnounce {
                svc: "uudesk".into(),
                v: 1,
                device_id: device_id.clone(),
                role: role.clone(),
                name: name.clone(),
                quic_port,
                ts: now_ms(),
            };
            if let Ok(json) = serde_json::to_vec(&a) {
                let _ = sock.send_to(&json, dst).await;
            }
            tokio::time::sleep(ANNOUNCE_INTERVAL).await;
        }
    })
}

/// 组播监听 socket：SO_REUSEADDR + join group，便于多进程/多网卡共存
async fn listener_socket() -> Result<UdpSocket> {
    let sock = socket2::Socket::new(
        socket2::Domain::IPV4,
        socket2::Type::DGRAM,
        Some(socket2::Protocol::UDP),
    )?;
    sock.set_reuse_address(true)?;
    sock.set_nonblocking(true)?;
    sock.bind(&SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), MULTICAST_PORT).into())?;
    sock.join_multicast_v4(&MULTICAST_GROUP, &Ipv4Addr::UNSPECIFIED)?;
    let std_sock: std::net::UdpSocket = sock.into();
    let tokio_sock = UdpSocket::from_std(std_sock)?;
    Ok(tokio_sock)
}

/// 启动监听任务：收到通告（含超时剔除）后上抛最新设备快照。
pub fn spawn_listener() -> (tokio::task::JoinHandle<()>, mpsc::UnboundedReceiver<Vec<DiscoveredDevice>>) {
    let (tx, rx) = mpsc::unbounded_channel();
    let handle = tokio::spawn(async move {
        let sock = match listener_socket().await {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!("lan listener failed: {e}");
                return;
            }
        };
        let mut cache: std::collections::HashMap<String, DiscoveredDevice> = Default::default();
        let mut buf = vec![0u8; 2048];
        let mut tick = tokio::time::interval(Duration::from_secs(2));
        loop {
            tokio::select! {
                r = sock.recv_from(&mut buf) => {
                    if let Ok((n, from)) = r {
                        if let Ok(a) = serde_json::from_slice::<LanAnnounce>(&buf[..n]) {
                            if a.svc == "uudesk" && a.v == 1 {
                                cache.insert(a.device_id.clone(), DiscoveredDevice {
                                    device_id: a.device_id,
                                    role: a.role,
                                    name: a.name,
                                    addr: from,
                                    last_seen: Instant::now(),
                                });
                                let _ = tx.send(cache.values().cloned().collect());
                            }
                        }
                    }
                }
                _ = tick.tick() => {
                    // 10 秒超时剔除
                    let before = cache.len();
                    cache.retain(|_, d| d.last_seen.elapsed() < CACHE_TIMEOUT);
                    if cache.len() != before {
                        let _ = tx.send(cache.values().cloned().collect());
                    }
                }
            }
        }
    });
    (handle, rx)
}

/// 供测试：直接发送一条通告到本地回环组播
pub async fn debug_announce(a: &LanAnnounce) -> Result<()> {
    let sock = UdpSocket::bind("0.0.0.0:0").await
        .map_err(|e| TransportError::Other(format!("announce sock: {e}")))?;
    sock.set_multicast_loop_v4(true)
        .map_err(|e| TransportError::Other(format!("mcast loop: {e}")))?;
    let json = serde_json::to_vec(a).map_err(|e| TransportError::Other(e.to_string()))?;
    let dst = SocketAddr::new(IpAddr::V4(MULTICAST_GROUP), MULTICAST_PORT);
    sock.send_to(&json, dst).await?;
    Ok(())
}
