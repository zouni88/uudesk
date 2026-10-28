import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'uu_transport.dart';

// ===== 附录 B：uu-ffi C ABI 绑定 =====

// typedef void (*uu_data_cb)(void* ctx, uint8_t channel, uint64_t conn_id,
//                            const uint8_t* data, uint32_t len);
typedef UUDataCbNative = Void Function(Pointer<Void> ctx, Uint8 channel, Uint64 connId,
    Pointer<Uint8> data, Uint32 len);
typedef UUDataCbDart = void Function(Pointer<Void> ctx, int channel, int connId,
    Pointer<Uint8> data, int len);

// typedef void (*uu_event_cb)(void* ctx, const char* event_json);
typedef UUEventCbNative = Void Function(Pointer<Void> ctx, Pointer<Utf8> eventJson);
typedef UUEventCbDart = void Function(Pointer<Void> ctx, Pointer<Utf8> eventJson);

// void* uu_ffi_new(const char* config_json);
typedef _NewNative = Pointer<Void> Function(Pointer<Utf8> configJson);
typedef _NewDart = Pointer<Void> Function(Pointer<Utf8> configJson);

// int32_t uu_ffi_start(void* h);
typedef _StartNative = Int32 Function(Pointer<Void> h);
typedef _StartDart = int Function(Pointer<Void> h);

// uint64_t uu_ffi_connect(void* h, const char* addr, const char* peer_pin_b32);
typedef _ConnectNative = Uint64 Function(Pointer<Void> h, Pointer<Utf8> addr, Pointer<Utf8> peerPin);
typedef _ConnectDart = int Function(Pointer<Void> h, Pointer<Utf8> addr, Pointer<Utf8> peerPin);

// int32_t uu_ffi_send(void* h, uint64_t conn_id, uint8_t channel,
//                     const uint8_t* data, uint32_t len);
typedef _SendNative = Int32 Function(Pointer<Void> h, Uint64 connId, Uint8 channel,
    Pointer<Uint8> data, Uint32 len);
typedef _SendDart = int Function(Pointer<Void> h, int connId, int channel,
    Pointer<Uint8> data, int len);

// void uu_ffi_set_callbacks(void* h, uu_data_cb on_data, uu_event_cb on_event, void* ctx);
typedef _SetCallbacksNative = Void Function(Pointer<Void> h,
    Pointer<NativeFunction<UUDataCbNative>> onData,
    Pointer<NativeFunction<UUEventCbNative>> onEvent, Pointer<Void> ctx);
typedef _SetCallbacksDart = void Function(Pointer<Void> h,
    Pointer<NativeFunction<UUDataCbNative>> onData,
    Pointer<NativeFunction<UUEventCbNative>> onEvent, Pointer<Void> ctx);

// void uu_ffi_close(void* h, uint64_t conn_id);
typedef _CloseNative = Void Function(Pointer<Void> h, Uint64 connId);
typedef _CloseDart = void Function(Pointer<Void> h, int connId);

// void uu_ffi_free(void* h);
typedef _FreeNative = Void Function(Pointer<Void> h);
typedef _FreeDart = void Function(Pointer<Void> h);

// const char* uu_ffi_last_error(void* h);
typedef _LastErrorNative = Pointer<Utf8> Function(Pointer<Void> h);
typedef _LastErrorDart = Pointer<Utf8> Function(Pointer<Void> h);

/// 默认库加载：Android 打开 `libuu_ffi.so`（cargo-ndk 产物放入 jniLibs），
/// 其余平台按常规命名尝试；测试/桌面可经 [library] 参数注入。
DynamicLibrary defaultUuFfiLibrary() {
  if (Platform.isAndroid) return DynamicLibrary.open('libuu_ffi.so');
  if (Platform.isWindows) return DynamicLibrary.open('uu_ffi.dll');
  if (Platform.isMacOS || Platform.isIOS) return DynamicLibrary.open('uu_ffi.framework/uu_ffi');
  return DynamicLibrary.open('libuu_ffi.so');
}

/// dart:ffi 实现，绑定 Rust `uu-ffi` 动态库（附录 B 契约）。
class UuFfiTransport extends UuTransport {
  final DynamicLibrary _lib;
  late final Pointer<Void> _handle;
  late final _NewDart _new;
  late final _StartDart _start;
  late final _ConnectDart _connect;
  late final _SendDart _send;
  late final _SetCallbacksDart _setCallbacks;
  late final _CloseDart _closeConn;
  late final _FreeDart _free;
  late final _LastErrorDart _lastError;

  final Set<int> _connIds = <int>{};
  bool _connected = false;
  NativeCallable<UUDataCbNative>? _dataCallable;
  NativeCallable<UUEventCbNative>? _eventCallable;

