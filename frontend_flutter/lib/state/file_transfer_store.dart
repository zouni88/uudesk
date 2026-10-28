import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/protocol/control_messages.dart';
import '../core/transport/frame_codec.dart';
import '../core/transport/uu_transport.dart';

enum TransferDirection { outgoing, incoming }
enum TransferState { offering, waitingAccept, running, done, rejected, failed }

class TransferTask {
  final int id;
  final TransferDirection direction;
  final String name;
  final int size;
  String? savePath;
  int transferred = 0;
  TransferState state;

  TransferTask({
    required this.id,
    required this.direction,
    required this.name,
    required this.size,
    this.state = TransferState.offering,
    this.savePath,
  });

  double get progress => size == 0 ? 0 : (transferred / size).clamp(0.0, 1.0);
}

/// §3.6/§7 文件双向传输：file_offer/accept 走控制流，
/// chunk 走文件通道（FileChunk 帧），完成后校验 sha256。
class FileTransferStore extends ChangeNotifier {
  UuTransport? _transport;
  int? _connId;
  final Random _rng = Random();
  final List<TransferTask> tasks = [];

  final Map<int, File> _outFiles = {}; // 出站：等待 file_accept
  final Map<int, TransferTask> _pendingIncoming = {}; // 入站：等待用户决定
  final Map<int, _IncomingWriter> _writers = {}; // 入站：正在写盘

  void bind(UuTransport t, {int connId = 1}) {
    _transport = t;
    _connId = connId;
    t.controlMessages.listen(_onControl);
    t.fileFrames.listen(_onChunk);
  }

  void unbind() {
    _transport = null;
    _connId = null;
    for (final w in _writers.values) {
      w.close();
    }
    _writers.clear();
    _outFiles.clear();
    _pendingIncoming.clear();
  }

  /// 发起文件发送（§3.6 file_offer）。
  Future<void> offerFile(File file) async {
    final t = _transport;
    final c = _connId;
    if (t == null || c == null) return;
    final id = _rng.nextInt(0x7FFFFFFF) + 1;
    final task = TransferTask(
      id: id,
      direction: TransferDirection.outgoing,
      name: file.uri.pathSegments.last,
      size: await file.length(),
      state: TransferState.offering,
    );
    tasks.add(task);
    _outFiles[id] = file;
    notifyListeners();
    t.sendControl(c, UuMsg.fileOffer(id, task.name, task.size));
  }

  /// 用户接受入站文件。
  Future<void> acceptIncoming(int id) async {
    final task = _pendingIncoming.remove(id);
    final t = _transport;
    final c = _connId;
    if (task == null || t == null || c == null) return;
    task.state = TransferState.running;
    final dir = await getApplicationDocumentsDirectory();
    final saveFile = File('${dir.path}/uudesk_in/${task.name}');
    await saveFile.parent.create(recursive: true);
    task.savePath = saveFile.path;
    _writers[id] = _IncomingWriter(saveFile);
    t.sendControl(c, UuMsg.fileAccept(id));
    notifyListeners();
  }

  void rejectIncoming(int id) {
    final task = _pendingIncoming.remove(id);
    if (task == null) return;
    task.state = TransferState.rejected;
    _transport?.sendControl(_connId ?? 0, UuMsg.fileReject(id));
    notifyListeners();
  }

  void _onControl(Map<String, dynamic> msg) {
    final c = _connId;
    final t = _transport;
    if (t == null || c == null) return;
    final id = (msg['id'] as num?)?.toInt();
    switch (msg['t']) {
      case 'file_offer':
        if (id == null) return;
        final task = TransferTask(
          id: id,
          direction: TransferDirection.incoming,
          name: msg['name'] as String? ?? 'file',
          size: (msg['size'] as num?)?.toInt() ?? 0,
          state: TransferState.waitingAccept,
        );
        tasks.add(task);
        _pendingIncoming[id] = task;
        notifyListeners();
        break;
      case 'file_accept':
        final task = _taskById(id!, TransferDirection.outgoing);
        final file = _outFiles.remove(id);
        if (task == null || file == null) return;
        task.state = TransferState.running;
        notifyListeners();
        unawaited(_sendFile(task, file));
        break;
      case 'file_reject':
        final task = _taskById(id!, TransferDirection.outgoing);
        if (task != null) {
          task.state = TransferState.rejected;
          notifyListeners();
        }
        break;
      case 'file_done':
        final task = _taskById(id!, TransferDirection.incoming);
        if (task == null) return;
        final writer = _writers.remove(id);
        final localSha = writer?.finish();
        final remote = msg['sha256'] as String? ?? '';
        task.state = (remote.isEmpty || localSha == null || remote == localSha)
            ? TransferState.done
            : TransferState.failed;
        notifyListeners();
        break;
    }
  }

  TransferTask? _taskById(int id, TransferDirection dir) =>
      tasks.where((e) => e.id == id && e.direction == dir).firstOrNull;

  Future<void> _sendFile(TransferTask task, File file) async {
    final raf = await file.open();
    try {
      Digest? digest;
      final sink = ChunkedConversionSink<Digest>.withCallback((ds) => digest = ds.single);
      final shaInput = sha256.startChunkedConversion(sink);
      final buf = Uint8List(FileChunk.chunkSize);
      var index = 0;
      var offset = 0;
      while (offset < task.size) {
        final n = await raf.readInto(buf, 0, min(FileChunk.chunkSize, task.size - offset));
        if (n <= 0) break;
        final part = Uint8List.sublistView(buf, 0, n);
        shaInput.add(part);
        _transport?.sendFile(_connId ?? 0, FileChunk(id: task.id, chunkIndex: index, data: part).encode());
        offset += n;
        index++;
        task.transferred = offset;
        notifyListeners();
        await Future<void>.delayed(Duration.zero); // 让出 UI 线程
      }
      shaInput.close();
      _transport?.sendControl(_connId ?? 0, UuMsg.fileDone(task.id, digest?.toString() ?? ''));
      task.state = TransferState.done;
    } catch (e) {
      debugPrint('file send failed: $e');
      task.state = TransferState.failed;
    } finally {
      await raf.close();
      notifyListeners();
    }
  }

  void _onChunk(UuDataFrame f) {
    final chunk = FileChunk.decode(f.data);
    if (chunk == null) return;
    final writer = _writers[chunk.id];
    final task = _taskById(chunk.id, TransferDirection.incoming);
    if (writer == null || task == null) return;
    writer.add(chunk.data);
    task.transferred += chunk.data.length;
    notifyListeners();
  }
}

class _IncomingWriter {
  final File file;
  late final RandomAccessFile _raf;
  final DigestSink _digestSink = DigestSink();
  late final Sink<List<int>> _shaInput;

  _IncomingWriter(this.file) {
    _raf = file.openSync(mode: FileMode.write);
    _shaInput = sha256.startChunkedConversion(_digestSink);
  }

  void add(Uint8List bytes) {
    _raf.writeFromSync(bytes);
    _shaInput.add(bytes);
  }

  String finish() {
    _shaInput.close();
    _raf.closeSync();
    return _digestSink.value?.toString() ?? '';
  }

  void close() {
    try {
      _raf.closeSync();
    } catch (_) {}
  }
}

class DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
