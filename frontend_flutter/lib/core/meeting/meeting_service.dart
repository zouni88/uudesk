// 会议入会排障需要日志直接出现在控制台，统一用 print。
// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter/foundation.dart'; // ChangeNotifier
// livekit_client 自带 ChatMessage（data stream），与本模块聊天模型重名，hide 之。
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;

import '../signaling/signaling_client.dart';
import 'meeting_models.dart';

/// 会议令牌信息（§10.1）。
class MeetingTokenInfo {
  final String token;
  final String serverUrl;
  const MeetingTokenInfo(this.token, this.serverUrl);
}

/// 信令服务器会议相关 API（§10.1/§10.2），便于测试注入 mock。
abstract interface class MeetingApi {
  Future<Map<String, dynamic>> meetingToken({
    required String room,
    required String identity,
    bool canPublish,
  });
  Future<Map<String, dynamic>> startEgress(String room);
  Future<Map<String, dynamic>> stopEgress(String room);
}

/// [SignalingClient] 适配 [MeetingApi]。
class SignalingMeetingApi implements MeetingApi {
  final SignalingClient client;
  SignalingMeetingApi(this.client);

  @override
  Future<Map<String, dynamic>> meetingToken({
    required String room,
    required String identity,
    bool canPublish = true,
  }) => client.meetingToken(
    room: room,
    identity: identity,
    canPublish: canPublish,
  );

  @override
  Future<Map<String, dynamic>> startEgress(String room) =>
      client.startMeetingEgress(room);

  @override
  Future<Map<String, dynamic>> stopEgress(String room) =>
      client.stopMeetingEgress(room);
}

class MeetingException implements Exception {
  final String message;
  MeetingException(this.message);
  @override
  String toString() => 'MeetingException: $message';
}

/// 多人会议服务（§10）：令牌签发 → LiveKit 连接 → 状态流。
///
/// 状态流：成员列表（[members]）、发言检测（[MeetingMember.speaking]）、
/// 聊天（[chats]）、举手（[raisedHands]）、反应（[reactions]）、录制（[recording]）。
class MeetingService extends ChangeNotifier {
  MeetingService({
    MeetingApi Function(String serverUrl)? apiFor,
    Room Function()? roomFactory,
  }) : _apiFor = apiFor ?? ((url) => SignalingMeetingApi(SignalingClient(url))),
       _roomFactory = roomFactory ?? Room.new;

  final MeetingApi Function(String serverUrl) _apiFor;
  final Room Function() _roomFactory;

  Room? _room;
  CancelListenFunc? _roomCancel;

  String signalingUrl = '';
  String roomName = '';
  String displayName = '';
  String selfIdentity = '';
  DateTime? joinedAt;
  String? lastError;

  bool micOn = false;
  bool camOn = false;
  bool screenOn = false;
  bool recording = false;

  /// 是否处于网络重连中（用于 UI 提示，避免误以为已断开）
  bool reconnecting = false;

  final List<ChatMessage> chats = [];
  final List<MeetingReaction> reactions = [];
  int unreadChat = 0;

  final Set<String> _raisedHands = {};
  Set<String> _speaking = {};

  // ===== 会中屏幕共享控制（飞书式，§10.4）=====
  /// 共享者侧：收到观看方的控制请求（viewerIdentity → 显示名）。
  final Map<String, String> controlRequests = {};

  /// 共享者侧：已授权控制的观看方 identity。
  final Set<String> controlGranted = {};

  /// 观看方侧：当前正在控制的共享者 identity（未授权为 null）。
  String? controlSharer;

  /// 共享者侧注入回调：由 AppState 接无障碍注入（手机被控链路复用）。
  void Function(Map<String, dynamic> ev)? controlInputHandler;

  /// 我是否正在共享且已授权他人控制。
  bool get sharingControlledByOthers => screenOn && controlGranted.isNotEmpty;

  bool get inMeeting => _room != null;
  bool get connected => _room?.connectionState == ConnectionState.connected;
  Set<String> get raisedHands => _raisedHands;
  Set<String> get speakingIdentities => _speaking;

