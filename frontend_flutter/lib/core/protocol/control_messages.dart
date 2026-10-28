/// §3 控制流消息构造器（JSON，坐标一律归一化 0.0–1.0）。
abstract final class UuMsg {
  // ===== 3.1 会话/握手 =====
  static Map<String, dynamic> hello(String role, String deviceId, String name) =>
      {'t': 'hello', 'role': role, 'device_id': deviceId, 'name': name, 'proto': 1};

  static Map<String, dynamic> helloAck(String deviceId, String name) =>
      {'t': 'hello_ack', 'device_id': deviceId, 'name': name};

  static Map<String, dynamic> sessionOpen(String mode, List<String> caps) =>
      {'t': 'session_open', 'mode': mode, 'caps': caps};

  static Map<String, dynamic> sessionClose() => {'t': 'session_close'};

  static Map<String, dynamic> error(int code, String msg) => {'t': 'error', 'code': code, 'msg': msg};

  static Map<String, dynamic> ping(int ts) => {'t': 'ping', 'ts': ts};

  static Map<String, dynamic> pong(int ts) => {'t': 'pong', 'ts': ts};

  // ===== 3.2 输入控制（controller→controlled）=====
  static Map<String, dynamic> inputMove(double x, double y) =>
      {'t': 'input', 'k': 'move', 'x': x, 'y': y};

  static Map<String, dynamic> inputDown(double x, double y, {int btn = 1}) =>
      {'t': 'input', 'k': 'down', 'x': x, 'y': y, 'btn': btn};

  static Map<String, dynamic> inputUp(double x, double y, {int btn = 1}) =>
      {'t': 'input', 'k': 'up', 'x': x, 'y': y, 'btn': btn};

  static Map<String, dynamic> inputScroll(double x, double y, double dx, double dy) =>
      {'t': 'input', 'k': 'scroll', 'x': x, 'y': y, 'dx': dx, 'dy': dy};

  static Map<String, dynamic> inputKey(int keyCode, String action, {int mods = 0}) =>
      {'t': 'input', 'k': 'key', 'key_code': keyCode, 'action': action, 'mods': mods};

  static Map<String, dynamic> inputTouch(int id, double x, double y, String action) =>
      {'t': 'input', 'k': 'touch', 'id': id, 'x': x, 'y': y, 'action': action};

  static Map<String, dynamic> inputText(String s) => {'t': 'input', 'k': 'text', 's': s};

  static Map<String, dynamic> keyframeReq() => {'t': 'keyframe_req'};

  static Map<String, dynamic> screenCfg(int fps, int w, int h, int bitrateKbps, String preset) => {
        't': 'screen_cfg', 'fps': fps, 'w': w, 'h': h,
        'bitrate_kbps': bitrateKbps, 'preset': preset,
      };

  // ===== 3.4 剪贴板 =====
  static Map<String, dynamic> clipSet(String text, int ts, {int? id}) =>
      {'t': 'clip_set', 'text': text, 'ts': ts, 'id': ?id};

  static Map<String, dynamic> clipAck(int id) => {'t': 'clip_ack', 'id': id};

  // ===== 3.5 手机被控指令 =====
  static Map<String, dynamic> capStart() => {'t': 'cap_start'};
  static Map<String, dynamic> capStop() => {'t': 'cap_stop'};
  static Map<String, dynamic> injectEnable() => {'t': 'inject_enable'};
  static Map<String, dynamic> injectDisable() => {'t': 'inject_disable'};

  // ===== 3.6 文件传输 =====
  static Map<String, dynamic> fileOffer(int id, String name, int size, {String? pathHint}) => {
        't': 'file_offer', 'id': id, 'name': name, 'size': size,
        'path_hint': ?pathHint,
      };

  static Map<String, dynamic> fileAccept(int id) => {'t': 'file_accept', 'id': id};
  static Map<String, dynamic> fileReject(int id) => {'t': 'file_reject', 'id': id};
  static Map<String, dynamic> fileDone(int id, String sha256) =>
      {'t': 'file_done', 'id': id, 'sha256': sha256};
}

/// §9 错误码。
abstract final class UuErrorCode {
  static const int protoUnsupported = 1001;
  static const int spkiPinMismatch = 1002;
  static const int pairCodeInvalid = 2001;
  static const int userRejected = 2002;
  static const int captureUnauthorized = 3001;
  static const int accessibilityDisabled = 3002;
  static const int fileInterrupted = 4001;
  static const int peerOffline = 4004; // 服务器扩展
  static const int signalingInvalid = 4005; // 服务器扩展

  static String describe(int code) => switch (code) {
        1001 => '协议版本不支持',
        1002 => 'SPKI pin 不匹配',
        2001 => '配对码无效/过期',
        2002 => '用户拒绝连接',
        3001 => '屏幕采集未授权',
        3002 => '无障碍服务未开启',
        4001 => '文件传输中断',
        4004 => '目标设备离线',
        4005 => '信令消息非法',
        _ => '未知错误($code)',
      };
}
