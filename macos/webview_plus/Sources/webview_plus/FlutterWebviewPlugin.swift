import Cocoa
import FlutterMacOS
import WebKit

public class WebviewPlusPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "webview_plus", binaryMessenger: registrar.messenger)
    let instance = WebviewPlusPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)

    // Enregistre la factory de PlatformView native (WKWebview)
    let factory = WebviewPlusFactory(registrar: registrar)
    registrar.register(factory, withId: "plugins.noam.me/webview_plus")

    // Canal global partagé avec les autres plateformes pour les API qui ne
    // sont pas rattachées à une instance de Webview précise (voir
    // `WebviewCacheManager` et `WebviewPlusController.setWebContentsDebuggingEnabled`
    // côté Dart).
    let infoChannel = FlutterMethodChannel(
      name: "plugins.noam.me/webview_plus_info", binaryMessenger: registrar.messenger)
    infoChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "clearCache":
        clearWebsiteData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], result: result)
      case "clearCookies":
        clearWebsiteData(ofTypes: [WKWebsiteDataTypeCookies], result: result)
      case "clearAllData":
        clearWebsiteData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), result: result)
      case "setWebContentsDebuggingEnabled":
        let args = call.arguments as? [String: Any]
        let enabled = (args?["enabled"] as? Bool) ?? true
        WebviewPlusPlatformView.setWebContentsDebuggingEnabled(enabled)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Vide les données de `WKWebsiteDataStore.default()` (voir
  /// `WebviewCacheManager` côté Dart) : ne nécessite aucune `WKWebView` déjà
  /// créée, contrairement à l'équivalent Windows.
  private static func clearWebsiteData(ofTypes types: Set<String>, result: @escaping FlutterResult) {
    WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
      result(nil)
    }
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