import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // TODO: 将 UuVideoDecoderPlugin.swift / UuProjectionPlugin.swift 加入 Runner target 后启用：
    // if let controller = window?.rootViewController as? FlutterViewController {
    //   UuVideoDecoderPlugin.register(with: controller.engine?.registers? ...)
    //   实际应使用 registrar: FlutterEngine().registrar(forPlugin: "uudesk")
    // }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
