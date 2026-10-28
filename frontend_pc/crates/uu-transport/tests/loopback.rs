//! 同机回环集成测试：两个 Endpoint 互连，控制流 + 一帧视频往返。

use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;

use uu_proto::{VideoHeader, VIDEO_HEADER_LEN};
use uu_transport::{connect, ControlMsg, Identity, InputEvent, PinPolicy, Server};

fn tmp_identity(tag: &str) -> Arc<Identity> {
    let dir = std::env::temp_dir().join(format!("uu-loopback-{}", tag));
    let _ = std::fs::remove_dir_all(&dir);
    Arc::new(Identity::load_or_create(&dir).unwrap())
}

#[tokio::test]
async fn loopback_control_and_video() {
    let server_id = tmp_identity("server");
    let client_id = tmp_identity("client");
    let client_pin = client_id.device_id.clone();

    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, 0));
    let mut server = Server::bind(server_id.clone(), addr, PinPolicy::AllowAny).unwrap();
    let listen = server.local_addr().unwrap();

    let accept = tokio::spawn(async move {
        let conn = server.accept().await.expect("server accept");
        // TLS 层 SPKI pin 已校验；peer_pin 即客户端 device_id
        assert_eq!(conn.peer_pin(), Some(client_pin.as_str()));

        let mut rx = conn.take_control_rx().unwrap();
        let first = rx.recv().await.expect("hello");
        match &first {
            ControlMsg::Hello { device_id, .. } => assert_eq!(device_id, &client_pin),
            m => panic!("expected hello, got {m:?}"),
        }
        conn.control()
            .send(ControlMsg::HelloAck {
                device_id: "srv-device".into(),
                name: "srv".into(),
            })
            .unwrap();

        // 收到一条 input 后回一条 screen_meta
        while let Some(m) = rx.recv().await {
            if let ControlMsg::Input { .. } = m {
                conn.control()
                    .send(ControlMsg::ScreenMeta {
                        w: 1920,
                        h: 1080,
                        scale: 1.0,
                        rotation: 0,
                        codec: "h264".into(),
                    })
                    .unwrap();
                break;
            }
        }

        // 发送一帧视频（假 NAL）+ DATAGRAM ping
        let fake_nal: Vec<u8> = vec![0, 0, 0, 1, 0x65, 1, 2, 3, 4, 5];
        conn.send_video_frame(&fake_nal, 7, 12345, true, 1920, 1080)
            .await
            .expect("send video");
        conn.send_datagram(b"ping".to_vec()).expect("datagram");
        // 保活：阻塞直到测试结束（rx 持有连接状态）
        tokio::time::sleep(std::time::Duration::from_secs(30)).await;
    });

    let client = connect(client_id.clone(), listen, &server_id.device_id)
        .await
        .expect("connect");

    let mut rx = client.take_control_rx().unwrap();
    client
        .control()
        .send(ControlMsg::Hello {
            role: "pc".into(),
            device_id: client_id.device_id.clone(),
            name: "cli".into(),
            proto: 1,
        })
        .unwrap();
    let ack = rx.recv().await.expect("hello_ack");
    assert!(matches!(ack, ControlMsg::HelloAck { .. }));

    client
        .control()
        .send(ControlMsg::Input { ev: InputEvent::Move { x: 0.1, y: 0.2 } })
        .unwrap();

    let meta = tokio::time::timeout(std::time::Duration::from_secs(5), rx.recv())
        .await
        .expect("timeout meta")
        .expect("meta msg");
    assert!(matches!(meta, ControlMsg::ScreenMeta { .. }));

    let mut vrx = client.take_video_rx().unwrap();
    let frame = tokio::time::timeout(std::time::Duration::from_secs(5), vrx.recv())
        .await
        .expect("timeout video")
        .expect("video frame");
    let h = VideoHeader::decode(&frame).expect("video header");
    assert_eq!(h.seq, 7);
    assert!(h.keyframe);
    assert_eq!(h.len as usize, frame.len() - VIDEO_HEADER_LEN);
    assert_eq!(&frame[VIDEO_HEADER_LEN..], &[0, 0, 0, 1, 0x65, 1, 2, 3, 4, 5]);

    let dg = tokio::time::timeout(std::time::Duration::from_secs(5), client.recv_datagram())
        .await
        .expect("timeout dgram")
        .expect("dgram");
    assert_eq!(dg, b"ping");

    accept.abort();
}

#[tokio::test]
async fn pin_mismatch_rejected() {
    let server_id = tmp_identity("srv2");
    let client_id = tmp_identity("cli2");
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, 0));
    let mut server = Server::bind(server_id.clone(), addr, PinPolicy::AllowAny).unwrap();
    let listen = server.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = server.accept().await;
    });
    // 用错误的 pin 连接，应在 TLS 层被拒（§9 错误码 1002 语义）
    let r = connect(client_id, listen, "AAAAAAAAAAAAAAAA").await;
    assert!(r.is_err(), "wrong pin must fail");
}

#[tokio::test]
async fn file_stream_roundtrip() {
    let server_id = tmp_identity("srv3");
    let client_id = tmp_identity("cli3");
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, 0));
    let mut server = Server::bind(server_id.clone(), addr, PinPolicy::AllowAny).unwrap();
    let listen = server.local_addr().unwrap();

    let accept = tokio::spawn(async move {
        let conn = server.accept().await.expect("accept");
        let mut frx = conn.take_file_rx().unwrap();
        let mut got: Vec<(u32, Vec<u8>)> = Vec::new();
        for _ in 0..2 {
            let c = frx.recv().await.expect("chunk");
            got.push((c.index, c.data));
        }
        assert_eq!(got[0].1.len(), 1000);
        assert_eq!(got[1].1.len(), 400);
        got
    });

    let client = connect(client_id, listen, &server_id.device_id).await.unwrap();
    let mut sender = client.open_file_sender().await.unwrap();
    sender.send_chunk(42, 0, &vec![0xABu8; 1000]).await.unwrap();
    sender.send_chunk(42, 1, &vec![0xCDu8; 400]).await.unwrap();
    sender.finish().await.unwrap();

    let got = tokio::time::timeout(std::time::Duration::from_secs(5), accept)
        .await
        .expect("timeout")
        .expect("server task");
    assert_eq!(got.len(), 2);
}
