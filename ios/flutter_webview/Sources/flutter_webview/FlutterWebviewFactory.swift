import Flutter
import UIKit

/// Factory enregistrée sous l'identifiant `plugins.noam.me/flutter_webview`,
/// instanciée par Flutter à chaque `UiKitView(viewType: ...)` créé côté Dart
/// (voir `flutter_webview_widget.dart`).
class FlutterWebviewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        let creationParams = args as? [String: Any?]
        return FlutterWebviewPlatformView(
            frame: frame,
            viewId: viewId,
            messenger: messenger,
            creationParams: creationParams
        )
    }

    /// Les `creationParams` sont envoyés depuis Dart via `StandardMessageCodec`
    /// (voir `creationParamsCodec` dans `UiKitView`) : on doit utiliser le
    /// même codec ici pour pouvoir les décoder correctement.
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}