  UuFfiTransport({
    DynamicLibrary? library,
    required String deviceId,
    String? certDir,
    int? listenPort,
  }) : _lib = library ?? defaultUuFfiLibrary() {
    _new = _lib.lookupFunction<_NewNative, _NewDart>('uu_ffi_new');
    _start = _lib.lookupFunction<_StartNative, _StartDart>('uu_ffi_start');
    _connect = _lib.lookupFunction<_ConnectNative, _ConnectDart>('uu_ffi_connect');
    _send = _lib.lookupFunction<_SendNative, _SendDart>('uu_ffi_send');
    _setCallbacks =
        _lib.lookupFunction<_SetCallbacksNative, _SetCallbacksDart>('uu_ffi_set_callbacks');
    _closeConn = _lib.lookupFunction<_CloseNative, _CloseDart>('uu_ffi_close');
    _free = _lib.lookupFunction<_FreeNative, _FreeDart>('uu_ffi_free');
    _lastError = _lib.lookupFunction<_LastErrorNative, _LastErrorDart>('uu_ffi_last_error');

    final config = jsonEncode({
      'device_id': deviceId,
      'cert_dir': certDir,
      'listen_port': listenPort,
    });
    final cfg = config.toNativeUtf8();
    try {
      _handle = _new(cfg);
      if (_handle == nullptr) throw UuFfiException('uu_ffi_new failed: $lastError');
      // 回调必须立即拷贝 data（仅回调期间有效，附录 B）。
      _dataCallable = NativeCallable<UUDataCbNative>.isolateLocal(_onDataNative);
      _eventCallable = NativeCallable<UUEventCbNative>.isolateLocal(_onEventNative);
      _setCallbacks(_handle, _dataCallable!.nativeFunction, _eventCallable!.nativeFunction, nullptr);
      final rc = _start(_handle);
      if (rc != 0) throw UuFfiException('uu_ffi_start failed($rc): $lastError');
    } finally {
      calloc.free(cfg);
    }
  }

  /// 失败原因（UTF-8，线程局部）。
  String get lastError {
    final p = _lastError(_handle);
    return p == nullptr ? '' : p.toDartString();
  }

  @override
  bool get isConnected => _connected;

  @override
  Future<int> connect(String addr, {String? peerPin}) async {
    final a = addr.toNativeUtf8();
    final pin = (peerPin ?? '').toNativeUtf8();
    try {
      final connId = _connect(_handle, a, pin);
      if (connId == 0) throw UuFfiException('uu_ffi_connect failed: $lastError');
      _connIds.add(connId);
      _connected = true;
      return connId;
    } finally {
      calloc.free(a);
      calloc.free(pin);
    }
  }

  @override
  void send(int connId, int channel, Uint8List bytes) {
    final ptr = calloc<Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      final rc = _send(_handle, connId, channel, ptr, bytes.length);
      if (rc != 0) {
        emitEvent(UuEvent('error', {'msg': 'uu_ffi_send failed($rc): $lastError'}));
      }
    } finally {
      calloc.free(ptr);
    }
  }

  void _onDataNative(Pointer<Void> ctx, int channel, int connId, Pointer<Uint8> data, int len) {
    // Rust 线程触发，立即拷贝。
    final copy = Uint8List(len)..setRange(0, len, data.asTypedList(len));
    emitData(UuDataFrame(channel: channel, connId: connId, data: copy));
  }

  void _onEventNative(Pointer<Void> ctx, Pointer<Utf8> eventJson) {
    if (eventJson == nullptr) return;
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(eventJson.toDartString()) as Map<String, dynamic>;
    } catch (_) {
      payload = {'raw': eventJson.toDartString()};
    }
    final type = (payload['t'] ?? 'unknown') as String;
    if (type == 'connected') _connected = true;
    if (type == 'disconnected') {
      final id = payload['conn_id'];
      if (id is int) _connIds.remove(id);
      if (_connIds.isEmpty) _connected = false;
    }
    emitEvent(UuEvent(type, payload));
  }

  @override
  Future<void> close() async {
    for (final id in _connIds.toList()) {
      _closeConn(_handle, id);
    }
    _connIds.clear();
    _connected = false;
  }

  @override
  void dispose() {
    if (_disposedOnce) return;
    _disposedOnce = true;
    close();
    _free(_handle);
    _dataCallable?.close();
    _eventCallable?.close();
    super.dispose();
  }

  bool _disposedOnce = false;
}

class UuFfiException implements Exception {
  final String message;
  UuFfiException(this.message);
  @override
  String toString() => 'UuFfiException: $message';
}
