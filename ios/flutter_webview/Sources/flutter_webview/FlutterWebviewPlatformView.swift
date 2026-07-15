import Flutter
import UIKit
import WebKit

/// PlatformView natif iOS encapsulant un `WKWebView`, exposé côté Dart via
/// `flutter_webview_$viewId` (voir `FlutterWebViewController` dans
/// `lib/src/flutter_webview_controller.dart`).
///
/// Reproduit fidèlement la surface fonctionnelle de l'implémentation
/// Android/Windows : chargement (URL/asset/fichier/HTML/data), exécution JS
/// avec retour `dynamic` décodé, injection JS/CSS, navigation, pont de
/// messages (`FlutterWebviewChannel.postMessage`) et pont de handlers
/// (`window.flutter_webview.callHandler`).
class FlutterWebviewPlatformView: NSObject, FlutterPlatformView {
    private let webView: ConfigurableWKWebView
    private let channel: FlutterMethodChannel
    private let viewId: Int64

    // -- Réglages dérivés de `initialSettings` ------------------------------
    private var disableContextMenu = false
    private var disableLongPressLinks = false
    private var selectionCssColor: String?
    private var disabledDefaultContextMenuItems: Set<String> = []

    // -- Éléments personnalisés du menu contextuel (`ContextMenuItem`) ------
    private var customContextMenuItems: [(id: String, name: String)] = []

    // Empêche de renvoyer `onNavigationRequest` pour les navigations que
    // l'on a nous-mêmes déclenchées suite à une validation Dart (ou via
    // loadUrl/reload/goBack/goForward), pour éviter une boucle infinie.
    private var isNavigatingInternally = false

    init(
        frame: CGRect,
        viewId: Int64,
        messenger: FlutterBinaryMessenger,
        creationParams: [String: Any?]?
    ) {
        self.viewId = viewId
        self.channel = FlutterMethodChannel(name: "flutter_webview_\(viewId)", binaryMessenger: messenger)

        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController

        let settings = creationParams?["initialSettings"] as? [String: Any?]

        configuration.preferences.javaScriptEnabled =
            (settings?["javaScriptEnabled"] as? Bool) ?? true

        // Pas de désactivation directe du DOM storage sur WKWebView ; on
        // utilise un websiteDataStore non-persistant en approximation quand
        // `domStorageEnabled == false` (données en mémoire, effacées à la
        // destruction de la vue).
        if (settings?["domStorageEnabled"] as? Bool) == false {
            configuration.websiteDataStore = .nonPersistent()
        }

        self.webView = ConfigurableWKWebView(frame: frame, configuration: configuration)
        super.init()

        webView.disabledActions = []

        userContentController.add(
            LeakAvoidingScriptMessageHandler(self), name: "FlutterWebviewChannel")
        userContentController.add(
            LeakAvoidingScriptMessageHandler(self), name: "FlutterWebviewJsHandler")
        userContentController.addUserScript(WKUserScript(
            source: bridgeScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        webView.navigationDelegate = self
        webView.uiDelegate = self

        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        applySettings(settings)

        if let items = creationParams?["contextMenuItems"] as? [[String: Any]] {
            customContextMenuItems = Self.parseContextMenuItems(items)
        }

        let initialAsset = creationParams?["initialAsset"] as? String
        let initialUrl = creationParams?["initialUrl"] as? String
        let initialFile = creationParams?["initialFile"] as? String
        if let initialAsset = initialAsset {
            loadFlutterAsset(initialAsset)
        } else if let initialFile = initialFile {
            loadFile(initialFile)
        } else if let initialUrl = initialUrl, let url = URL(string: initialUrl) {
            isNavigatingInternally = true
            webView.load(URLRequest(url: url))
        }
    }

    func view() -> UIView { webView }

    private static func parseContextMenuItems(_ raw: [[String: Any]]) -> [(id: String, name: String)] {
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String else { return nil }
            return (id: id, name: name)
        }
    }

    // MARK: - Réglages

    private func applySettings(_ settings: [String: Any?]?) {
        webView.allowsBackForwardNavigationGestures =
            (settings?["allowsBackForwardNavigationGestures"] as? Bool) ?? false
        webView.allowsLinkPreview = (settings?["allowsLinkPreview"] as? Bool) ?? false

        if (settings?["transparentBackground"] as? Bool) == true {
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
        }

        if let userAgent = settings?["userAgent"] as? String {
            webView.customUserAgent = userAgent
        }

        if (settings?["isInspectable"] as? Bool) == true {
            if #available(iOS 16.4, *) {
                webView.isInspectable = true
            }
        }

        if (settings?["supportZoom"] as? Bool) == false {
            // WKWebView ne propose pas de flag natif "supportZoom" : on
            // neutralise le viewport via un petit script.
            let js = "(function(){var m=document.querySelector('meta[name=viewport]');" +
                "if(!m){m=document.createElement('meta');m.name='viewport';" +
                "(document.head||document.documentElement).appendChild(m);}" +
                "m.content='width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';})();"
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }

        disableContextMenu = (settings?["disableContextMenu"] as? Bool) ?? false
        disableLongPressLinks = (settings?["disableLongPressContextMenuOnLinks"] as? Bool) ?? false

        if let disabledItems = settings?["disabledDefaultContextMenuItems"] as? [String] {
            disabledDefaultContextMenuItems = Set(disabledItems)
        }
        webView.disabledActions = disabledDefaultContextMenuItems

        if let colorValue = settings?["selectionHandleColor"] as? Int {
            selectionCssColor = argbToCssRgba(colorValue)
            // `tintColor` pilote la couleur du curseur et des poignées de
            // sélection natives sur WKWebView (contrairement à Android, où
            // aucune API publique équivalente n'existe) : contrairement au
            // CSS `::selection` (surlignage du texte), il s'agit ici d'un
            // vrai réglage natif.
            let a = CGFloat((colorValue >> 24) & 0xFF) / 255.0
            let r = CGFloat((colorValue >> 16) & 0xFF) / 255.0
            let g = CGFloat((colorValue >> 8) & 0xFF) / 255.0
            let b = CGFloat(colorValue & 0xFF) / 255.0
            webView.tintColor = UIColor(red: r, green: g, blue: b, alpha: a == 0 ? 1 : a)
        }
    }

