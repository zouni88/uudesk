import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'frame_codec.dart';
import 'uu_transport.dart';

/// 内存回环传输：两端互通，供 UI 开发与无 native 库时降级。
class MockTransport extends UuTransport {
  final String name;
  MockTransport? _peer;
  int _nextConnId = 1;
  bool _connected = false;

  MockTransport({this.name = 'mock'});

  /// 创建一对互通的 mock 端（controller ↔ controlled）。
  static (MockTransport controller, MockTransport controlled) createPair({
    String controllerName = 'phone',
    String controlledName = 'pc',
  }) {
    final a = MockTransport(name: controllerName);
    final b = MockTransport(name: controlledName);
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  @override
  bool get isConnected => _connected;

  /// 模拟被控端收到一条入站连接（无 accept API，对应真实实现里
  /// uu-ffi 的 connected 事件）。
  void acceptMockConnection() {
    _connected = true;
    _peer?._connected = true;
    emitEvent(UuEvent('connected', {'conn_id': 1, 'peer': _peer?.name ?? 'pc'}));
    _peer?.emitEvent(UuEvent('connected', {'conn_id': 1, 'peer': name}));
  }

  @override
  Future<int> connect(String addr, {String? peerPin}) async {
    final peer = _peer;
    if (peer == null) throw StateError('MockTransport 未配对，无法 connect($addr)');
    final connId = _nextConnId++;
    _connected = true;
    peer._connected = true;
    // 模拟双向 connected 事件（附录 B event_json），两端共享同一 conn_id。
    emitEvent(UuEvent('connected', {'conn_id': connId, 'peer': peer.name}));
    await Future<void>.delayed(Duration.zero);
    peer._nextConnId = connId + 1;
    peer.emitEvent(UuEvent('connected', {'conn_id': connId, 'peer': name}));
    return connId;
  }

  @override
  void send(int connId, int channel, Uint8List bytes) {
    final peer = _peer;
    if (peer == null || !_connected) return;
    peer.emitData(UuDataFrame(channel: channel, connId: connId, data: bytes));
  }

  @override
  Future<void> close() async {
    _connected = false;
    emitEvent(UuEvent('disconnected', {'conn_id': 1}));
    _peer?._connected = false;
    _peer?.emitEvent(UuEvent('disconnected', {'conn_id': 1}));
  }

  /// 模拟对端（PC）：回 hello_ack / screen_meta，并周期性推送 mock 视频帧。
  MockPcSimulator attachPcSimulator() => MockPcSimulator(this);
}

/// 挂在 mock 被控端上的 PC 行为模拟器，让控制页 UI 有画面与响应。
class MockPcSimulator {
  final MockTransport pcSide;
  final Random _rng = Random();
  StreamSubscription<Map<String, dynamic>>? _sub;
  StreamSubscription<UuDataFrame>? _fileSub;
  Timer? _frameTimer;
  int _seq = 0;
  int _width = 1920;
  int _height = 1080;

  // 文件回环演示：接受 file_offer 后收集 chunk，回 file_done。
  final Map<int, BytesBuilder> _incoming = {};
  final Map<int, int> _expected = {};

  MockPcSimulator(this.pcSide) {
    _sub = pcSide.controlMessages.listen(_onControl);
    _fileSub = pcSide.fileFrames.listen(_onFileChunk);
  }