  /// 成员快照：本端 + 远端（含视频/共享轨道，供 UI 渲染）。
  List<MeetingMember> get members {
    final r = _room;
    if (r == null) return const [];
    final out = <MeetingMember>[];
    final local = r.localParticipant;
    if (local != null) {
      out.add(
        MeetingMember(
          identity: local.identity,
          name: displayName.isNotEmpty ? displayName : local.name,
          isSelf: true,
          micOn: micOn,
          camOn: camOn,
          speaking: _speaking.contains(local.identity),
          handRaised: _raisedHands.contains(local.identity),
          videoTrack: _videoOf(local, TrackSource.camera),
          shareTrack: _videoOf(local, TrackSource.screenShareVideo),
        ),
      );
    }
    for (final p in r.remoteParticipants.values) {
      out.add(
        MeetingMember(
          identity: p.identity,
          name: p.name.isNotEmpty ? p.name : p.identity,
          isSelf: false,
          micOn: p.isMicrophoneEnabled(),
          camOn: p.isCameraEnabled(),
          speaking: _speaking.contains(p.identity),
          handRaised: _raisedHands.contains(p.identity),
          videoTrack: _videoOf(p, TrackSource.camera),
          shareTrack: _videoOf(p, TrackSource.screenShareVideo),
        ),
      );
    }
    return out;
  }

  static VideoTrack? _videoOf(Participant p, TrackSource source) {
    final track = p.getTrackPublicationBySource(source)?.track;
    return track is VideoTrack ? track : null;
  }

  /// §10.1 取令牌：`POST /api/meeting/token {room, identity, can_publish}`。
  Future<MeetingTokenInfo> requestToken({
    required String serverUrl,
    required String room,
    required String identity,
    bool canPublish = true,
  }) async {
    final resp = await _apiFor(
      serverUrl,
    ).meetingToken(room: room, identity: identity, canPublish: canPublish);
    final token = resp['token'] as String? ?? '';
    final lkUrl = resp['server_url'] as String? ?? '';
    if (token.isEmpty || lkUrl.isEmpty) {
      print(
        '[meeting] requestToken failed: response missing '
        'token/server_url, keys=${resp.keys.toList()}',
      );
      throw MeetingException('令牌响应缺少 token/server_url');
    }
    return MeetingTokenInfo(token, lkUrl);
  }

