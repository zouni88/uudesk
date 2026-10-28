import 'dart:convert';

import 'package:livekit_client/livekit_client.dart';

/// §10.2 会中 data channel topic 约定。
abstract final class MeetingTopics {
  /// 会中文字聊天（LiveKit 标准 topic）。
  static const String chat = 'lk.chat';
  /// 举手：payload `{"raised":bool}`。
  static const String raiseHand = 'uudesk/raise-hand';
  /// 表情反应：payload `{"emoji":"👍"}`。
  static const String reaction = 'uudesk/reaction';
  /// 会中屏幕共享控制（飞书式）：
  /// payload `{"a":"req|grant|revoke|release|input","to":"<identity>","ev":{...}}`，
  /// `ev` 为 §3.2 input 消息原文（归一化坐标），`to` 为被控/请求目标的 identity。
  static const String control = 'uudesk/control';
}

/// 聊天消息（含本端发送与远端接收）。
class ChatMessage {
  final String identity;
  final String name;
  final String text;
  final DateTime ts;
  final bool isSelf;

  ChatMessage({
    required this.identity,
    required this.name,
    required this.text,
    required this.ts,
    this.isSelf = false,
  });
}

/// 表情反应（短时展示，UI 按 ts 过滤）。
class MeetingReaction {
  final String identity;
  final String name;
  final String emoji;
  final DateTime ts;

  MeetingReaction({
    required this.identity,
    required this.name,
    required this.emoji,
    required this.ts,
  });
}

/// 成员宫格一格所需的快照（由 MeetingService 从 Room 派生）。
class MeetingMember {
  final String identity;
  final String name;
  final bool isSelf;
  final bool micOn;
  final bool camOn;
  final bool speaking;
  final bool handRaised;
  /// 摄像头视频轨道（可能为 null：未开摄像头/未订阅）。
  final VideoTrack? videoTrack;
  /// 屏幕共享视频轨道。
  final VideoTrack? shareTrack;

  const MeetingMember({
    required this.identity,
    required this.name,
    required this.isSelf,
    required this.micOn,
    required this.camOn,
    required this.speaking,
    required this.handRaised,
    this.videoTrack,
    this.shareTrack,
  });
}

// ===== §10.2 topic payload 编解码 =====

List<int> encodeChat(String text) => utf8.encode(text);

String decodeChat(List<int> data) => utf8.decode(data, allowMalformed: true);

List<int> encodeRaiseHand(bool raised) =>
    utf8.encode(jsonEncode({'raised': raised}));

bool decodeRaiseHand(List<int> data) {
  final j = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
  return j['raised'] == true;
}

List<int> encodeReaction(String emoji) =>
    utf8.encode(jsonEncode({'emoji': emoji}));

String decodeReaction(List<int> data) {
  final j = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
  return (j['emoji'] as String?) ?? '';
}

List<int> encodeControl(Map<String, dynamic> action) =>
    utf8.encode(jsonEncode(action));

/// 解码 `uudesk/control` payload，非法返回 null。
Map<String, dynamic>? decodeControl(List<int> data) {
  try {
    final j = jsonDecode(utf8.decode(data));
    return j is Map<String, dynamic> ? j : null;
  } catch (_) {
    return null;
  }
}
