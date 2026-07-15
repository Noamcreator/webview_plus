import Flutter
import UIKit

public class FlutterWebviewPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_webview", binaryMessenger: registrar.messenger())
    let instance = FlutterWebviewPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)

    // Enregistre la factory de PlatformView native (WKWebView) sous le
    // même identifiant que côté Dart (`_kViewType` dans
    // flutter_webview_widget.dart), utilisé par `UiKitView(viewType: ...)`.
    let factory = FlutterWebviewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "plugins.noam.me/flutter_webview")
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}