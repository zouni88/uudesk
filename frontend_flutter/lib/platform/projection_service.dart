import 'dart:async';

import 'package:flutter/services.dart';

/// Android 被控能力服务：
/// - `uudesk/projection`（MethodChannel）：启停 MediaProjection 采集，
///   编码帧经 EventChannel `uudesk/camera_frame` 上抛 NAL 字节。
/// - `uudesk/accessibility`（MethodChannel）：下发 §3.2 input 指令 JSON 给
///   无障碍服务注入；状态经 EventChannel `uudesk/accessibility` 上报。
/// 无原生实现时安全降级。
class ProjectionService {
  static const MethodChannel _projection = MethodChannel('uudesk/projection');
  static const MethodChannel _accessibility = MethodChannel('uudesk/accessibility');
  static const EventChannel _cameraFrame = EventChannel('uudesk/camera_frame');
  static const EventChannel _a11yStatus = EventChannel('uudesk/accessibility');

  bool _capturing = false;
  StreamSubscription<dynamic>? _frameSub;
  StreamSubscription<dynamic>? _a11ySub;

  bool get capturing => _capturing;
  bool get accessibilityReady => _accessibilityAvailable;
  bool _accessibilityAvailable = false;

  /// 编码后的 NAL 帧字节流（供 sendVideo）。
  Stream<Uint8List> get nalFrames {
    return _cameraFrame.receiveBroadcastStream().where((e) => e is Uint8List).cast<Uint8List>();
  }

  /// 无障碍服务状态流（enabled / disabled）。
  Stream<String> get accessibilityStatus => _a11yStatus
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => (e as Map)['state'] as String? ?? 'unknown');

  /// 启动采集（首次会弹系统授权框）。
  Future<bool> startCapture() async {
    try {
      final ok = await _projection.invokeMethod<bool>('start') ?? false;
      _capturing = ok;
      return ok;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> stopCapture() async {
    try {
      await _projection.invokeMethod<void>('stop');
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
    _capturing = false;
    return true;
  }

  /// 会议共享保活：开启 mediaProjection 类型前台服务。
  /// Android 14+ 要求调用 getDisplayMedia 前已有该前台服务；同时避免共享期间
  /// 进程被回收（切回应用时 Activity/Flutter 引擎重建 = 应用“重启”）。
  Future<void> startShareKeepAlive() async {
    try {
      await _projection.invokeMethod<void>('shareStart');
    } on PlatformException {
      // ignore：保活失败不影响共享本身
    } on MissingPluginException {
      // ignore
    }
  }

  Future<void> stopShareKeepAlive() async {
    try {
      await _projection.invokeMethod<void>('shareStop');
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
  }

  /// 向无障碍服务下发一条 input 指令 JSON（§3.2）。
  Future<void> inject(Map<String, dynamic> message) async {
    try {
      await _accessibility.invokeMethod<void>('inject', message);
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
  }

  /// 开始监听无障碍状态（幂等）。
  void watchAccessibility() {
    if (_a11ySub != null) return;
    _a11ySub = accessibilityStatus.listen((s) {
      _accessibilityAvailable = s == 'enabled';
    });
  }

  Future<void> dispose() async {
    await _frameSub?.cancel();
    await _a11ySub?.cancel();
    _frameSub = null;
    _a11ySub = null;
  }
}
