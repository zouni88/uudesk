import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/signaling/signaling_client.dart';
import '../../state/session_store.dart';
import '../../state/settings_store.dart';

/// §8 配对流程控制器：
/// - 被控侧：gen_code 显示本机 6 位码 / revoke_code 撤销；处理 invite。
/// - 控制侧：输入对方码 POST /api/pair；invite_result 接受后
///   reflect→candidates 交换地址打洞，失败则 relay_open 走服务器中继。
class PairingController extends ChangeNotifier {
  final SettingsStore settings;
  final SessionStore session;

  String localCode = '';
  DateTime? localCodeExpiry;
  String status = '';
  bool busy = false;

  /// 收到的 invite（from=发起方设备名，device_id=发起方 id，§8）。
  Map<String, dynamic>? pendingInvite;

  SignalingClient? _sig;
  StreamSubscription<Map<String, dynamic>>? _sigSub;
  String? _waitingPeer; // 控制侧：等待 invite_result 的对端 id

  PairingController({required this.settings, required this.session});

  /// 生成/刷新本机配对码。优先走信令服务器 gen_code；
  /// 服务器不可达时本地生成并提示离线模式。
  Future<void> refreshLocalCode() async {
    busy = true;
    notifyListeners();
    try {
      final sig = SignalingClient(settings.serverUrl);
      _sig = sig;
      final reg = await sig
          .register(
            name: settings.deviceName.isEmpty ? 'phone' : settings.deviceName,
            role: 'phone',
            deviceId: settings.deviceId,
            spkiPin: settings.deviceId, // 证书由 uu-ffi 侧管理，v1 以 device_id 占位
          )
          .timeout(const Duration(seconds: 5));
      await sig.connectWs(reg['token'] as String).timeout(const Duration(seconds: 5));
      _sigSub = sig.messages.listen(_onSignaling);
      sig.requestGenCode();
      status = '已通过服务器生成配对码';
    } catch (e) {
      localCode = _localRandomCode();
      localCodeExpiry = DateTime.now().add(const Duration(minutes: 10));
      status = '服务器不可达，本地生成（离线演示）';
    }
    busy = false;
    notifyListeners();
  }

  void revokeCode() {
    _sig?.revokeCode();
    localCode = '';
    localCodeExpiry = null;
    status = '配对码已撤销';
    notifyListeners();
  }

  /// 用对方 6 位码发起配对并建立会话。
  Future<void> connectWithCode(String code) async {
    if (code.length != 6 || int.tryParse(code) == null) {
      status = '配对码需为 6 位数字';
      notifyListeners();
      return;
    }
    busy = true;
    status = '正在配对…';
    notifyListeners();
    try {
      final sig = _sig ?? SignalingClient(settings.serverUrl);
      _sig = sig;
      if (!sig.isConnected) {
        try {
          final reg = await sig
              .register(
                name: settings.deviceName.isEmpty ? 'phone' : settings.deviceName,
                role: 'phone',
                deviceId: settings.deviceId,
                spkiPin: settings.deviceId,
              )
              .timeout(const Duration(seconds: 5));
          await sig.connectWs(reg['token'] as String).timeout(const Duration(seconds: 5));
          _sigSub = sig.messages.listen(_onSignaling);
        } catch (_) {
          status = '服务器不可达，直接演示连接';
          await session.startController('pair://$code');
          busy = false;
          notifyListeners();
          return;
        }
      }
      await sig.pair(code, settings.deviceId).timeout(const Duration(seconds: 5));
      _waitingPeer = 'peer-$code';
      status = '配对请求已发送，等待对方接受…';
    } catch (e) {
      status = '配对失败：$e';
    }
    busy = false;
    notifyListeners();
  }

  void _onSignaling(Map<String, dynamic> m) {
    switch (m['t']) {
      case 'code':
        localCode = m['code'] as String? ?? '';
        localCodeExpiry = DateTime.now()
            .add(Duration(seconds: (m['expires_in'] as num?)?.toInt() ?? 600));
        notifyListeners();
        break;
      case 'invite':
        // 被控侧收到邀请：展示 from/device_id 供用户确认与 pin 校验。
        pendingInvite = m;
        status = '收到 ${m['from']} 的连接请求';
        notifyListeners();
        break;
      case 'invite_result':
        if (m['accept'] == true) {
          final peer = m['to'] as String? ?? _waitingPeer ?? '';
          _waitingPeer = null;
          status = '对方已接受，交换候选地址…';
          _exchangeCandidates(peer);
        } else {
          status = '对方拒绝连接（2002）';
        }
        notifyListeners();
        break;
      case 'candidates':
        final peer = m['peer'] as String? ?? '';
        final addrs = (m['addrs'] as List? ?? []).map((e) => e.toString()).toList();
        if (addrs.isNotEmpty) {
          status = '直连 $peer …';
          notifyListeners();
          session.startController(addrs.first, peerPin: peer);
        }
        break;
      case 'relay_open':
        final peer = m['peer'] as String? ?? '';
        status = '打洞失败，走服务器中继（$peer）';
        notifyListeners();
        session.startRelay(_relayHost, peer);
        break;
      case 'error':
        status = '信令错误 ${m['code']}: ${m['msg']}';
        notifyListeners();
        break;
    }
  }

  /// §8：先 reflect 拿自身公网地址，再上报 candidates（服务端改写 peer 并回填）。
  Future<void> _exchangeCandidates(String peer) async {
    final sig = _sig;
    if (sig == null) return;
    var addrs = <String>[];
    try {
      addrs = await sig.reflect().timeout(const Duration(seconds: 5));
    } catch (_) {
      addrs = await sig.requestReflect();
    }
    if (addrs.isNotEmpty) sig.reportCandidates(peer, addrs);
  }

  String get _relayHost {
    final u = Uri.parse(settings.serverUrl);
    return '${u.host}:${SignalingClient.relayQuicPort}';
  }

  /// 被控侧应答 invite（device_id 作为 SPKI pin 校验）。
  void answerInvite(bool accept) {
    final inv = pendingInvite;
    if (inv == null) return;
    _sig?.answerInvite(inv['device_id'] as String? ?? '', accept);
    if (accept) {
      // 被控侧同样 reflect→candidates 交换；等待控制端连入。
      _exchangeCandidates(inv['device_id'] as String? ?? '');
      session.startControlled();
    }
    pendingInvite = null;
    notifyListeners();
  }

  String _localRandomCode() => (100000 + Random().nextInt(900000)).toString();

  @override
  void dispose() {
    _sigSub?.cancel();
    _sig?.close();
    super.dispose();
  }
}
