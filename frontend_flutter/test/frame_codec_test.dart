import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uu_desk/core/transport/frame_codec.dart';

void main() {
  group('VideoFrame §4 帧头', () {
    test('encode/decode 往返一致', () {
      final payload = Uint8List.fromList(List.generate(64, (i) => i));
      final frame = VideoFrame(
        flags: VideoFrame.flagKeyframe,
        seq: 0xDEADBEEF,
        ptsUs: 0x0102030405060708,
        width: 1920,
        height: 1080,
        payload: payload,
      );
      final decoded = VideoFrame.decode(frame.encode());
      expect(decoded, isNotNull);
      expect(decoded!.isKeyframe, isTrue);
      expect(decoded.codec, VideoFrame.codecH264AnnexB);
      expect(decoded.seq, 0xDEADBEEF);
      expect(decoded.ptsUs, 0x0102030405060708);
      expect(decoded.width, 1920);
      expect(decoded.height, 1080);
      expect(decoded.payload, payload);
    });

    test('头部为大端字节序', () {
      final frame = VideoFrame(
        seq: 0x01020304,
        ptsUs: 0x0807060504030201,
        width: 0x1122,
        height: 0x3344,
        payload: Uint8List.fromList([0xAA]),
      );
      final bytes = frame.encode();
      final bd = ByteData.view(bytes.buffer);
      expect(bd.getUint16(0, Endian.big), 0x5556); // "UV"
      expect(bytes[2], 0); // flags
      expect(bytes[3], 0); // codec
      expect(bytes.sublist(4, 8), [0x01, 0x02, 0x03, 0x04]); // seq u32 BE
      expect(bytes.sublist(8, 16),
          [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]); // pts u64 BE
      expect(bytes.sublist(16, 18), [0x11, 0x22]); // w
      expect(bytes.sublist(18, 20), [0x33, 0x44]); // h
      expect(bd.getUint32(20, Endian.big), 1); // payload len
      expect(bytes.length, VideoFrame.headerSize + 1);
    });

    test('keyframe 位仅在 flags bit0', () {
      final p = Uint8List.fromList([1]);
      final nonKey = VideoFrame(
              seq: 1, ptsUs: 1, width: 8, height: 8, payload: p)
          .encode();
      final key = VideoFrame(
              flags: VideoFrame.flagKeyframe,
              seq: 1,
              ptsUs: 1,
              width: 8,
              height: 8,
              payload: p)
          .encode();
      expect(VideoFrame.decode(nonKey)!.isKeyframe, isFalse);
      expect(VideoFrame.decode(key)!.isKeyframe, isTrue);
      // 其它 flags 位不影响 keyframe 判定
      final other = VideoFrame(
              flags: 0x02, seq: 1, ptsUs: 1, width: 8, height: 8, payload: p)
          .encode();
      expect(VideoFrame.decode(other)!.isKeyframe, isFalse);
    });

    test('magic 不符返回 null', () {
      final bytes = VideoFrame(
              seq: 0, ptsUs: 0, width: 0, height: 0, payload: Uint8List(0))
          .encode();
      bytes[0] = 0x55;
      bytes[1] = 0x99;
      expect(VideoFrame.decode(bytes), isNull);
    });

    test('截断（不足帧头 / payload 不完整）返回 null', () {
      final bytes = VideoFrame(
              seq: 0,
              ptsUs: 0,
              width: 0,
              height: 0,
              payload: Uint8List(16))
          .encode();
      expect(VideoFrame.decode(Uint8List.sublistView(bytes, 0, 10)), isNull);
      expect(
          VideoFrame.decode(Uint8List.sublistView(bytes, 0, bytes.length - 1)),
          isNull);
    });
  });

  group('FileChunk §7 chunk 头', () {
    test('encode/decode 往返一致', () {
      final data = Uint8List.fromList(List.generate(1000, (i) => i & 0xFF));
      final chunk = FileChunk(id: 42, chunkIndex: 7, data: data);
      final decoded = FileChunk.decode(chunk.encode());
      expect(decoded, isNotNull);
      expect(decoded!.id, 42);
      expect(decoded.chunkIndex, 7);
      expect(decoded.chunkLen, 1000);
      expect(decoded.data, data);
    });

    test('头部为大端字节序', () {
      final bytes = FileChunk(
              id: 0x01020304, chunkIndex: 0x05060708, data: Uint8List.fromList([9]))
          .encode();
      expect(bytes.sublist(0, 2), [0x55, 0x46]); // "UF"
      expect(bytes.sublist(2, 6), [0x01, 0x02, 0x03, 0x04]); // id BE
      expect(bytes.sublist(6, 10), [0x05, 0x06, 0x07, 0x08]); // index BE
      expect(bytes.sublist(10, 14), [0, 0, 0, 1]); // len BE
      expect(bytes.length, FileChunk.headerSize + 1);
    });

    test('magic 不符 / 截断返回 null', () {
      final bytes = FileChunk(id: 1, chunkIndex: 0, data: Uint8List(8)).encode();
      bytes[1] = 0x00;
      expect(FileChunk.decode(bytes), isNull);
      final good = FileChunk(id: 1, chunkIndex: 0, data: Uint8List(8)).encode();
      expect(FileChunk.decode(Uint8List.sublistView(good, 0, 5)), isNull);
      expect(
          FileChunk.decode(Uint8List.sublistView(good, 0, good.length - 1)),
          isNull);
    });
  });
}