    private func argbToCssRgba(_ argb: Int) -> String {
        let a = (argb >> 24) & 0xFF
        let r = (argb >> 16) & 0xFF
        let g = (argb >> 8) & 0xFF
        let b = argb & 0xFF
        return "rgba(\(r),\(g),\(b),\(Double(a) / 255.0))"
    }

    // MARK: - Pont JS <-> Dart

    /// Script injecté au tout début de chaque page : expose
    /// `window.flutter_webview.callHandler(...)` (pont vers
    /// `addJavaScriptHandler` côté Dart) et `window.FlutterWebviewChannel`
    /// (pont vers `onMessageReceived`), plus le CSS de sélection éventuel.
    private func bridgeScript() -> String {
        let cssBlock: String
        if let color = selectionCssColor {
            cssBlock = "document.addEventListener('DOMContentLoaded',function(){" +
                "var st=document.createElement('style');" +
                "st.innerHTML='::selection{background:\(color);}';" +
                "(document.head||document.documentElement).appendChild(st);});"
        } else {
            cssBlock = ""
        }

        return """
        (function(){
          if (window.flutter_webview) return;
          \(cssBlock)
          var __fwCbId = 0;
          var __fwCallbacks = {};
          window.flutter_webview = {
            callHandler: function(handlerName) {
              var args = Array.prototype.slice.call(arguments, 1);
              var id = 'cb_' + (__fwCbId++);
              return new Promise(function(resolve, reject) {
                __fwCallbacks[id] = { resolve: resolve, reject: reject };
                window.webkit.messageHandlers.FlutterWebviewJsHandler.postMessage({
                  handlerName: handlerName, args: JSON.stringify(args), callbackId: id
                });
              });
            },
            _resolveCallback: function(id, result) {
              var cb = __fwCallbacks[id];
              if (cb) { cb.resolve(result); delete __fwCallbacks[id]; }
            },
            _rejectCallback: function(id, error) {
              var cb = __fwCallbacks[id];
              if (cb) { cb.reject(error); delete __fwCallbacks[id]; }
            }
          };
          window.FlutterWebviewChannel = {
            postMessage: function(msg) {
              window.webkit.messageHandlers.FlutterWebviewChannel.postMessage(String(msg));
            }
          };
        })();
        """
    }

