import Cocoa
import FlutterMacOS

/// Factory enregistrée sous l'identifiant `plugins.noam.me/webview_plus`,
/// instanciée par Flutter à chaque `AppKitView(viewType: ...)` créé côté
/// Dart (voir `webview_plus_widget.dart`).
///
/// ⚠️ Contrairement à iOS, l'API macOS (`FlutterPlatformViewFactory`) ne
/// renvoie pas un objet `FlutterPlatformView` intermédiaire mais directement
/// la `NSView` à afficher (voir `FlutterPlatformViews.h` du SDK macOS).
/// `WebviewPlusPlatformView` est donc directement une sous-classe de
/// `WKWebview`.
class WebviewPlusFactory: NSObject, FlutterPlatformViewFactory {
    private let registrar: FlutterPluginRegistrar

    init(registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
        super.init()
    }

    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
        let creationParams = args as? [String: Any?]
        return WebviewPlusPlatformView(
            viewId: viewId,
            registrar: registrar,
            creationParams: creationParams
        )
    }

    /// Les `creationParams` sont envoyés depuis Dart via `StandardMessageCodec`
    /// (voir `creationParamsCodec` dans `AppKitView`) : on doit utiliser le
    /// même codec ici pour pouvoir les décoder correctement.
    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
        FlutterStandardMessageCodec.sharedInstance()
    }
}
