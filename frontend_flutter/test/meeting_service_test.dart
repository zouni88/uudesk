import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uu_desk/core/meeting/meeting_models.dart';
import 'package:uu_desk/core/meeting/meeting_service.dart';

/// 记录调用的假会议 API（不连真实信令/LiveKit）。
class FakeMeetingApi implements MeetingApi {
  final Map<String, dynamic>? tokenResponse;
  Object? tokenError;

  final List<({String room, String identity, bool canPublish})> tokenCalls = [];
  final List<String> egressStartCalls = [];
  final List<String> egressStopCalls = [];

  FakeMeetingApi({this.tokenResponse});

  @override
  Future<Map<String, dynamic>> meetingToken({
    required String room,
    required String identity,
    bool canPublish = true,
  }) async {
    tokenCalls.add((room: room, identity: identity, canPublish: canPublish));
    if (tokenError != null) throw tokenError!;
    return tokenResponse ?? const {'token': 'tk-1', 'server_url': 'wss://lk.example.com/r'};
  }

  @override
  Future<Map<String, dynamic>> startEgress(String room) async {
    egressStartCalls.add(room);
    return const {};
  }

  @override
  Future<Map<String, dynamic>> stopEgress(String room) async {
    egressStopCalls.add(room);
    return const {};
  }
}

MeetingService serviceWith(FakeMeetingApi api) =>
    MeetingService(apiFor: (_) => api);

void main() {
  group('令牌获取（§10.1）', () {
    test('requestToken 透传 room/identity/can_publish 并解析响应', () async {
      final api = FakeMeetingApi();
      final svc = serviceWith(api);
      final info = await svc.requestToken(
        serverUrl: 'https://signal.example.com',
        room: 'room-42',
        identity: 'dev-abc',
        canPublish: false,
      );
      expect(api.tokenCalls, hasLength(1));
      expect(api.tokenCalls.single.room, 'room-42');
      expect(api.tokenCalls.single.identity, 'dev-abc');
      expect(api.tokenCalls.single.canPublish, false);
      expect(info.token, 'tk-1');
      expect(info.serverUrl, 'wss://lk.example.com/r');
    });

    test('响应缺 token 抛 MeetingException', () async {
      final api = FakeMeetingApi(tokenResponse: const {'server_url': 'wss://x'});
      final svc = serviceWith(api);
      expect(
        () => svc.requestToken(
            serverUrl: 'https://s', room: 'r', identity: 'i'),
        throwsA(isA<MeetingException>()),
      );
    });

    test('响应缺 server_url 抛 MeetingException', () async {
      final api = FakeMeetingApi(tokenResponse: const {'token': 'tk'});
      final svc = serviceWith(api);
      expect(
        () => svc.requestToken(
            serverUrl: 'https://s', room: 'r', identity: 'i'),
        throwsA(isA<MeetingException>()),
      );
    });
  });

  group('topic payload 编解码（§10.2）', () {
    test('chat 纯文本 utf8 往返（含中文 emoji）', () {
      const text = '你好，World 👋🎉';
      expect(decodeChat(encodeChat(text)), text);
    });

    test('raiseHand bool 往返', () {
      expect(decodeRaiseHand(encodeRaiseHand(true)), true);
      expect(decodeRaiseHand(encodeRaiseHand(false)), false);
    });

    test('reaction emoji 往返', () {
      expect(decodeReaction(encodeReaction('👍')), '👍');
    });

    test('raiseHand payload 为 JSON {"raised":bool}', () {
      final j = jsonDecode(utf8.decode(encodeRaiseHand(true)));
      expect(j, {'raised': true});
    });

    test('reaction payload 为 JSON {"emoji":str}', () {
      final j = jsonDecode(utf8.decode(encodeReaction('👏')));
      expect(j, {'emoji': '👏'});
    });

    test('chat topic 常量为 LiveKit 标准 lk.chat', () {
      expect(MeetingTopics.chat, 'lk.chat');
      expect(MeetingTopics.raiseHand, 'uudesk/raise-hand');
      expect(MeetingTopics.reaction, 'uudesk/reaction');
    });
  });

  group('ingestData 状态流（不依赖 Room）', () {
    test('聊天消息入列并计未读，名字空时回退 identity', () {
      final svc = serviceWith(FakeMeetingApi());
      svc.ingestData(
        topic: MeetingTopics.chat,
        data: encodeChat('会议开始'),
        fromIdentity: 'peer-1',
      );
      svc.ingestData(
        topic: MeetingTopics.chat,
        data: encodeChat('hi'),
        fromIdentity: 'peer-2',
        fromName: '张三',
      );
      expect(svc.chats, hasLength(2));
      expect(svc.chats[0].name, 'peer-1');
      expect(svc.chats[1].name, '张三');
      expect(svc.chats[1].text, 'hi');
      expect(svc.unreadChat, 2);
      svc.markChatRead();
      expect(svc.unreadChat, 0);
    });

    test('举手置位与放下', () {
      final svc = serviceWith(FakeMeetingApi());
      svc.ingestData(
        topic: MeetingTopics.raiseHand,
        data: encodeRaiseHand(true),
        fromIdentity: 'peer-1',
      );
      expect(svc.raisedHands, contains('peer-1'));
      svc.ingestData(
        topic: MeetingTopics.raiseHand,
        data: encodeRaiseHand(false),
        fromIdentity: 'peer-1',
      );
      expect(svc.raisedHands, isNot(contains('peer-1')));
    });

    test('反应入列', () {
      final svc = serviceWith(FakeMeetingApi());
      svc.ingestData(
        topic: MeetingTopics.reaction,
        data: encodeReaction('🎉'),
        fromIdentity: 'peer-9',
        fromName: '李四',
      );
      expect(svc.reactions, hasLength(1));
      expect(svc.reactions.single.emoji, '🎉');
      expect(svc.reactions.single.name, '李四');
    });

    test('非法 payload 忽略不抛异常', () {
      final svc = serviceWith(FakeMeetingApi());
      expect(
        () => svc.ingestData(
          topic: MeetingTopics.raiseHand,
          data: utf8.encode('not-json'),
          fromIdentity: 'x',
        ),
        returnsNormally,
      );
      expect(svc.raisedHands, isEmpty);
    });

    test('未知 topic 忽略', () {
      final svc = serviceWith(FakeMeetingApi());
      svc.ingestData(
          topic: 'some/other', data: utf8.encode('{}'), fromIdentity: 'x');
      expect(svc.chats, isEmpty);
      expect(svc.reactions, isEmpty);
      expect(svc.unreadChat, 0);
    });

    test('本端举手（无 Room 仅本地状态）', () async {
      final svc = serviceWith(FakeMeetingApi());
      svc.selfIdentity = 'me';
      await svc.setHandRaised(true);
      expect(svc.selfHandRaised, true);
      expect(svc.raisedHands, contains('me'));
      await svc.setHandRaised(false);
      expect(svc.selfHandRaised, false);
    });
  });

  group('录制 API（§10.2）', () {
    test('start/stopRecording 调用 egress 端点并乐观置位', () async {
      final api = FakeMeetingApi();
      final svc = serviceWith(api);
      svc.roomName = 'room-7';
      await svc.startRecording();
      expect(svc.recording, true);
      expect(api.egressStartCalls, ['room-7']);
      await svc.stopRecording();
      expect(svc.recording, false);
      expect(api.egressStopCalls, ['room-7']);
    });
  });
}
