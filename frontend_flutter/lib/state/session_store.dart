import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/protocol/control_messages.dart';
import '../core/signaling/signaling_client.dart';
import '../core/transport/frame_codec.dart';
import '../core/transport/mock_transport.dart';
import '../core/transport/uu_ffi_transport.dart';
import '../core/transport/uu_transport.dart';
import '../platform/projection_service.dart';
import '../platform/video_decoder_service.dart';
import 'file_transfer_store.dart';
import 'settings_store.dart';

/// 会话角色。
enum SessionRole { none, controller, controlled }

/// 当前会话状态：持有 [UuTransport]、路由 §3 控制消息、驱动画面/输入/文件。
class SessionStore extends ChangeNotifier {
  final SettingsStore settings;
  final FileTransferStore files;
  final VideoDecoderService decoder;
  final ProjectionService projection;

  UuTransport? transport;
  int? connId;
  SessionRole role = SessionRole.none;
  String statusText = '未连接';
  bool usingMock = false;

  // 被控画面元数据（§3.3 screen_meta）
  int screenWidth = 0;
  int screenHeight = 0;

  StreamSubscription<Map<String, dynamic>>? _ctrlSub;
  StreamSubscription<UuDataFrame>? _videoSub;
  StreamSubscription<UuEvent>? _eventSub;
  int _lastVideoSeq = -1;

  /// 会议屏幕共享是否占用 MediaProjection（§10，由 AppState 注入）。
  /// Android 同一 App 不允许多个 MediaProjection 同时运行，被控采集需让位。
  bool Function()? screenShareBusyByMeeting;

  /// mock 会话时的对端 PC 模拟器（供文件页等演示触发）。
  MockPcSimulator? mockSimulator;

  SessionStore({
    required this.settings,
    required this.files,
    required this.decoder,
    required this.projection,
  });

  bool get isActive => transport != null && connId != null;

  /// 装配点：优先 FFI（真实 QUIC），native 库缺失时降级 mock。
  Future<void> startController(String addr, {String? peerPin}) async {
    await stop();
    try {
      final ffi = UuFfiTransport(
        deviceId: settings.deviceId,
        certDir: settings.certDir.isEmpty ? null : settings.certDir,
        listenPort: null,
      );
      await _open(ffi, addr, peerPin, mock: false);
    } catch (e) {
      debugPrint('FFI 传输不可用，降级 mock: $e');
      final (phone, pc) = MockTransport.createPair();
      mockSimulator = pc.attachPcSimulator();
      await _open(phone, 'mock://$addr', peerPin, mock: true);
    }
  }

  /// 纯 mock 会话（UI 演示/测试）。
  Future<void> startMockController(String addr) async {
    await stop();
    final (phone, pc) = MockTransport.createPair();
    mockSimulator = pc.attachPcSimulator();
    await _open(phone, addr, null, mock: true);
  }

  /// §8 relay_open：打洞失败后经服务器 QUIC 端口（8443，ALPN uudesk/1）中继。
  /// 双向流首条消息 relay_hello，随后正常 hello/session_open（服务器配对后转发）。
  Future<void> startRelay(String serverAddr, String peerDeviceId) async {
    await stop();
    try {
      final ffi = UuFfiTransport(
        deviceId: settings.deviceId,
        certDir: settings.certDir.isEmpty ? null : settings.certDir,
        listenPort: null,
      );
      await _open(ffi, serverAddr, null, mock: false, relayPeer: peerDeviceId);
    } catch (e) {
      debugPrint('relay FFI 不可用，降级 mock: $e');
      final (phone, pc) = MockTransport.createPair();
      mockSimulator = pc.attachPcSimulator();
      await _open(phone, 'mock://relay', null, mock: true);
    }
  }

  /// 手机被控：作为 controlled 端等待 PC 连接。
  /// mock 环境下用一对回环模拟 PC 侧行为。
  Future<void> startControlled() async {
    await stop();
    final (phone, pc) = MockTransport.createPair();
    transport = phone;
    role = SessionRole.controlled;
    usingMock = true;
    connId = 1;
    pc._asMockPeerOfPhone();
    statusText = '被控监听中（mock）';
    _bindStreams();
    phone.sendControl(1, UuMsg.hello('phone', settings.deviceId, settings.deviceName));
    notifyListeners();
  }

