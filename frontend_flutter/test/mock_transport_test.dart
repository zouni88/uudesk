import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uu_desk/core/protocol/control_messages.dart';
import 'package:uu_desk/core/transport/frame_codec.dart';
import 'package:uu_desk/core/transport/mock_transport.dart';
import 'package:uu_desk/core/transport/uu_transport.dart';

void main() {
  group('MockTransport 回环', () {
    test('connect 后双向 connected 事件、conn_id 一致', () async {
      final (phone, pc) = MockTransport.createPair();
      final phoneEvents = <UuEvent>[];
      final pcEvents = <UuEvent>[];
      phone.events.listen(phoneEvents.add);
      pc.events.listen(pcEvents.add);

      final connId = await phone.connect('mock://pc', peerPin: 'pin123');
      await Future<void>.delayed(Duration.zero); // 等 broadcast 事件派发
      expect(connId, 1);
      expect(phone.isConnected, isTrue);
      expect(pc.isConnected, isTrue);

      final connected = phoneEvents.where((e) => e.type == 'connected').toList();
      expect(connected, hasLength(1));
      expect(connected.first.connId, connId);
      expect(pcEvents.any((e) => e.type == 'connected' && e.connId == connId),
          isTrue);

      await phone.close();
      await Future<void>.delayed(Duration.zero);
      expect(phoneEvents.any((e) => e.type == 'disconnected'), isTrue);
      expect(pcEvents.any((e) => e.type == 'disconnected'), isTrue);
      expect(phone.isConnected, isFalse);
    });

    test('send 原始字节互通且保留通道号', () async {
      final (a, b) = MockTransport.createPair();
      await a.connect('mock://x');
      final received = <UuDataFrame>[];
      b.data.listen(received.add);

      a.send(1, UuChannel.video, Uint8List.fromList([1, 2, 3]));
      a.send(1, UuChannel.file, Uint8List.fromList([4, 5]));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(2));
      expect(received[0].channel, UuChannel.video);
      expect(received[0].data, [1, 2, 3]);
      expect(received[1].channel, UuChannel.file);
    });

    test('sendControl 经 controlMessages 还原 JSON（§3）', () async {
      final (phone, pc) = MockTransport.createPair();
      final connId = await phone.connect('mock://pc');
      final incoming = pc.controlMessages.first;

      phone.sendControl(connId, UuMsg.hello('phone', 'dev-1', 'Pixel'));
      final msg = await incoming.timeout(const Duration(seconds: 1));
      expect(msg['t'], 'hello');
      expect(msg['role'], 'phone');
      expect(msg['device_id'], 'dev-1');
      expect(msg['name'], 'Pixel');
      expect(msg['proto'], 1);
    });

    test('acceptMockConnection 模拟被控端入站连接', () async {
      final (phone, pc) = MockTransport.createPair();
      final pcEvents = <UuEvent>[];
      pc.events.listen(pcEvents.add);
      phone.acceptMockConnection();
      await Future<void>.delayed(Duration.zero);
      expect(pc.isConnected, isTrue);
      expect(pcEvents.any((e) => e.type == 'connected'), isTrue);
    });
  });

  group('MockPcSimulator（PC 行为模拟）', () {
    late MockTransport phone;
    late MockPcSimulator sim;
    late int connId;

    setUp(() async {
      final (p, pc) = MockTransport.createPair();
      phone = p;
      sim = pc.attachPcSimulator();
      connId = await phone.connect('mock://pc');
    });

    tearDown(() => sim.dispose());

    test('hello → hello_ack', () async {
      final ack = phone.controlMessages
          .firstWhere((m) => m['t'] == 'hello_ack')
          .timeout(const Duration(seconds: 1));
      phone.sendControl(connId, UuMsg.hello('phone', 'dev-1', 'Pixel'));
      final msg = await ack;
      expect(msg['device_id'], 'mock-pc');
      expect(msg['name'], 'Mock PC');
    });

    test('session_open → screen_meta + 可解码视频帧（§4）', () async {
      final meta = phone.controlMessages
          .firstWhere((m) => m['t'] == 'screen_meta')
          .timeout(const Duration(seconds: 1));
      final video = phone.videoFrames.first
          .timeout(const Duration(seconds: 2));

      phone.sendControl(connId, UuMsg.sessionOpen('view_pc', ['input']));

      final m = await meta;
      expect(m['w'], 1920);
      expect(m['h'], 1080);
      expect(m['codec'], 'h264');

      final frame = VideoFrame.decode((await video).data);
      expect(frame, isNotNull);
      expect(frame!.isKeyframe, isTrue);
      expect(frame.width, 1920);
      expect(frame.height, 1080);
    });

    test('file_offer → file_accept → chunk → file_done（§7 回环）', () async {
      final data = Uint8List.fromList([10, 20, 30]);
      final accept = phone.controlMessages
          .firstWhere((m) => m['t'] == 'file_accept' && m['id'] == 7)
          .timeout(const Duration(seconds: 1));

      phone.sendControl(connId, UuMsg.fileOffer(7, 'a.bin', data.length));
      await accept;

      phone.sendFile(
          connId, FileChunk(id: 7, chunkIndex: 0, data: data).encode());
      final done = await phone.controlMessages
          .firstWhere((m) => m['t'] == 'file_done' && m['id'] == 7)
          .timeout(const Duration(seconds: 1));
      expect(done['sha256'], isA<String>());
    });

    test('keyframe_req → 立即下发关键帧', () async {
      final video = phone.videoFrames
          .map((f) => VideoFrame.decode(f.data))
          .firstWhere((fr) => fr != null && fr.isKeyframe)
          .timeout(const Duration(seconds: 2));
      phone.sendControl(connId, UuMsg.keyframeReq());
      expect((await video)!.isKeyframe, isTrue);
    });
  });
}
