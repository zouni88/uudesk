import 'dart:async';
import 'dart:convert';
import 'dart:io';

// 排障日志直接打到控制台，统一用 print。
// ignore_for_file: avoid_print

import 'package:web_socket_channel/web_socket_channel.dart';

/// §8 信令与配对客户端。
///
/// - HTTP：`POST /api/register`、`POST /api/pair`、`GET /api/reflect`
/// - WS：`GET /ws?token=<设备令牌>`，收发 JSON 消息
///   （invite / invite_result / candidates / relay_open / presence /
///    gen_code / revoke_code / code / reflect）
///
/// 语义要点（§8 最新）：
/// - `invite` 的 `from`=发起方（控制端）设备名、`device_id`=发起方 device_id
///   （供被控端展示与 SPKI pin 校验）。
/// - 上报 `candidates` 前需先经 `GET /api/reflect` 或 WS `reflect` 取得
///   自身公网地址；服务端把 `peer` 改写为发送方后转发对端，并回填对端地址。
/// - `relay_open` 后双方连服务器 QUIC 端口（8443，ALPN `uudesk/1`），
///   双向流首条消息 [relayHelloMessage]（§2 u32 大端长度前缀由 uu-ffi 处理）。
class SignalingClient {
  /// 服务器中继 QUIC 端口（§8）。
  static const int relayQuicPort = 8443;
  static const String relayAlpn = 'uudesk/1';

  /// 服务器基址，如 `https://signal.example.com` 或 `http://host:port`。
  final String baseUrl;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _status = StreamController<String>.broadcast();
  bool _closed = false;

  SignalingClient(this.baseUrl);

  Uri get _httpUri => Uri.parse(baseUrl);
  Uri get _wsUri {
    final u = Uri.parse(baseUrl);
    final scheme = u.isScheme('https') ? 'wss' : 'ws';
    return u.replace(scheme: scheme);
  }

  /// 信令消息流（服务端→设备）。
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// 连接状态：`connected` / `disconnected` / `error:<msg>`
  Stream<String> get status => _status.stream;

  bool get isConnected => _channel != null;

  /// 设备注册（§8 HTTP）：返回 `{token, device_id}`。
  Future<Map<String, dynamic>> register({
    required String name,
    required String role,
    required String deviceId,
    required String spkiPin,
  }) async {
    final body = jsonEncode({
      'name': name, 'role': role, 'device_id': deviceId, 'spki_pin': spkiPin,
    });
    final resp = await _post('/api/register', body);
    return resp;
  }

  /// 控制端用 6 位配对码发起配对（§8 HTTP）：`POST /api/pair {code, device_id}`。
  Future<Map<String, dynamic>> pair(String code, String deviceId) =>
      _post('/api/pair', jsonEncode({'code': code, 'device_id': deviceId}));

  /// §10.1 会议令牌签发：`POST /api/meeting/token {room, identity, can_publish}`
  /// → `{token, server_url}`。
  Future<Map<String, dynamic>> meetingToken({
    required String room,
    required String identity,
    bool canPublish = true,
  }) =>
      _post('/api/meeting/token',
          jsonEncode({'room': room, 'identity': identity, 'can_publish': canPublish}));

  /// §10.2 开始录制（Egress RoomComposite）：`POST /api/meeting/egress/start {room}`。
  Future<Map<String, dynamic>> startMeetingEgress(String room) =>
      _post('/api/meeting/egress/start', jsonEncode({'room': room}));

  /// §10.2 停止录制（规范未定义 stop 端点，按对称路径假设）。
  Future<Map<String, dynamic>> stopMeetingEgress(String room) =>
      _post('/api/meeting/egress/stop', jsonEncode({'room': room}));

  /// 连接 WS 信令通道。
  Future<void> connectWs(String token) async {
    _channel?.sink.close();
    final uri = _wsUri.replace(path: '/ws', query: 'token=${Uri.encodeComponent(token)}');
    final ch = WebSocketChannel.connect(uri);
    _channel = ch;
    await ch.ready;
    _sub = ch.stream.listen(
      (raw) {
        try {
          _messages.add(jsonDecode(raw as String) as Map<String, dynamic>);
        } catch (_) {/* 忽略非 JSON 帧 */}
      },
      onDone: () => _status.add('disconnected'),
      onError: (e) => _status.add('error:$e'),
      cancelOnError: false,
    );
    _status.add('connected');
  }

  /// 被控端申请生成 6 位配对码（10 分钟有效），服务端以 `code` 消息返回。
  void requestGenCode() => send({'t': 'gen_code'});

  /// 被控端撤销当前配对码。
  void revokeCode() => send({'t': 'revoke_code'});

  /// 取得本机公网地址（HTTP `GET /api/reflect`）。
  Future<List<String>> reflect() async {
    final resp = await _get('/api/reflect');
    final addrs = (resp['addrs'] as List? ?? []).map((e) => e.toString()).toList();
    return addrs;
  }

  /// 取得本机公网地址（WS `reflect`）。应答按 `{t:"reflect", addrs:[...]}`
  /// 解析（规范未定死应答类型名，两者都兼容）。
  Future<List<String>> requestReflect() async {
    send({'t': 'reflect'});
    final completer = Completer<List<String>>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = messages.listen((m) {
      if (m['t'] == 'reflect' || m['t'] == 'reflect_result') {
        sub.cancel();
        completer.complete(
            (m['addrs'] as List? ?? []).map((e) => e.toString()).toList());
      }
    });
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        sub.cancel();
        return const [];
      },
    );
  }

  /// 上报本机候选地址（§8：服务端改写 `peer` 为发送方后转发对端并回填）。
  void reportCandidates(String peer, List<String> addrs) =>
      send({'t': 'candidates', 'peer': peer, 'addrs': addrs});

  /// 应答 invite：`{t:"invite_result", to, accept}`。
  void answerInvite(String to, bool accept) =>
      send({'t': 'invite_result', 'to': to, 'accept': accept});

  /// relay_open 后中继流首条消息（§8）。经 uu-ffi control 通道发送，
  /// u32 大端长度前缀由 Rust 侧处理（附录 B）。
  static Map<String, dynamic> relayHelloMessage(String peerDeviceId, String selfDeviceId) => {
        't': 'relay_hello', 'peer': peerDeviceId, 'device_id': selfDeviceId,
      };

  void send(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  Future<Map<String, dynamic>> _post(String path, String body) async {
    final client = HttpClient();
    print('[signaling] POST ${_httpUri.replace(path: path)} body=$body');
    try {
      final req = await client.postUrl(_httpUri.replace(path: path));
      req.headers.contentType = ContentType.json;
      req.write(body);
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      print('[signaling] POST $path <- ${resp.statusCode} $text');
      if (resp.statusCode ~/ 100 != 2) {
        throw SignalingException(resp.statusCode, text);
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final client = HttpClient();
    print('[signaling] GET ${_httpUri.replace(path: path)}');
    try {
      final req = await client.getUrl(_httpUri.replace(path: path));
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      print('[signaling] GET $path <- ${resp.statusCode} $text');
      if (resp.statusCode ~/ 100 != 2) {
        throw SignalingException(resp.statusCode, text);
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
    await _messages.close();
    await _status.close();
  }
}

class SignalingException implements Exception {
  final int statusCode;
  final String body;
  SignalingException(this.statusCode, this.body);
  @override
  String toString() => 'SignalingException($statusCode): $body';
}
