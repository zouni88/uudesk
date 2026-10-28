import Flutter
import ReplayKit

/// iOS 被控能力骨架：
/// - MethodChannel `uudesk/projection`：start/stop 采集。
///   iOS 无 MediaProjection 等价物，方案为 ReplayKit `RPPreviewViewController`
///   或 Broadcast Upload Extension（需 App Group 共享缓冲）；
///   TODO：Extension 采集 CMSampleBuffer → H.264 NAL → EventChannel
///   `uudesk/camera_frame` 上抛 Dart（§4 帧头由 Dart 侧添加）。
/// - MethodChannel `uudesk/accessibility`：inject。
///   iOS 无公开事件注入 API（Jailbreak 除外）；被控输入仅能通过
///   短连（shortcuts）/ MFi 键盘等受限方案，TODO 评估产品降级策略。
final class UuProjectionPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let projection = FlutterMethodChannel(
            name: "uudesk/projection", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(UuProjectionPlugin(), channel: projection)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            // TODO: 启动 ReplayKit 直播采集（Broadcast Upload Extension）。
            result(false)
        case "stop":
            // TODO: 停止采集。
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
