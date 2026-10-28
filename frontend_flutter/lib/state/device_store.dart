import 'package:flutter/foundation.dart';

import '../core/discovery/lan_discovery.dart';
import 'settings_store.dart';

/// 设备列表：§6 LAN 组播发现结果 + 已配对设备。
class DeviceStore extends ChangeNotifier {
  final SettingsStore settings;
  final LanDiscovery _discovery = LanDiscovery();

  List<LanDevice> lanDevices = const [];

  DeviceStore(this.settings) {
    _discovery.devices.listen((list) {
      lanDevices = list;
      notifyListeners();
    });
  }

  List<PairedDevice> get paired => settings.pairedDevices;

  Future<void> startDiscovery() async {
    try {
      await _discovery.start(
        advertiseDeviceId: settings.deviceId.isEmpty ? null : settings.deviceId,
        role: 'phone',
        name: settings.deviceName,
        quicPort: 0, // 手机端 QUIC 监听端口由 uu-ffi 分配，v1 仅监听
      );
    } catch (e) {
      debugPrint('LAN discovery unavailable: $e');
    }
  }

  Future<void> stopDiscovery() => _discovery.stop();

  @override
  Future<void> dispose() async {
    await _discovery.dispose();
    super.dispose();
  }
}