  Future<void> _open(UuTransport t, String addr, String? peerPin,
      {required bool mock, String? relayPeer}) async {
    transport = t;
    role = SessionRole.controller;
    usingMock = mock;
    statusText = mock ? '已连接（mock）' : '已连接（FFI）';
    connId = await t.connect(addr, peerPin: peerPin);
    _bindStreams();
    if (relayPeer != null) {
      // 中继流首条消息（§8），长度前缀由 uu-ffi 处理。
      t.sendControl(connId!, SignalingClient.relayHelloMessage(relayPeer, settings.deviceId));
    }
    t.sendControl(connId!, UuMsg.hello('phone', settings.deviceId, settings.deviceName));
    t.sendControl(connId!, UuMsg.sessionOpen('view_pc', ['input', 'clipboard', 'file']));
    notifyListeners();
  }

  void _bindStreams() {
    final t = transport!;
    _ctrlSub = t.controlMessages.listen(_onControl);
    _videoSub = t.videoFrames.listen(_onVideoFrame);
    _eventSub = t.events.listen((e) {
      if (e.type == 'disconnected') {
        statusText = '已断开';
        notifyListeners();
      } else if (e.type == 'error') {
        statusText = '错误：${e.message}';
        notifyListeners();
      }
    });
    files.bind(t, connId: connId ?? 1);
  }

  void _onControl(Map<String, dynamic> msg) {
    final t = msg['t'];
    switch (t) {
      case 'screen_meta':
        screenWidth = (msg['w'] as num?)?.toInt() ?? screenWidth;
        screenHeight = (msg['h'] as num?)?.toInt() ?? screenHeight;
        if (role == SessionRole.controller) {
          decoder.configure(screenWidth, screenHeight);
        }
        notifyListeners();
        break;
      case 'input':
        // 被控：转发给无障碍注入服务（§3.5 / §3.2 touch/text）。
        if (role == SessionRole.controlled) projection.inject(msg);
        break;
      case 'cap_start':
        if (role == SessionRole.controlled) {
          if (screenShareBusyByMeeting?.call() == true) {
            statusText = '会议屏幕共享中，无法同时被控采集';
            notifyListeners();
            break;
          }
          projection.startCapture().then((ok) {
            statusText = ok ? '采集中' : '采集未授权(3001)';
            notifyListeners();
          });
        }
        break;
      case 'cap_stop':
        if (role == SessionRole.controlled) {
          projection.stopCapture();
          statusText = '采集已停止';
          notifyListeners();
        }
        break;
      case 'inject_enable':
      case 'inject_disable':
        notifyListeners();
        break;
      case 'clip_set':
        if (settings.clipboardSync) {
          // TODO: 写入系统剪贴板（Clipboard.setData），以较大 ts 为准。
          transport?.sendControl(connId ?? 0, UuMsg.clipAck((msg['id'] as num?)?.toInt() ?? 0));
        }
        break;
      // 文件类消息由 FileTransferStore 直接订阅处理。
    }
  }

  void _onVideoFrame(UuDataFrame f) {
    final frame = VideoFrame.decode(f.data);
    if (frame == null) return;
    if (_lastVideoSeq >= 0 &&
        frame.seq != ((_lastVideoSeq + 1) & 0xFFFFFFFF) &&
        !frame.isKeyframe) {
      transport?.sendControl(connId ?? 0, UuMsg.keyframeReq());
    }
    _lastVideoSeq = frame.seq;
    decoder.decode(frame.payload, keyframe: frame.isKeyframe);
  }

  /// 控制端发送输入消息（归一化坐标）。
  void sendInput(Map<String, dynamic> message) {
    transport?.sendControl(connId ?? 0, message);
  }

  Future<void> stop() async {
    await _ctrlSub?.cancel();
    await _videoSub?.cancel();
    await _eventSub?.cancel();
    _ctrlSub = _videoSub = _eventSub = null;
    _lastVideoSeq = -1;
    await transport?.close();
    transport?.dispose();
    transport = null;
    connId = null;
    role = SessionRole.none;
    mockSimulator?.dispose();
    mockSimulator = null;
    files.unbind();
    await decoder.release();
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

extension on MockTransport {
  /// 被控演示：模拟 PC 侧连入并回复 hello_ack。
  void _asMockPeerOfPhone() {
    acceptMockConnection();
    controlMessages.listen((msg) {
      if (msg['t'] == 'hello') {
        sendControl(1, UuMsg.helloAck('mock-pc', 'Mock PC'));
      }
    });
  }
}