    fileprivate func handleScriptMessage(_ message: WKScriptMessage) {
        switch message.name {
        case "FlutterWebviewChannel":
            if let text = message.body as? String {
                channel.invokeMethod("onMessageReceived", arguments: text)
            }
        case "FlutterWebviewJsHandler":
            guard let body = message.body as? [String: Any],
                  let handlerName = body["handlerName"] as? String,
                  let argsJson = body["args"] as? String,
                  let callbackId = body["callbackId"] as? String else { return }

            channel.invokeMethod(
                "onJavaScriptHandler",
                arguments: ["handlerName": handlerName, "args": argsJson]
            ) { [weak self] response in
                guard let self = self else { return }
                if let error = response as? FlutterError {
                    let literal = JsonLiteral.encode(error.message ?? error.code)
                    self.runScriptSafely(
                        "window.flutter_webview && window.flutter_webview._rejectCallback('\(callbackId)', \(literal));"
                    )
                } else if response is FlutterMethodNotImplemented {
                    let literal = JsonLiteral.encode("Aucun handler côté Dart nommé \"\(handlerName)\"")
                    self.runScriptSafely(
                        "window.flutter_webview && window.flutter_webview._rejectCallback('\(callbackId)', \(literal));"
                    )
                } else {
                    let literal = JsonLiteral.encode(response)
                    self.runScriptSafely(
                        "window.flutter_webview && window.flutter_webview._resolveCallback('\(callbackId)', \(literal));"
                    )
                }
            }
        default:
            break
        }
    }

    private func runScriptSafely(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Chargement

    private func loadFlutterAsset(_ assetPath: String) {
        let key = FlutterDartProject.lookupKey(forAsset: assetPath)
        guard let path = Bundle.main.path(forResource: key, ofType: nil) else { return }
        let url = URL(fileURLWithPath: path)
        isNavigatingInternally = true
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func loadFile(_ filePath: String) {
        if filePath.hasPrefix("http://") || filePath.hasPrefix("https://") || filePath.hasPrefix("file://") {
            if let url = URL(string: filePath) {
                isNavigatingInternally = true
                webView.load(URLRequest(url: url))
            }
            return
        }
        let url = URL(fileURLWithPath: filePath)
        isNavigatingInternally = true
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func injectScriptFromUrl(_ urlFile: String) {
        let js = "(function(){var s=document.createElement('script');s.src=\(JsonLiteral.encode(urlFile));" +
            "(document.head||document.documentElement).appendChild(s);})();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func injectCssFromUrl(_ urlFile: String) {
        let js = "(function(){var l=document.createElement('link');l.rel='stylesheet';l.href=\(JsonLiteral.encode(urlFile));" +
            "(document.head||document.documentElement).appendChild(l);})();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func assetUrl(_ assetPath: String) -> String {
        let key = FlutterDartProject.lookupKey(forAsset: assetPath)
        if let path = Bundle.main.path(forResource: key, ofType: nil) {
            return URL(fileURLWithPath: path).absoluteString
        }
        return assetPath
    }

    // MARK: - MethodChannel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "loadUrl":
            guard let args = call.arguments as? [String: Any], let urlString = args["url"] as? String,
                  let url = URL(string: urlString) else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "url manquant", details: nil))
                return
            }
            isNavigatingInternally = true
            webView.load(URLRequest(url: url))
            result(nil)