  /// 入会：取 token → 连接 LiveKit → 默认开麦。identity 用 device_id（§10.1）。
  Future<void> join({
    required String serverUrl,
    required String room,
    required String identity,
    required String displayName,
  }) async {
    await leave();
    signalingUrl = serverUrl;
    roomName = room;
    this.displayName = displayName;
    selfIdentity = identity;
    lastError = null;
    print(
      '[meeting] join server=$serverUrl room=$room '
      'identity=$identity name=$displayName',
    );
    MeetingTokenInfo tk;
    try {
      tk = await requestToken(
        serverUrl: serverUrl,
        room: room,
        identity: identity,
      );
    } catch (e) {
      print('[meeting] join failed at requestToken: $e');
      rethrow;
    }
    print(
      '[meeting] token ok, livekit_url=${tk.serverUrl} '
      'token_len=${tk.token.length}',
    );
    final r = _room = _roomFactory();
    _bind(r);
    try {
      await r.connect(tk.serverUrl, tk.token);
      print('[meeting] livekit connected');
      // 显示名尽力而为（需 token 带 canUpdateOwnMetadata，失败不影响入会）。
      try {
        await r.localParticipant?.setName(displayName);
      } catch (_) {}
      // 开麦失败不应导致整个入会失败（例如设备被占用）
      try {
        await setMic(true);
      } catch (e) {
        print('[meeting] setMic(true) failed after join: $e');
        lastError = '麦克风开启失败：$e';
      }
      joinedAt = DateTime.now();
    } catch (e) {
      print('[meeting] join failed at livekit connect(${tk.serverUrl}): $e');
      lastError = '$e';
      _teardown();
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  void _bind(Room r) {
    _roomCancel = r.events.listen((e) {
      switch (e) {
        case RoomDisconnectedEvent():
          print('[meeting] room disconnected');
          lastError = '会议已断开';
          reconnecting = false;
          _teardown();
        case RoomReconnectingEvent():
          reconnecting = true;
        case RoomReconnectedEvent():
          reconnecting = false;
        case ActiveSpeakersChangedEvent(:final speakers):
          _speaking = {for (final p in speakers) p.identity};
        // 成员/轨道变化必须刷新快照，否则远端开摄像头、加入、离开、静音都不会更新 UI
        case ParticipantConnectedEvent():
        case ParticipantDisconnectedEvent():
        case TrackPublishedEvent():
        case TrackUnpublishedEvent():
        case TrackSubscribedEvent():
        case TrackUnsubscribedEvent():
        case TrackMutedEvent():
        case TrackUnmutedEvent():
          break;
        case DataReceivedEvent(:final topic, :final data, :final participant):
          ingestData(
            topic: topic,
            data: data,
            fromIdentity: participant?.identity ?? '',
            fromName: participant?.name ?? '',
          );
        case RoomRecordingStatusChanged(:final activeRecording):
          recording = activeRecording;
        default:
          break;
      }
      notifyListeners();
    });
  }

  /// §10.2 data channel 消息解码并入状态流（不依赖 Room，可单测）。
  void ingestData({
    required String? topic,
    required List<int> data,
    required String fromIdentity,
    String fromName = '',
  }) {
    try {
      switch (topic) {
        case MeetingTopics.chat:
          chats.add(
            ChatMessage(
              identity: fromIdentity,
              name: fromName.isEmpty ? fromIdentity : fromName,
              text: decodeChat(data),
              ts: DateTime.now(),
            ),
          );
          if (chats.length > 200) chats.removeRange(0, chats.length - 200);
          unreadChat++;
        case MeetingTopics.raiseHand:
          final raised = decodeRaiseHand(data);
          if (raised) {
            _raisedHands.add(fromIdentity);
          } else {
            _raisedHands.remove(fromIdentity);
          }
        case MeetingTopics.reaction:
          reactions.add(
            MeetingReaction(
              identity: fromIdentity,
              name: fromName.isEmpty ? fromIdentity : fromName,
              emoji: decodeReaction(data),
              ts: DateTime.now(),
            ),
          );
          if (reactions.length > 20) {
            reactions.removeRange(0, reactions.length - 20);
          }
        case MeetingTopics.control:
          final j = decodeControl(data);
          if (j == null) break;
          final to = j['to'];
          final name = fromName.isEmpty ? fromIdentity : fromName;
          switch (j['a']) {
            case 'req':
              if (to == selfIdentity) controlRequests[fromIdentity] = name;
            case 'grant':
              if (to == selfIdentity) controlSharer = fromIdentity;
            case 'revoke':
              if (to == selfIdentity && controlSharer == fromIdentity) {
                controlSharer = null;
              }
            case 'release':
              if (to == selfIdentity) {
                controlRequests.remove(fromIdentity);
                controlGranted.remove(fromIdentity);
              }
            case 'input':
              final ev = j['ev'];
              if (to == selfIdentity &&
                  screenOn &&
                  controlGranted.contains(fromIdentity) &&
                  ev is Map<String, dynamic>) {
                controlInputHandler?.call(ev);
              }
          }
        default:
          break;
      }
    } catch (_) {
      // 非法 payload 忽略。
    }
  }

  LocalParticipant? get _local => _room?.localParticipant;

  Future<void> setMic(bool on) async {
    final l = _local;
    if (l == null) return;
    try {
      await l.setMicrophoneEnabled(on);
      micOn = on;
    } catch (e) {
      lastError = '麦克风${on ? '开启' : '关闭'}失败：$e';
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  Future<void> toggleMic() => setMic(!micOn);

  Future<void> toggleCamera() async {
    final l = _local;
    if (l == null) return;
    final next = !camOn;
    try {
      await l.setCameraEnabled(next);
      camOn = next;
    } catch (e) {
      // 失败不回滚 UI 状态，避免“显示已开摄像头但没有画面”
      lastError = '摄像头${next ? '开启' : '关闭'}失败：$e';
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  /// 屏幕共享（Android 走 LiveKit/flutter_webrtc 自带 MediaProjection 授权流程）。
  Future<void> toggleScreenShare() async {
    final l = _local;
    if (l == null) return;
    final next = !screenOn;
    try {
      await l.setScreenShareEnabled(next);
      screenOn = next;
    } catch (e) {
      lastError = '屏幕共享${next ? '开启' : '停止'}失败：$e';
      notifyListeners();
      rethrow;
    }
    if (!next) {
      // 停止共享即收回全部控制授权。
      controlGranted.clear();
      controlRequests.clear();
    }
    notifyListeners();
  }

  // ===== 会中控制协商（§10.4，data channel topic uudesk/control）=====

  Future<void> _publishControl(
    Map<String, dynamic> msg,
    String? dest, {
    bool reliable = true,
  }) async {
    final l = _local;
    if (l == null) return;
    await l.publishData(
      encodeControl(msg),
      topic: MeetingTopics.control,
      reliable: reliable,
      destinationIdentities: dest == null ? null : [dest],
    );
  }

  /// 观看方：请求控制共享者屏幕。
  Future<void> requestControl(String sharerIdentity) =>
      _publishControl({'a': 'req', 'to': sharerIdentity}, sharerIdentity);

  /// 共享方：同意某观看方控制。
  Future<void> grantControl(String viewerIdentity) async {
    controlRequests.remove(viewerIdentity);
    controlGranted.add(viewerIdentity);
    await _publishControl({'a': 'grant', 'to': viewerIdentity}, viewerIdentity);
    notifyListeners();
  }

  /// 共享方：拒绝控制请求（本地清除，不回复）。
  void rejectControl(String viewerIdentity) {
    controlRequests.remove(viewerIdentity);
    notifyListeners();
  }

  /// 共享方：收回某观看方的控制。
  Future<void> revokeControl(String viewerIdentity) async {
    controlGranted.remove(viewerIdentity);
    await _publishControl({
      'a': 'revoke',
      'to': viewerIdentity,
    }, viewerIdentity);
    notifyListeners();
  }

  /// 观看方：主动退出控制。
  Future<void> releaseControl() async {
    final s = controlSharer;
    controlSharer = null;
    if (s != null) {
      await _publishControl({'a': 'release', 'to': s}, s);
    }
    notifyListeners();
  }

  /// 观看方：发送一条 §3.2 input 事件（move 走不可靠通道降延迟）。
  Future<void> sendControlInput(Map<String, dynamic> ev) async {
    final s = controlSharer;
    if (s == null) return;
    await _publishControl(
      {'a': 'input', 'to': s, 'ev': ev},
      s,
      reliable: ev['k'] != 'move',
    );
  }

  Future<void> sendChat(String text) async {
    final t = text.trim();
    if (t.isEmpty || _local == null) return;
    await _local!.publishData(
      encodeChat(t),
      topic: MeetingTopics.chat,
      reliable: true,
    );
    chats.add(
      ChatMessage(
        identity: selfIdentity,
        name: displayName,
        text: t,
        ts: DateTime.now(),
        isSelf: true,
      ),
    );
    notifyListeners();
  }

  /// 举手/放下（本端状态与广播同步维护）。
  Future<void> setHandRaised(bool raised) async {
    if (_local != null) {
      await _local!.publishData(
        encodeRaiseHand(raised),
        topic: MeetingTopics.raiseHand,
        reliable: true,
      );
    }
    if (raised) {
      _raisedHands.add(selfIdentity);
    } else {
      _raisedHands.remove(selfIdentity);
    }
    notifyListeners();
  }

  bool get selfHandRaised => _raisedHands.contains(selfIdentity);

  Future<void> sendReaction(String emoji) async {
    if (_local != null) {
      await _local!.publishData(
        encodeReaction(emoji),
        topic: MeetingTopics.reaction,
        reliable: true,
      );
    }
    reactions.add(
      MeetingReaction(
        identity: selfIdentity,
        name: displayName,
        emoji: emoji,
        ts: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  /// §10.2 录制：`POST /api/meeting/egress/start {room}`。
  Future<void> startRecording() async {
    await _apiFor(signalingUrl).startEgress(roomName);
    recording = true;
    notifyListeners();
  }

  /// 停止录制（规范未定义 stop 端点，按 `POST /api/meeting/egress/stop` 假设）。
  Future<void> stopRecording() async {
    await _apiFor(signalingUrl).stopEgress(roomName);
    recording = false;
    notifyListeners();
  }

  void markChatRead() {
    if (unreadChat == 0) return;
    unreadChat = 0;
    notifyListeners();
  }

  /// 离开房间并清理全部会中状态。
  Future<void> leave() async {
    final r = _room;
    if (r == null) return;
    // 会中控制：尽力通知对端（释放观看方身份/收回共享方授权）。
    final s = controlSharer;
    if (s != null) {
      try {
        await _publishControl({'a': 'release', 'to': s}, s);
      } catch (_) {}
    }
    for (final v in controlGranted.toList()) {
      try {
        await _publishControl({'a': 'revoke', 'to': v}, v);
      } catch (_) {}
    }
    _room = null;
    await _roomCancel?.call();
    _roomCancel = null;
    try {
      await r.disconnect();
    } catch (_) {}
    r.dispose();
    _resetState();
    notifyListeners();
  }

  void _teardown() {
    _roomCancel?.call();
    _roomCancel = null;
    _room = null;
    _resetState();
  }

  void _resetState() {
    roomName = '';
    displayName = '';
    selfIdentity = '';
    joinedAt = null;
    micOn = camOn = screenOn = recording = false;
    reconnecting = false;
    chats.clear();
    reactions.clear();
    _raisedHands.clear();
    _speaking.clear();
    unreadChat = 0;
    controlRequests.clear();
    controlGranted.clear();
    controlSharer = null;
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}
