import 'dart:async';

import 'package:flutter/services.dart';

/// Android 原生 H264 解码服务（MethodChannel `uudesk/video_decoder`）。
/// 解码到 SurfaceTexture，返回的 textureId 供 Flutter `Texture` 组件渲染。
/// 无原生插件（如桌面/测试环境）时全部方法安全降级为 null。
class VideoDecoderService {
  static const MethodChannel _ch = MethodChannel('uudesk/video_decoder');

  int? textureId;
  int _width = 0;
  int _height = 0;

  bool get available => textureId != null;

  /// 配置解码器并创建纹理；分辨率变化时重建。
  Future<int?> configure(int width, int height) async {
    if (width == _width && height == _height && textureId != null) return textureId;
    await release();
    try {
      final id = await _ch.invokeMethod<int>('configure', {
        'width': width, 'height': height,
      });
      textureId = id;
      _width = width;
      _height = height;
      return id;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 送入一帧 Annex-B NAL 数据。
  Future<void> decode(Uint8List nal, {required bool keyframe}) async {
    if (textureId == null) return;
    try {
      await _ch.invokeMethod<void>('decode', {
        'data': nal, 'keyframe': keyframe,
      });
    } on PlatformException {
      // 丢帧不致命，请求 IDR 由上层处理。
    } on MissingPluginException {
      textureId = null;
    }
  }

  Future<void> release() async {
    if (textureId == null) return;
    try {
      await _ch.invokeMethod<void>('release');
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
    textureId = null;
    _width = 0;
    _height = 0;
  }
}