        case "loadFlutterAsset":
            guard let args = call.arguments as? [String: Any], let assetPath = args["assetPath"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "assetPath manquant", details: nil))
                return
            }
            loadFlutterAsset(assetPath)
            result(nil)

        case "loadFile":
            guard let args = call.arguments as? [String: Any], let filePath = args["filePath"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "filePath manquant", details: nil))
                return
            }
            loadFile(filePath)
            result(nil)

        case "loadHtmlString":
            guard let args = call.arguments as? [String: Any], let html = args["html"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "html manquant", details: nil))
                return
            }
            let baseUrl = (args["baseUrl"] as? String).flatMap { URL(string: $0) }
            isNavigatingInternally = true
            webView.loadHTMLString(html, baseURL: baseUrl)
            result(nil)

        case "loadData":
            guard let args = call.arguments as? [String: Any], let data = args["data"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "data manquant", details: nil))
                return
            }
            let mimeType = (args["mimeType"] as? String) ?? "text/html"
            let encodingName = (args["encoding"] as? String) ?? "utf8"
            let baseUrl = (args["baseUrl"] as? String).flatMap { URL(string: $0) } ?? URL(string: "about:blank")!
            isNavigatingInternally = true
            webView.load(
                data.data(using: .utf8) ?? Data(),
                mimeType: mimeType,
                characterEncodingName: encodingName,
                baseURL: baseUrl
            )
            result(nil)

        case "evaluateJavaScript":
            guard let args = call.arguments as? [String: Any], let code = args["code"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "code manquant", details: nil))
                return
            }
            // WKWebView décode déjà nativement le résultat JS en types
            // Objective-C pontés (NSNumber/NSString/NSArray/NSDictionary/
            // NSNull), directement compatibles avec StandardMethodCodec :
            // aucun décodage JSON manuel n'est nécessaire ici (contrairement
            // à Android/Windows où le résultat est une chaîne JSON brute).
            webView.evaluateJavaScript(code) { value, error in
                if let error = error {
                    result(FlutterError(code: "JS_ERROR", message: error.localizedDescription, details: nil))
                    return
                }
                result(value is NSNull ? nil : value)
            }

        case "getHtml":
            webView.evaluateJavaScript("document.documentElement.outerHTML") { value, _ in
                result(value as? String)
            }

        case "injectJavascriptFileFromUrl":
            guard let args = call.arguments as? [String: Any], let url = args["url"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "url manquant", details: nil))
                return
            }
            injectScriptFromUrl(url)
            result(nil)

        case "injectJavascriptFileFromAsset":
            guard let args = call.arguments as? [String: Any], let assetFilePath = args["assetFilePath"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "assetFilePath manquant", details: nil))
                return
            }
            injectScriptFromUrl(assetUrl(assetFilePath))
            result(nil)

        case "injectCSSFileFromUrl":
            guard let args = call.arguments as? [String: Any], let url = args["url"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "url manquant", details: nil))
                return
            }
            injectCssFromUrl(url)
            result(nil)

        case "injectCSSFileFromAsset":
            guard let args = call.arguments as? [String: Any], let assetFilePath = args["assetFilePath"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "assetFilePath manquant", details: nil))
                return
            }
            injectCssFromUrl(assetUrl(assetFilePath))
            result(nil)

        case "reload":
            webView.reload()
            result(nil)

        case "goBack":
            isNavigatingInternally = true
            webView.goBack()
            result(nil)

        case "goForward":
            isNavigatingInternally = true
            webView.goForward()
            result(nil)

        case "canGoBack":
            result(webView.canGoBack)

        case "canGoForward":
            result(webView.canGoForward)

        case "setContextMenuItems":
            if let args = call.arguments as? [String: Any],
               let items = args["items"] as? [[String: Any]] {
                customContextMenuItems = Self.parseContextMenuItems(items)
            } else {
                customContextMenuItems = []
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// MARK: - WKNavigationDelegate

extension FlutterWebviewPlatformView: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Laisse passer les frames secondaires (iframes) sans interception.
        guard navigationAction.targetFrame?.isMainFrame ?? false else {
            decisionHandler(.allow)
            return
        }

        if isNavigatingInternally {
            isNavigatingInternally = false
            decisionHandler(.allow)
            return
        }

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        channel.invokeMethod("onNavigationRequest", arguments: url.absoluteString) { response in
            let allow = (response as? Bool) ?? true
            decisionHandler(allow ? .allow : .cancel)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        channel.invokeMethod("onLoadStart", arguments: webView.url?.absoluteString ?? "")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        channel.invokeMethod("onLoadStop", arguments: webView.url?.absoluteString ?? "")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportError(error, url: webView.url?.absoluteString ?? "")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportError(error, url: webView.url?.absoluteString ?? "")
    }

    private func reportError(_ error: Error, url: String) {
        let nsError = error as NSError
        // Ignore l'annulation volontaire d'une navigation (ex: `loadUrl`
        // appelé pendant qu'un chargement précédent était encore en cours).
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        channel.invokeMethod("onReceivedError", arguments: [
            "url": url,
            "code": nsError.code,
            "description": nsError.localizedDescription
        ])
    }
}

