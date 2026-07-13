import Cocoa
import FlutterMacOS

public class WebviewPlusPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "webview_plus", binaryMessenger: registrar.messenger)
    let instance = WebviewPlusPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)

    // Enregistre la factory de PlatformView native (WKWebview)
    let factory = WebviewPlusFactory(registrar: registrar)
    registrar.register(factory, withId: "plugins.noam.me/webview_plus")
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}