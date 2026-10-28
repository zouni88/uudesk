import Flutter
import UIKit
import VideoToolbox

/// iOS H.264 解码骨架（MethodChannel `uudesk/video_decoder`）。
///
/// TODO(VideoToolbox)：
/// 1. `VTDecompressionSessionCreate`（kCMVideoCodecType_H264），
///    Annex-B → AVCC（或 `vtdecoding` 直接喂 NAL 需先转 length-prefixed）。
/// 2. 解码帧（CVPixelBuffer）经 `FlutterTextureRegistry.register` 的
///    `FlutterTexturePixelBuffer.copyPixelBuffer` 上屏，configure 返回 textureId。
/// 3. decode 方法：异步 `VTDecompressionSessionDecodeFrame`，回调里刷新纹理。
/// 4. release：`VTDecompressionSessionInvalidate` + unregisterTexture。
///
/// 当前为占位实现：configure 返回 nil（Dart 侧降级为占位画面渲染）。
final class UuVideoDecoderPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "uudesk/video_decoder", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(UuVideoDecoderPlugin(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "configure":
            // TODO: 创建 VTDecompressionSession + 注册纹理，返回 textureId。
            result(nil)
        case "decode":
            // TODO: 送入 Annex-B NAL 解码并刷新纹理。
            result(nil)
        case "release":
            // TODO: 释放会话与纹理。
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