  void _onControl(Map<String, dynamic> msg) {
    final t = msg['t'];
    switch (t) {
      case 'hello':
        pcSide.sendControl(1, {'t': 'hello_ack', 'device_id': 'mock-pc', 'name': 'Mock PC'});
        break;
      case 'session_open':
        _sendScreenMeta();
        _startFrames();
        break;
      case 'session_close':
        _stop();
        break;
      case 'keyframe_req':
        _emitFrame(keyframe: true);
        break;
      case 'screen_cfg':
        _width = (msg['w'] as num?)?.toInt() ?? _width;
        _height = (msg['h'] as num?)?.toInt() ?? _height;
        pcSide.sendControl(1, {'t': 'screen_cfg_ack'});
        _sendScreenMeta();
        break;
      case 'clip_set':
        pcSide.sendControl(1, {'t': 'clip_ack', 'id': msg['id']});
        break;
      case 'file_offer':
        final id = (msg['id'] as num).toInt();
        _expected[id] = (msg['size'] as num?)?.toInt() ?? 0;
        _incoming[id] = BytesBuilder(copy: false);
        pcSide.sendControl(1, {'t': 'file_accept', 'id': id});
        break;
    }
  }

  void _onFileChunk(UuDataFrame f) {
    final chunk = FileChunk.decode(f.data);
    if (chunk == null) return;
    final buf = _incoming[chunk.id];
    if (buf == null) return;
    buf.add(chunk.data);
    if (buf.length >= (_expected[chunk.id] ?? 0)) {
      final sha = _simpleSha(buf.toBytes());
      pcSide.sendControl(1, {'t': 'file_done', 'id': chunk.id, 'sha256': sha});
      _incoming.remove(chunk.id);
      _expected.remove(chunk.id);
    }
  }

  /// 演示：PC 主动发来一个文件。
  void sendDemoFile({String name = 'demo_from_pc.bin', int size = 600 * 1024}) {
    final id = _rng.nextInt(0x7FFFFFFF) + 1;
    final data = Uint8List(size);
    for (var i = 0; i < size; i++) {
      data[i] = _rng.nextInt(256);
    }
    pcSide.sendControl(1, {
      't': 'file_offer', 'id': id, 'name': name, 'size': size,
    });
    // 手机 file_accept 后分块推送。
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = pcSide.controlMessages
        .where((m) => m['t'] == 'file_accept' && m['id'] == id)
        .listen((m) async {
      sub.cancel();
      for (var off = 0; off < size; off += FileChunk.chunkSize) {
        final end = (off + FileChunk.chunkSize) > size ? size : off + FileChunk.chunkSize;
        pcSide.sendFile(1, FileChunk(
          id: id, chunkIndex: off ~/ FileChunk.chunkSize,
          data: Uint8List.sublistView(data, off, end),
        ).encode());
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      pcSide.sendControl(1, {'t': 'file_done', 'id': id, 'sha256': _simpleSha(data)});
    });
  }

  static String _simpleSha(Uint8List data) {
    // 演示用摘要占位；正式校验见 FileTransferStore（crypto sha256）。
    var h = 0x811C9DC5;
    for (final b in data) {
      h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    return 'mock-${h.toRadixString(16)}';
  }

  void _sendScreenMeta() {
    pcSide.sendControl(1, {
      't': 'screen_meta', 'w': _width, 'h': _height,
      'scale': 1.0, 'rotation': 0, 'codec': 'h264',
    });
  }

  void _startFrames() {
    _frameTimer?.cancel();
    _frameTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _emitFrame(keyframe: _seq % 10 == 0);
    });
    _emitFrame(keyframe: true);
  }

  void _emitFrame({required bool keyframe}) {
    // mock 载荷不是真实 H.264，仅演示帧管线（解码服务会降级为占位渲染）。
    final nal = Uint8List.fromList(utf8.encode('mock-nal-${_rng.nextInt(1 << 20)}'));
    final frame = VideoFrame(
      flags: keyframe ? VideoFrame.flagKeyframe : 0,
      seq: _seq++,
      ptsUs: DateTime.now().microsecondsSinceEpoch,
      width: _width,
      height: _height,
      payload: nal,
    );
    pcSide.sendVideo(1, frame.encode());
  }

  void _stop() {
    _frameTimer?.cancel();
    _frameTimer = null;
  }

  void dispose() {
    _stop();
    _sub?.cancel();
    _fileSub?.cancel();
  }
}
