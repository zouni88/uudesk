# UUDesk 协议规范 v1

远程控制软件三端（PC/Rust、手机/Flutter、服务器/Go）共同遵循的唯一协议契约。
任何一端修改协议必须先更新本文件并提升版本号。

## 0. 总览

- 传输层：QUIC (RFC 9000)，TLS 1.3，自签名证书，证书 SPKI SHA-256 = 设备指纹。
- 信令/中继服务器：Go 实现，HTTPS + WebSocket（wss）做信令；QUIC 做可选的中继转发。
- 局域网发现：UDP 组播 239.255.77.233:37723（发现通告，JSON，见 §6）。
- 角色：`pc` | `phone` | `server`。会话中区分 `controller`（控制端）与 `controlled`（被控端），
  同一连接双向可用：controller 发输入事件，controlled 发音视频。

## 1. QUIC 连接与证书

- 每设备持有一对 Ed25519 密钥；用密钥签名生成自签名 X.509 证书（CN=device_id）。
- `device_id` = base32(SHA256(SPKI DER)) 前 16 字符。
- 验证方式：SPKI pinning。配对时双方交换 device_id，之后连接只接受 pin 匹配的证书。
- ALPN: `uudesk/1`。

## 2. 流布局

| 流 | 类型 | 方向 | 内容 |
|----|------|------|------|
| 双向流 #0（由发起连接方打开） | 控制流 | 双向 | 长度前缀 JSON 消息（§3），u32 大端长度 + UTF-8 JSON |
| 每视频帧一条单向流 | 视频 | controlled→controller | 帧头 + Annex-B H.264（§4） |
| 每音频块一条单向流 | 音频 | controlled→controller | 帧头 + Opus（§5） |
| 双向流 | 文件 | 任意 | 每文件一条流（§7） |
| 单向数据报 (DATAGRAM) | 探测/低时延输入 | 双向 | ping、可选输入事件 |

视频帧用「每帧一条单向流」避免队头阻塞；解码端按 `seq` 检测丢帧，丢关键帧则请求 IDR。

## 3. 控制流消息（JSON）

通用信封：`{"t":"<type>","id":<u32 可选请求号>,"...":"..."}`。响应携带相同 `id`。
所有坐标一律归一化 0.0–1.0（相对被控画面）。

### 3.1 会话/握手
- `hello`：`{t,role,device_id,name,proto:1}` 连接后控制流第一条消息。
- `hello_ack`：`{t,device_id,name}`。
- `session_open`：`{t,mode:"view_pc"|"control_phone", caps:[...]}` 声明本次会话用途。
- `session_close`、`error`：`{t,code,msg}`。
- `ping`/`pong`：`{t,ts}`（也走 DATAGRAM）。

### 3.2 输入控制（controller→controlled）
- `input`：`{t,k, ...}`，k 取值：
  - `move` `{x,y}`；`down`/`up` `{x,y,btn:1|2|3}`；`scroll` `{x,y,dx,dy}`
  - `key` `{key_code, action:"down"|"up"|"press", mods}`（key_code 用 PC 虚拟键码表，见附录 A）
  - `touch` `{id,x,y,action:"down"|"up"|"move"}`（手机被控时）
  - `text` `{s}`（输入法整串提交）
- `keyframe_req`：`{t}` 请求 IDR。
- `screen_cfg`：`{t,fps,w,h,bitrate_kbps,preset}` controlled 应用后回 `screen_cfg_ack`。

### 3.3 画面元数据（controlled→controller，视频流前的控制流消息）
- `screen_meta`：`{t,w,h,scale,rotation,codec:"h264"}`。分辨率变化时重发。

### 3.4 剪贴板同步
- `clip_set`：`{t,text,ts}`；收到后写入本地剪贴板并回 `clip_ack{id}`。
- 双向都发；以较大 `ts` 为准。

### 3.5 手机被控（PC→phone 指令）
- `cap_start`：`{t}` phone 启动 MediaProjection（首次需用户授权）开始向 PC 推视频。
- `cap_stop`：`{t}`。
- `inject_enable` / `inject_disable`：无障碍事件注入开关。

### 3.6 文件传输
- `file_offer`：`{t,id,name,size,path_hint}`（可双向）。
- `file_accept` / `file_reject`：`{t,id}`。
- 接受后在文件流上发送二进制（§7）。
- `file_done`：`{t,id,sha256}`。

## 4. 视频帧格式（每帧一条单向流）

