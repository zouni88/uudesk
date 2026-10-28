import 'dart:typed_data';

/// UUDesk 二进制帧编解码（大端 ByteData）。
/// - §4 视频帧头：magic u16=0x5556, flags u8(bit0=keyframe), codec u8(0=H264 AnnexB),
///   seq u32, pts_us u64, w u16, h u16, len u32, payload=NAL 数据。
/// - §7 文件 chunk：magic u16=0x5546, id u32, chunk_index u32, chunk_len u32, 随后原始字节。

/// §4 视频帧。
class VideoFrame {
  static const int magic = 0x5556; // "UV"
  static const int headerSize = 24;
  static const int flagKeyframe = 0x01;
  static const int codecH264AnnexB = 0;

  final int flags;
  final int codec;
  final int seq;
  final int ptsUs;
  final int width;
  final int height;
  final Uint8List payload;

  const VideoFrame({
    this.flags = 0,
    this.codec = codecH264AnnexB,
    required this.seq,
    required this.ptsUs,
    required this.width,
    required this.height,
    required this.payload,
  });

  bool get isKeyframe => (flags & flagKeyframe) != 0;

  /// 编码为整帧字节（含帧头），可直接经 video 通道发送。
  Uint8List encode() {
    final out = Uint8List(headerSize + payload.length);
    final bd = ByteData.view(out.buffer);
    bd.setUint16(0, magic, Endian.big);
    bd.setUint8(2, flags);
    bd.setUint8(3, codec);
    bd.setUint32(4, seq & 0xFFFFFFFF, Endian.big);
    bd.setUint64(8, ptsUs, Endian.big);
    bd.setUint16(16, width & 0xFFFF, Endian.big);
    bd.setUint16(18, height & 0xFFFF, Endian.big);
    bd.setUint32(20, payload.length, Endian.big);
    out.setRange(headerSize, out.length, payload);
    return out;
  }

  /// 从字节解码；magic 不符或数据不完整返回 null。
  static VideoFrame? decode(Uint8List bytes) {
    if (bytes.length < headerSize) return null;
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    if (bd.getUint16(0, Endian.big) != magic) return null;
    final len = bd.getUint32(20, Endian.big);
    if (bytes.length < headerSize + len) return null;
    return VideoFrame(
      flags: bd.getUint8(2),
      codec: bd.getUint8(3),
      seq: bd.getUint32(4, Endian.big),
      ptsUs: bd.getUint64(8, Endian.big),
      width: bd.getUint16(16, Endian.big),
      height: bd.getUint16(18, Endian.big),
      payload: Uint8List.sublistView(bytes, headerSize, headerSize + len),
    );
  }

  @override
  String toString() =>
      'VideoFrame(seq=$seq, pts=$ptsUs, ${width}x$height, key=$isKeyframe, nal=${payload.length}B)';
}

/// §7 文件流 chunk。
class FileChunk {
  static const int magic = 0x5546; // "UF"
  static const int headerSize = 14;
  static const int chunkSize = 256 * 1024;

  final int id;
  final int chunkIndex;
  final Uint8List data;

  const FileChunk({
    required this.id,
    required this.chunkIndex,
    required this.data,
  });

  int get chunkLen => data.length;

  /// 编码为 chunk 字节（含 14 字节头），经 file 通道发送。
  Uint8List encode() {
    final out = Uint8List(headerSize + data.length);
    final bd = ByteData.view(out.buffer);
    bd.setUint16(0, magic, Endian.big);
    bd.setUint32(2, id & 0xFFFFFFFF, Endian.big);
    bd.setUint32(6, chunkIndex & 0xFFFFFFFF, Endian.big);
    bd.setUint32(10, data.length, Endian.big);
    out.setRange(headerSize, out.length, data);
    return out;
  }

  /// 从字节解码；magic 不符或数据不完整返回 null。
  static FileChunk? decode(Uint8List bytes) {
    if (bytes.length < headerSize) return null;
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    if (bd.getUint16(0, Endian.big) != magic) return null;
    final len = bd.getUint32(10, Endian.big);
    if (bytes.length < headerSize + len) return null;
    return FileChunk(
      id: bd.getUint32(2, Endian.big),
      chunkIndex: bd.getUint32(6, Endian.big),
      data: Uint8List.sublistView(bytes, headerSize, headerSize + len),
    );
  }
}
