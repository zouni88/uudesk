import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// §6 局域网发现：UDP 组播 239.255.77.233:37723。
/// 通告 JSON：`{"svc":"uudesk","v":1,"device_id","role","name","quic_port","ts"}`，
/// 每 3 秒发送；监听者缓存 10 秒超时。
class LanDiscovery {
  static final InternetAddress groupAddress =
      InternetAddress('239.255.77.233', type: InternetAddressType.IPv4);
  static const int port = 37723;
  static const Duration advertiseInterval = Duration(seconds: 3);
  static const Duration cacheTimeout = Duration(seconds: 10);

  RawDatagramSocket? _socket;
  Timer? _advertiseTimer;
  Timer? _sweepTimer;
  final Map<String, _Entry> _peers = {};
  final _updates = StreamController<List<LanDevice>>.broadcast();

  Stream<List<LanDevice>> get devices => _updates.stream;

  /// 开始监听（并可选地周期性通告本机）。
  Future<void> start({
    String? advertiseDeviceId,
    String role = 'phone',
    String name = '',
    int quicPort = 0,
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    try {
      socket.joinMulticast(groupAddress);
    } catch (_) {
      // 部分平台/网络不支持组播时退化为仅监听本机广播。
    }
    _socket = socket;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      _handleAdvertisement(dg.data, dg.address);
    });
    if (advertiseDeviceId != null && quicPort > 0) {
      _advertiseTimer = Timer.periodic(advertiseInterval, (_) {
        _advertise(advertiseDeviceId, role, name, quicPort);
      });
      _advertise(advertiseDeviceId, role, name, quicPort);
    }
    _sweepTimer = Timer.periodic(const Duration(seconds: 2), (_) => _sweep());
  }

  void _advertise(String deviceId, String role, String name, int quicPort) {
    final payload = utf8.encode(jsonEncode({
      'svc': 'uudesk', 'v': 1, 'device_id': deviceId, 'role': role,
      'name': name, 'quic_port': quicPort, 'ts': DateTime.now().millisecondsSinceEpoch,
    }));
    _socket?.send(payload, groupAddress, port);
  }

  void _handleAdvertisement(List<int> bytes, InternetAddress from) {
    try {
      final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (j['svc'] != 'uudesk') return;
      final id = j['device_id'] as String?;
      if (id == null) return;
      _peers[id] = _Entry(LanDevice(
        deviceId: id,
        role: j['role'] as String? ?? '',
        name: j['name'] as String? ?? '',
        quicPort: (j['quic_port'] as num?)?.toInt() ?? 0,
        address: from.address,
      ), DateTime.now());
      _emit();
    } catch (_) {/* 忽略坏包 */}
  }

  void _sweep() {
    final now = DateTime.now();
    final before = _peers.length;
    _peers.removeWhere((_, e) => now.difference(e.seen) > cacheTimeout);
    if (_peers.length != before) _emit();
  }

  void _emit() => _updates.add(snapshot());

  List<LanDevice> snapshot() {
    final list = _peers.values.map((e) => e.device).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  Future<void> stop() async {
    _advertiseTimer?.cancel();
    _sweepTimer?.cancel();
    _socket?.close();
    _socket = null;
    _peers.clear();
  }

  Future<void> dispose() async {
    await stop();
    await _updates.close();
  }
}

class LanDevice {
  final String deviceId;
  final String role;
  final String name;
  final int quicPort;
  final String address;

  const LanDevice({
    required this.deviceId,
    required this.role,
    required this.name,
    required this.quicPort,
    required this.address,
  });

  String get quicAddr => '$address:$quicPort';
}

class _Entry {
  final LanDevice device;
  final DateTime seen;
  _Entry(this.device, this.seen);
}