// MARK: - WKUIDelegate (menu contextuel / long-press)

extension FlutterWebviewPlatformView: WKUIDelegate {
    @available(iOS 13.0, *)
    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        if disableContextMenu {
            completionHandler(nil)
            return
        }
        if disableLongPressLinks && elementInfo.linkURL != nil {
            completionHandler(nil)
            return
        }
        if customContextMenuItems.isEmpty {
            // Comportement système par défaut, sans personnalisation.
            completionHandler(nil)
            return
        }

        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [weak self] suggestedActions in
            guard let self = self else { return UIMenu(children: suggestedActions) }

            let customActions = self.customContextMenuItems.map { item -> UIAction in
                UIAction(title: item.name) { [weak self] _ in
                    self?.invokeCustomContextMenuAction(id: item.id)
                }
            }
            return UIMenu(children: suggestedActions + customActions)
        })
    }

    /// Lit la sélection courante puis notifie Dart via `onContextMenuAction`
    /// (miroir de l'implémentation Android, voir
    /// `FlutterWebviewPlatformView.invokeCustomContextMenuAction` côté
    /// Kotlin).
    private func invokeCustomContextMenuAction(id: String) {
        webView.evaluateJavaScript("window.getSelection ? window.getSelection().toString() : '';") {
            [weak self] value, _ in
            let text = value as? String ?? ""
            self?.channel.invokeMethod("onContextMenuAction", arguments: ["id": id, "text": text])
        }
    }
}

/// Sous-classe de `WKWebView` permettant de désactiver individuellement les
/// actions d'édition par défaut (copier / couper / coller / tout
/// sélectionner) du menu de sélection de texte natif, via
/// `canPerformAction(_:withSender:)`. Cette technique fonctionne car iOS
/// route les actions d'édition du contenu web à travers la chaîne de
/// répondeurs de la `WKWebView`, même si le rendu vit dans un process
/// séparé.
class ConfigurableWKWebView: WKWebView {
    var disabledActions: Set<String> = []

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if disabledActions.contains("copy") && action == #selector(UIResponderStandardEditActions.copy(_:)) {
            return false
        }
        if disabledActions.contains("cut") && action == #selector(UIResponderStandardEditActions.cut(_:)) {
            return false
        }
        if disabledActions.contains("paste") && action == #selector(UIResponderStandardEditActions.paste(_:)) {
            return false
        }
        if disabledActions.contains("selectAll") && action == #selector(UIResponderStandardEditActions.selectAll(_:)) {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

// MARK: - WKScriptMessageHandler (évite les cycles de rétention forts)

/// `WKUserContentController` retient fortement son `WKScriptMessageHandler` :
/// on passe donc par un intermédiaire faible pour éviter une fuite mémoire
/// (le PlatformView ne serait jamais désalloué sinon).
private class LeakAvoidingScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var owner: FlutterWebviewPlatformView?

    init(_ owner: FlutterWebviewPlatformView) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handleScriptMessage(message)
    }
}

/// Encode une valeur Dart (String/NSNumber/Bool/Array/Dictionary/nil) en un
/// littéral JS/JSON valide, embarquable tel quel dans un appel à
/// `evaluateJavaScript`.
enum JsonLiteral {
    static func encode(_ value: Any?) -> String {
        guard let value = value, !(value is NSNull) else { return "null" }
        if let str = value as? String {
            return encodeString(str)
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let array = value as? [Any?] {
            return "[" + array.map { encode($0) }.joined(separator: ",") + "]"
        }
        if let dict = value as? [String: Any?] {
            let entries = dict.map { key, val in "\(encodeString(key)):\(encode(val))" }
            return "{" + entries.joined(separator: ",") + "}"
        }
        return encodeString("\(value)")
    }

    private static func encodeString(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(c)
            }
        }
        out += "\""
        return out
    }
}