```
magic:  u16 = 0x5556 ("UV")
flags:  u8  bit0=keyframe
codec:  u8  0=H264 AnnexB
seq:    u32 大端，从 0 递增，环绕
pts_us: u64 大端
w,h:    u16 大端
len:    u32 大端（随后 NAL 数据长度）
payload: NAL...
```
- 编码：H.264，Baseline/Main，PC 端 openh264 软编（默认 30fps/4Mbps），
  Android MediaCodec 硬编输出 Annex-B（SPS/PPS 随关键帧）。
- 解码：PC 端用 openh264 软解；手机端 Android MediaCodec / iOS VideoToolbox。

## 5. 音频帧格式（单向流）

```
magic: u16 = 0x5541 ("UA")
seq: u32  pts_us: u64  codec: u8(0=opus 48k/2ch)  len: u32  payload
```
- 采集：PC cpal → opus 编码（64kbps，10ms 帧）；播放同理。手机端 v1 可先占位。

## 6. 局域网发现（UDP 组播）

通告 JSON：`{"svc":"uudesk","v":1,"device_id","role","name","quic_port","ts"}`，
每 3 秒发送；监听者缓存 10 秒超时。收到后可直接向 `quic_port` 发起 QUIC 连接。

## 7. 文件流格式

控制流 `file_offer/file_accept` 之后，发送方打开一条双向流：
```
header: magic u16=0x5546("UF"), id u32, chunk_index u32, chunk_len u32, 随后原始字节
```
- chunk 大小 256KB；最后 chunk_len 可小于 256KB，发送方 finish 流。
- 接收方按 `file_offer.size` 判定完成，校验 sha256。

## 8. 信令与配对（服务器 API，WebSocket JSON）

连接：`GET /ws?token=<设备令牌>`（注册后长期有效）。
设备注册（HTTP）：`POST /api/register {name, role, device_id, spki_pin}` → `{token, device_id}`。

消息（服务端→设备 / 设备→服务端）：
- `invite`：`{t:"invite",from,code,device_id}` 服务端根据配对码向目标设备推送。
  语义：`from`=发起方（控制端）设备名，`device_id`=发起方 device_id（供被控端展示与 SPKI pin 校验）。
- `invite_result`：`{t:"invite_result",to,accept:bool}`。
- `candidates`：`{t:"candidates",peer,addrs:[...]}` 设备先经 `GET /api/reflect` 或 WS 消息
  `reflect` 取得自身公网地址，再上报 `candidates`；服务端把 `peer` 字段改写为发送方后转发给对端，
  并把已知的对端地址回填给发送方（一次上报即完成交换）。双方同时向对方地址打 UDP 包发起
  QUIC 直连（NAT 打洞）。
- `relay_open`：`{t:"relay_open",peer}` 打洞失败后，双方各自连服务器 QUIC 端口（8443，ALPN
  `uudesk/1`），打开一条双向流，首条消息为 `{"t":"relay_hello","peer":"<对端 device_id>",
  "device_id":"<本机 device_id>"}`（按 §2 加 u32 大端长度前缀）；服务器按双方 self/peer 互指
  完成配对后，其后字节原样双向转发（应用层中继）。
- `gen_code` / `revoke_code`：被控端生成/撤销 6 位配对码（服务端消息 `code` 返回）。
- `presence`：在线状态。

配对码：被控端生成 6 位数字码（10 分钟有效），控制端在服务器 `POST /api/pair {code, device_id}` 发起。

## 9. 错误码

| code | 含义 |
|------|------|
| 1001 | 协议版本不支持 |
| 1002 | SPKI pin 不匹配 |
| 2001 | 配对码无效/过期 |
| 2002 | 用户拒绝连接 |
| 3001 | 屏幕采集未授权 |
| 3002 | 无障碍服务未开启 |
| 4001 | 文件传输中断 |
| 4004 | 目标设备离线（服务器扩展） |
| 4005 | 信令消息非法（服务器扩展） |

## 附录 A：key_code

采用 Windows 虚拟键码（VK_*）。手机端物理键盘/软键盘事件映射到 VK 码后发送；
PC 端用 enigo `Key::Other(code)` 或查表转换为按键。

## 附录 B：FFI 契约（uu-ffi crate，C ABI）

手机端不重复实现 QUIC：Rust 工作区中的 `uu-ffi` crate 以 cdylib/staticlib 暴露 C ABI，
Flutter 通过 `dart:ffi` 绑定（Android 用 cargo-ndk 编译，iOS 用 xcframework）。
PC 端 Rust 直接依赖 `uu-transport`，不经过 FFI。

