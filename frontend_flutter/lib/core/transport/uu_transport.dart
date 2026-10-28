import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// 通道编号，对应附录 B 的 UU_CH_*。
abstract final class UuChannel {
  static const int control = 0;
  static const int video = 1;
  static const int audio = 2;
  static const int file = 3;
}

/// 某通道上收到的一帧原始数据。
class UuDataFrame {
  final int channel;
  final int connId;
  final Uint8List data;

  const UuDataFrame({required this.channel, required this.connId, required this.data});

  @override
  String toString() => 'UuDataFrame(ch=$channel, conn=$connId, ${data.length}B)';
}

/// 连接事件（附录 B event_json）：connected / disconnected / error。
class UuEvent {
  final String type;
  final Map<String, dynamic> payload;

  UuEvent(this.type, this.payload);

  int? get connId => payload['conn_id'] as int?;
  String? get message => (payload['msg'] ?? payload['message']) as String?;

  @override
  String toString() => 'UuEvent($type, $payload)';
}

/// 传输抽象层：QUIC 连接、控制/视频/文件收发与事件流。
///
/// 实现：
/// - [UuFfiTransport]：dart:ffi 绑定 Rust uu-ffi 动态库（生产路径）。
/// - [MockTransport]：内存回环，UI 开发与无 native 库时降级。
abstract class UuTransport {
  final StreamController<UuDataFrame> _dataCtrl = StreamController<UuDataFrame>.broadcast();
  final StreamController<UuEvent> _eventCtrl = StreamController<UuEvent>.broadcast();
  bool _disposed = false;

  /// 所有通道的原始数据流。
  Stream<UuDataFrame> get data => _dataCtrl.stream;

  /// 连接事件流。
  Stream<UuEvent> get events => _eventCtrl.stream;

  /// 便捷流：控制通道 JSON 消息（§3）。
  Stream<Map<String, dynamic>> get controlMessages => _dataCtrl.stream
      .where((f) => f.channel == UuChannel.control)
      .map((f) => jsonDecode(utf8.decode(f.data)) as Map<String, dynamic>);

  /// 便捷流：视频通道帧字节（§4）。
  Stream<UuDataFrame> get videoFrames =>
      _dataCtrl.stream.where((f) => f.channel == UuChannel.video);

  /// 便捷流：文件通道 chunk 字节（§7）。
  Stream<UuDataFrame> get fileFrames =>
      _dataCtrl.stream.where((f) => f.channel == UuChannel.file);

  bool get isConnected;

  /// 作为控制端向 [addr]（host:port）发起 QUIC 连接，返回 conn_id。
  /// [peerPin] 为被控端 device_id（SPKI pin，§1）。
  Future<int> connect(String addr, {String? peerPin});

  /// 底层发送：control 为裸 JSON 字节（长度前缀由 Rust 侧处理），
  /// video/audio/file 为含帧头的完整帧字节。
  void send(int connId, int channel, Uint8List bytes);

  /// 发送 §3 控制消息。
  void sendControl(int connId, Map<String, dynamic> message) {
    send(connId, UuChannel.control, Uint8List.fromList(utf8.encode(jsonEncode(message))));
  }

  /// 发送 §4 视频整帧（含帧头）。
  void sendVideo(int connId, Uint8List frameBytes) =>
      send(connId, UuChannel.video, frameBytes);

  /// 发送 §7 文件 chunk（含 chunk 头）。
  void sendFile(int connId, Uint8List chunkBytes) =>
      send(connId, UuChannel.file, chunkBytes);

  /// 关闭全部连接并释放资源。
  Future<void> close();

  /// 子类收到数据时调用。
  void emitData(UuDataFrame frame) {
    if (!_disposed && !_dataCtrl.isClosed) _dataCtrl.add(frame);
  }

  /// 子类产生事件时调用。
  void emitEvent(UuEvent event) {
    if (!_disposed && !_eventCtrl.isClosed) _eventCtrl.add(event);
  }

  void dispose() {
    _disposed = true;
    _dataCtrl.close();
    _eventCtrl.close();
  }
}
