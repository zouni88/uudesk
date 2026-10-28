# UUDesk

跨端远程控制与多人会议系统：用手机控制 PC 桌面，也能让 PC 反向查看/控制手机；内置基于自托管 LiveKit 的多人会议。

三端共用一套协议契约（[proto/uu-proto.md](proto/uu-proto.md)），任何一端改动协议必须先更新该文档。

## 特性

- **远程控制**：QUIC 点对点直连，NAT 打洞失败自动回落服务器中继
- **安全配对**：Ed25519 设备密钥 + 自签名证书，SPKI pinning 校验设备指纹；6 位配对码（10 分钟有效）
- **双向画面**：H.264 每帧一条单向流，避免队头阻塞；支持 IDR 重请求与码率/帧率动态调整
- **输入注入**：鼠标、键盘、触摸、文本、滚轮，坐标统一归一到 0.0–1.0
- **剪贴板同步**：双向按时间戳收敛
- **文件传输**：256KB 分块 + SHA-256 校验
- **多人会议**：自托管 LiveKit（WebRTC），屏幕共享、文字聊天、举手、表情、Egress 录制，房间无时长限制
- **局域网发现**：UDP 组播 239.255.77.233:37723

## 架构

| 模块 | 技术栈 | 说明 |
|------|--------|------|
| [backend_go](backend_go) | Go 1.26 | 信令（WS）、配对、NAT 打洞辅助、QUIC 应用层中继、LiveKit 令牌签发与录制管理 |
| [desktop](desktop) | Tauri 2 + React 19 + TS | PC 桌面端（Tauri 原生壳 + Web 前端） |
| [frontend_flutter](frontend_flutter) | Flutter / Dart | 手机端（Android/iOS），经 `dart:ffi` 调用 Rust 传输层 |
| [frontend_pc](frontend_pc) | Rust workspace | PC 原生能力：传输、屏幕采集/编解码、输入注入、剪贴板、音频、会议 |
| [proto](proto) | — | 唯一协议规范 v1 |

数据传输分两条独立通道：远程控制走 QUIC（§1–§8），会议媒体走 LiveKit WebRTC（§10），互不影响。

```
┌──────────┐   QUIC 控制流 / 视频 / 音频 / 文件   ┌──────────┐
│ 手机端    │◄──────────────────────────────────►│ PC 端     │
│ Flutter  │        P2P 直连 or 服务器中继        │ Rust/Tauri│
└────┬─────┘                                    └────┬─────┘
     │              WSS 信令 / HTTP API               │
     └───────────────────┬───────────────────────────┘
                ┌────────▼────────┐
                │ uudesk-server   │  Go
                │ /ws  /api/*     │
                └────────┬────────┘
                         │ 令牌 + webhook
                ┌────────▼────────┐
                │ LiveKit + Redis │  会议媒体面
                │ + TURN + Egress │
                └─────────────────┘
```

## 目录结构

```
uudesk/
├── backend_go/            # Go 信令/中继/会议 API 服务
│   ├── cmd/uudesk-server/ # 入口
│   ├── internal/          # api, pair, ws, relay, meeting, store
│   ├── data/              # 设备表与中继证书（运行期数据）
│   └── deploy/            # Dockerfile、docker-compose、LiveKit/TURN/Egress 配置
├── desktop/               # Tauri 2 + React + TypeScript 桌面端
│   ├── src/               # React 页面与组件（会议、远程、设备、设置）
│   └── src-tauri/         # Rust 原生壳
├── frontend_flutter/      # 手机端 Flutter 应用
│   ├── lib/core/          # 协议、信令、传输、会议封装
│   └── lib/features/      # 控制 PC / 被控 / 会议 / 配对 / 文件
├── frontend_pc/           # Rust 工作区（uu-proto / uu-transport / uu-screen / uu-input / uu-audio / uu-meeting / uu-ffi ...）
└── proto/uu-proto.md      # 协议规范 v1
```

## 快速开始

### 1. 后端（Go）

```bash
cd backend_go
go run ./cmd/uudesk-server -http :8080 -quic :8443 -data ./data
```

默认监听 `:8080`（HTTP/WS）与 `:8443/udp`（QUIC 中继）。主要接口：

- `POST /api/register` 设备注册，返回长期令牌
- `GET  /api/reflect` 获取自身公网地址（打洞用）
- `POST /api/pair` 配对码发起连接
- `GET  /api/health` 健康检查
- `GET  /ws?token=<设备令牌>` 信令 WebSocket
- `POST /api/meeting/token` 签发 LiveKit 令牌
- `POST /api/meeting/egress/start|stop`、`GET /api/meeting/recordings`、`POST /api/meeting/webhook` 录制管理

未配置 `LIVEKIT_API_KEY`/`LIVEKIT_API_SECRET` 时服务照常启动，仅会议接口返回 5001。

### 2. 桌面端（Tauri）

```bash
cd desktop
npm install
npm run tauri dev      # 开发
npm run tauri build    # 打包
```

### 3. 手机端（Flutter）

```bash
cd frontend_flutter
flutter pub get
flutter run
```

传输层不重复实现 QUIC：由 `frontend_pc/crates/uu-ffi` 输出 C ABI（Android 用 `cargo-ndk`，iOS 用 xcframework），Flutter 通过 `dart:ffi` 绑定。

### 4. PC Rust 工作区

```bash
cd frontend_pc
cargo test --workspace
cargo build -p uu-app
```

## 配置

后端会议相关环境变量（也可放在 `backend_go/deploy/.env`，参考 `.env.example`）：

| 变量 | 说明 |
|------|------|
| `LIVEKIT_API_KEY` | LiveKit API Key（同时作为 JWT `iss`） |
| `LIVEKIT_API_SECRET` | LiveKit API Secret，仅服务端持有 |
| `LIVEKIT_URL` | 客户端连接地址，如 `wss://host:7881` |
| `EXTERNAL_IP` | 对外公网 IP（TURN/媒体通告） |
| `REDIS_ADDR` | Redis 地址，默认 `redis:6379` |

## 部署

`backend_go/deploy` 提供整套会议栈编排（livekit-server + redis + turn + egress + uudesk-server）：

```bash
cd backend_go/deploy
cp .env.example .env      # 填写 key/secret/公网 IP
docker compose up -d
```

LiveKit 端口 7881（WS + RTC）、7882（WebRTC over TCP 回退）、50000-50010/udp（simulcast）；TURN 3478/5349；Go 服务 8080 与 8443/udp。

## 协议

完整规范见 [proto/uu-proto.md](proto/uu-proto.md)：QUIC 连接与证书、流布局、控制流 JSON 消息、视频/音频/文件帧格式、局域网发现、信令与配对、错误码、FFI 契约、会议（LiveKit）方案。

## 许可证

[Apache License 2.0](LICENSE)
