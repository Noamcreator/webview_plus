import Flutter
import UIKit

public class WebviewPlusPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "webview_plus", binaryMessenger: registrar.messenger())
    let instance = WebviewPlusPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)

    // Enregistre la factory de PlatformView native (WKWebview) sous le
    // même identifiant que côté Dart (`_kViewType` dans
    // webview_plus_widget.dart), utilisé par `UiKitView(viewType: ...)`.
    let factory = WebviewPlusFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "plugins.noam.me/webview_plus")
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