```c
// 通道编号
#define UU_CH_CONTROL 0
#define UU_CH_VIDEO   1
#define UU_CH_AUDIO   2
#define UU_CH_FILE    3

// 数据回调：在 Rust 线程触发，data 仅回调期间有效，绑定层需立即拷贝
typedef void (*uu_data_cb)(void* ctx, uint8_t channel, uint64_t conn_id,
                           const uint8_t* data, uint32_t len);
// 事件回调：event_json = {"t":"connected"|"disconnected"|"error",...}
typedef void (*uu_event_cb)(void* ctx, const char* event_json);

void*      uu_ffi_new(const char* config_json);   // {device_id,cert_dir,listen_port|null}
int32_t    uu_ffi_start(void* h);                 // 0=成功
uint64_t   uu_ffi_connect(void* h, const char* addr, const char* peer_pin_b32); // 返回 conn_id
int32_t    uu_ffi_send(void* h, uint64_t conn_id, uint8_t channel,
                       const uint8_t* data, uint32_t len); // control=JSON, video/audio/file=帧字节
void       uu_ffi_set_callbacks(void* h, uu_data_cb on_data, uu_event_cb on_event, void* ctx);
void       uu_ffi_close(void* h, uint64_t conn_id);
void       uu_ffi_free(void* h);
const char* uu_ffi_last_error(void* h);           // UTF-8，线程局部
```

- `uu_ffi_send` 的 video 通道：内部按 §4 打开一条单向流发送整帧（含帧头）。
- control 通道消息即 §3 JSON，长度前缀由 Rust 侧处理，绑定层只收发裸 JSON。
- 所有函数不得抛异常；失败返回负值并用 `uu_ffi_last_error` 取原因。

## 10. 多人会议（自托管 LiveKit）

会议与远程控制是两条独立通道，共用同一设备体系与信令服务器：

- 媒体面：自托管 LiveKit server（WebRTC），提供回音消除、带宽自适应、simulcast、
  屏幕共享、录制等能力；**会议无时长限制**。
- 控制面：远程控制仍走 §1–§8 的 QUIC 点对点/中继，不受会议影响。

### 10.1 身份与令牌
- LiveKit participant identity = `device_id`（§1），显示名 = 设备名。
- 令牌由 Go 信令服务器签发：`POST /api/meeting/token`
  `{room, identity, can_publish?:bool}` → `{token, server_url}`。
  token 为 HS256 JWT：`iss=LIVEKIT_API_KEY`、`sub=identity`、`video` grant
  （room、roomAdmin、canPublish、canSubscribe）。API key/secret 由服务器环境变量配置。
- 客户端不持有 API secret，只从信令服务器取 token。

### 10.2 房间与功能映射
- 房间创建/加入/退出全部由 LiveKit 管理，Go 服务器不存房间状态（持久房间，无时限）。
- 屏幕共享：LiveKit 标准 screen share track（`setScreenShareEnabled`），
  PC 端共享整屏/窗口，Android 端共享 MediaProjection。
- 会中文字聊天：LiveKit data channel，topic `lk.chat`。
- 举手：自定义 data topic `uudesk/raise-hand`，payload `{"raised":bool}`。
- 表情反应：自定义 data topic `uudesk/reaction`，payload `{"emoji":"👍"}`。
- 录制：LiveKit Egress 服务录制房间为 MP4（RoomComposite），产物存服务器磁盘；
  Go 服务器接收 Egress webhook 记录录制列表，提供 `GET /api/meeting/recordings?room=`。

### 10.3 部署
- `backend_go/deploy/docker-compose.yml`：livekit-server + redis + turn + egress。
- livekit 配置 `config.yaml`：`keys` 配置 API key/secret；WebSocket/HTTP API 端口 7881；
  UDP 媒体端口用官方字段 `rtc.port_range_start/port_range_end`（如 50000-50010），
  `use_external_ip`（公网 IP 经环境变量注入）；turn `3478/5349`。
- 客户端连接地址：`wss://<server-host>:7881`（或反代后的 443 路径）。
- 录制启动：`POST /api/meeting/egress/start {room}` → 优先经 SDK 直连 LiveKit 启动
  RoomComposite MP4 录制，成功返回 `{ok,room,egress_id}`；LiveKit 不可达时回退返回
  `{ok,room,command,note}`（livekit-cli 命令交运维执行）。
  停止：`POST /api/meeting/egress/stop {room}` → `{ok,room,egress_id}`；
  无进行中录制返回 code 5003，停止失败返回 5004。
  结束经 webhook 回传并记入 `GET /api/meeting/recordings?room=`。
- 令牌 video grant 含 `canUpdateOwnMetadata:true`（允许入会后 setName 改显示名）。
