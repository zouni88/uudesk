import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 配对过的设备记录。
class PairedDevice {
  final String deviceId;
  final String name;
  final String role;
  String? lastAddr;

  PairedDevice({required this.deviceId, required this.name, required this.role, this.lastAddr});

  Map<String, dynamic> toJson() =>
      {'device_id': deviceId, 'name': name, 'role': role, 'last_addr': lastAddr};

  factory PairedDevice.fromJson(Map<String, dynamic> j) => PairedDevice(
        deviceId: j['device_id'] as String,
        name: j['name'] as String? ?? '',
        role: j['role'] as String? ?? 'pc',
        lastAddr: j['last_addr'] as String?,
      );
}

/// 设置持久化：服务器地址、device_id/证书目录、剪贴板同步开关、已配对设备。
class SettingsStore extends ChangeNotifier {
  static const _fileName = 'uudesk_settings.json';

  String serverUrl = 'http://192.168.3.41:8080';
  String deviceId = '';
  String deviceName = '';
  String certDir = '';
  bool clipboardSync = true;
  final List<PairedDevice> pairedDevices = [];

  // ===== 会议会话（Activity/Flutter 引擎被系统重建后用于恢复入会状态）=====
  String meetingRoom = '';
  String meetingServer = '';
  String meetingName = '';
  bool meetingMicOn = true;
  bool meetingCamOn = false;
  int meetingSavedAt = 0; // 毫秒时间戳

  /// 是否存在可恢复的会议会话。
  bool get meetingActive => meetingRoom.isNotEmpty && meetingServer.isNotEmpty;

  File? _file;

  Future<void> load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/$_fileName');
      if (await _file!.exists()) {
        final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        serverUrl = j['server_url'] as String? ?? serverUrl;
        deviceId = j['device_id'] as String? ?? '';
        deviceName = j['device_name'] as String? ?? '';
        certDir = j['cert_dir'] as String? ?? '';
        clipboardSync = j['clipboard_sync'] as bool? ?? true;
        meetingRoom = j['meeting_room'] as String? ?? '';
        meetingServer = j['meeting_server'] as String? ?? '';
        meetingName = j['meeting_name'] as String? ?? '';
        meetingMicOn = j['meeting_mic_on'] as bool? ?? true;
        meetingCamOn = j['meeting_cam_on'] as bool? ?? false;
        meetingSavedAt = (j['meeting_saved_at'] as num?)?.toInt() ?? 0;
        pairedDevices
          ..clear()
          ..addAll((j['paired'] as List? ?? [])
              .map((e) => PairedDevice.fromJson(e as Map<String, dynamic>)));
      }
    } catch (_) {
      // 首次运行或文件损坏：使用默认值
    }
    // 首次运行（无配置文件）时也要生成 deviceId，否则会议 identity 为空。
    if (deviceId.isEmpty) {
      deviceId = _generateDeviceId();
      save();
    }
    notifyListeners();
  }

  Future<void> save() async {
    final f = _file;
    if (f == null) return;
    final j = {
      'server_url': serverUrl,
      'device_id': deviceId,
      'device_name': deviceName,
      'cert_dir': certDir,
      'clipboard_sync': clipboardSync,
      'meeting_room': meetingRoom,
      'meeting_server': meetingServer,
      'meeting_name': meetingName,
      'meeting_mic_on': meetingMicOn,
      'meeting_cam_on': meetingCamOn,
      'meeting_saved_at': meetingSavedAt,
      'paired': pairedDevices.map((e) => e.toJson()).toList(),
    };
    await f.writeAsString(jsonEncode(j));
  }

  void update({String? serverUrl, String? deviceId, String? deviceName, String? certDir, bool? clipboardSync}) {
    this.serverUrl = serverUrl ?? this.serverUrl;
    this.deviceId = deviceId ?? this.deviceId;
    this.deviceName = deviceName ?? this.deviceName;
    this.certDir = certDir ?? this.certDir;
    this.clipboardSync = clipboardSync ?? this.clipboardSync;
    notifyListeners();
    save();
  }

  void addPaired(PairedDevice d) {
    pairedDevices.removeWhere((e) => e.deviceId == d.deviceId);
    pairedDevices.add(d);
    notifyListeners();
    save();
  }

  void removePaired(String deviceId) {
    pairedDevices.removeWhere((e) => e.deviceId == deviceId);
    notifyListeners();
    save();
  }

  /// 入会成功后记录会话，供系统重建进程/Activity 后自动恢复。
  Future<void> saveMeetingSession({
    required String room,
    required String server,
    required String name,
    required bool micOn,
    required bool camOn,
  }) async {
    meetingRoom = room;
    meetingServer = server;
    meetingName = name;
    meetingMicOn = micOn;
    meetingCamOn = camOn;
    meetingSavedAt = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    await save();
  }

  /// 主动离开会议/恢复失败时清除会话，避免下次启动误入会。
  Future<void> clearMeetingSession() async {
    if (meetingRoom.isEmpty && meetingSavedAt == 0) return;
    meetingRoom = '';
    meetingServer = '';
    meetingName = '';
    meetingMicOn = true;
    meetingCamOn = false;
    meetingSavedAt = 0;
    notifyListeners();
    await save();
  }

  /// 占位 device_id（§1 正式实现为 base32(SHA256(SPKI DER)) 前 16 字符，
  /// 证书由 Rust uu-ffi 侧生成管理）。
  String _generateDeviceId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final rnd = DateTime.now().microsecondsSinceEpoch;
    return List.generate(16, (i) => chars[(rnd ~/ (1 << (i % 10))) % chars.length]).join();
  }
}
