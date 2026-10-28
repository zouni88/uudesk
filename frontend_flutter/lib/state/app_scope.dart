import 'package:flutter/widgets.dart';

import '../core/meeting/meeting_service.dart';
import '../platform/projection_service.dart';
import '../platform/video_decoder_service.dart';
import 'device_store.dart';
import 'file_transfer_store.dart';
import 'session_store.dart';
import 'settings_store.dart';

/// 全局依赖容器（ChangeNotifier 集合，不引入重型状态框架）。
class AppState {
  final SettingsStore settings;
  final FileTransferStore files;
  final VideoDecoderService decoder;
  final ProjectionService projection;
  final SessionStore session;
  final DeviceStore devices;
  final MeetingService meeting;

  AppState._({
    required this.settings,
    required this.files,
    required this.decoder,
    required this.projection,
    required this.session,
    required this.devices,
    required this.meeting,
  });

  static Future<AppState> bootstrap() async {
    final settings = SettingsStore();
    await settings.load();
    final files = FileTransferStore();
    final decoder = VideoDecoderService();
    final projection = ProjectionService();
    final session = SessionStore(
      settings: settings,
      files: files,
      decoder: decoder,
      projection: projection,
    );
    final devices = DeviceStore(settings);
    final meeting = MeetingService();
    // 会议屏幕共享与被控采集共用 MediaProjection，Android 不允许同时运行：
    // 被控端收到 cap_start 时若会议共享进行中，拒绝并提示（UI 互斥）。
    session.screenShareBusyByMeeting = () => meeting.screenOn;
    // 会中控制（§10.4）：本机共享且已授权时，观看方 input 经无障碍注入本机屏幕。
    meeting.controlInputHandler = projection.inject;
    return AppState._(
      settings: settings,
      files: files,
      decoder: decoder,
      projection: projection,
      session: session,
      devices: devices,
      meeting: meeting,
    );
  }

  void dispose() {
    session.dispose();
    devices.dispose();
    files.dispose();
    projection.dispose();
    meeting.dispose();
  }
}

/// InheritedWidget 暴露 [AppState]。
class AppScope extends InheritedWidget {
  final AppState state;

  const AppScope({super.key, required this.state, required super.child});

  /// 在 build 中读取并注册依赖（AppState 变化时重建）。
  static AppState of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(w != null, 'AppScope 未在 widget 树中');
    return w!.state;
  }

  /// 在 initState 等非 build 场景读取，不注册依赖。
  static AppState read(BuildContext context) {
    final w = context.getInheritedWidgetOfExactType<AppScope>();
    assert(w != null, 'AppScope 未在 widget 树中');
    return w!.state;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => state != oldWidget.state;
}
