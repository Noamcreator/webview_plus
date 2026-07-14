import Cocoa
import FlutterMacOS
import WebKit

/// PlatformView natif macOS encapsulant un `WKWebView`, exposé côté Dart via
/// `webview_plus_$viewId` (voir `WebviewPlusController` dans
/// `lib/src/webview_plus_controller.dart`).
///
/// Reproduit fidèlement la surface fonctionnelle de l'implémentation
/// Android/iOS : chargement (URL/asset/fichier/HTML/data), exécution JS
/// avec retour `dynamic` décodé, injection JS/CSS, navigation, pont de
/// messages (`WebviewPlusChannel.postMessage`) et pont de handlers
/// (`window.webview_plus.callHandler`).
///
/// ⚠️ Sur macOS, `FlutterPlatformViewFactory.create` doit renvoyer une
/// `NSView` directement (pas de protocole `FlutterPlatformView` séparé
/// comme sur iOS) : cette classe est donc elle-même une sous-classe de
/// `WKWebView`, ce qui a l'avantage de permettre d'y surcharger
/// `willOpenMenu(_:with:)` pour piloter le menu contextuel natif.
class WebviewPlusPlatformView: WKWebView {
    private let channel: FlutterMethodChannel
    private let viewId: Int64
    private let registrar: FlutterPluginRegistrar

    // -- Réglages dérivés de `initialSettings` ------------------------------
    private var disableContextMenu = false
    private var disableLongPressLinks = false
    private var selectionCssColor: String?

    // Mis à jour en continu par le script injecté (mouseover/mouseout) afin
    // de savoir, au moment du clic droit, si le curseur survole un lien —
    // macOS n'exposant pas d'équivalent public au `hitTestResult` Android.
    private var isHoveringLink = false

    // Empêche de renvoyer `onNavigationRequest` pour les navigations que
    // l'on a nous-mêmes déclenchées suite à une validation Dart (ou via
    // loadUrl/reload/goBack/goForward), pour éviter une boucle infinie.
    private var isNavigatingInternally = false

    init(
        viewId: Int64,
        registrar: FlutterPluginRegistrar,
        creationParams: [String: Any?]?
    ) {
        self.viewId = viewId
        self.registrar = registrar
        self.channel = FlutterMethodChannel(
            name: "webview_plus_\(viewId)",
            binaryMessenger: registrar.messenger
        )

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

        super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: configuration)
        
        wantsLayer = true

        self.wantsLayer = wantsLayer
        self.autoresizingMask = [.width, .height]

        userContentController.add(
            LeakAvoidingScriptMessageHandler(self), name: "WebviewPlusChannel")
        userContentController.add(
            LeakAvoidingScriptMessageHandler(self), name: "WebviewPlusJsHandler")
        userContentController.add(
            LeakAvoidingScriptMessageHandler(self), name: "WebviewPlusLinkHover")

        applySettings(settings)

        // Le script de pont dépend de `selectionCssColor`, calculé par
        // `applySettings` : on l'ajoute donc après coup.
        userContentController.addUserScript(WKUserScript(
            source: bridgeScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        navigationDelegate = self
        uiDelegate = self

        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
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
            load(URLRequest(url: url))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) non supporté")
    }

    // MARK: - Réglages

    private func applySettings(_ settings: [String: Any?]?) {
        allowsBackForwardNavigationGestures =
            (settings?["allowsBackForwardNavigationGestures"] as? Bool) ?? false

        // Équivalent macOS (trackpad) du pincement pour zoomer.
        allowsMagnification = (settings?["supportZoom"] as? Bool) ?? true

        if (settings?["transparentBackground"] as? Bool) == true {
            // WKWebView ne propose pas de propriété publique équivalente à
            // `isOpaque`/`backgroundColor` sur macOS : on passe par la clé
            // privée `drawsBackground` (technique standard et stable) en
            // complément d'un fond de calque transparent.
            setValue(false, forKey: "drawsBackground")
            layer?.backgroundColor = .clear
        }

        if let userAgent = settings?["userAgent"] as? String {
            customUserAgent = userAgent
        }

        if (settings?["isInspectable"] as? Bool) == true {
            if #available(macOS 13.3, *) {
                isInspectable = true
            }
        }

        if (settings?["supportZoom"] as? Bool) == false {
            // Neutralise également le viewport pour les pages pensées
            // mobile-first (cohérence avec Android/iOS).
            let js = "(function(){var m=document.querySelector('meta[name=viewport]');" +
                "if(!m){m=document.createElement('meta');m.name='viewport';" +
                "(document.head||document.documentElement).appendChild(m);}" +
                "m.content='width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';})();"
            configuration.userContentController.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }

        disableContextMenu = (settings?["disableContextMenu"] as? Bool) ?? false
        disableLongPressLinks = (settings?["disableLongPressContextMenuOnLinks"] as? Bool) ?? false

        if let colorValue = settings?["selectionHandleColor"] as? Int {
            selectionCssColor = argbToCssRgba(colorValue)
        }
    }

    private func argbToCssRgba(_ argb: Int) -> String {
        let a = (argb >> 24) & 0xFF
        let r = (argb >> 16) & 0xFF
        let g = (argb >> 8) & 0xFF
        let b = argb & 0xFF
        return "rgba(\(r),\(g),\(b),\(Double(a) / 255.0))"
    }

    // MARK: - Menu contextuel (clic droit)

    /// `willOpenMenu(_:with:)` est appelé par AppKit juste avant l'affichage
    /// du menu contextuel natif : c'est le point d'accroche macOS le plus
    /// fiable pour le désactiver, en équivalent du `setOnLongClickListener`
    /// Android ou du `contextMenuConfigurationForElement` iOS.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        if disableContextMenu {
            menu.removeAllItems()
            return
        }
        if disableLongPressLinks && isHoveringLink {
            menu.removeAllItems()
            return
        }
        super.willOpenMenu(menu, with: event)
    }

    // MARK: - Pont JS <-> Dart

    /// Script injecté au tout début de chaque page : expose
    /// `window.webview_plus.callHandler(...)` (pont vers
    /// `addJavaScriptHandler` côté Dart), `window.WebviewPlusChannel`
    /// (pont vers `onMessageReceived`), le CSS de sélection éventuel, ainsi
    /// qu'un suivi de survol des liens utilisé pour
    /// `disableLongPressContextMenuOnLinks`.
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
          if (window.webview_plus) return;
          \(cssBlock)
          var __fwCbId = 0;
          var __fwCallbacks = {};
          window.webview_plus = {
            callHandler: function(handlerName) {
              var args = Array.prototype.slice.call(arguments, 1);
              var id = 'cb_' + (__fwCbId++);
              return new Promise(function(resolve, reject) {
                __fwCallbacks[id] = { resolve: resolve, reject: reject };
                window.webkit.messageHandlers.WebviewPlusJsHandler.postMessage({
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
          window.WebviewPlusChannel = {
            postMessage: function(msg) {
              window.webkit.messageHandlers.WebviewPlusChannel.postMessage(String(msg));
            }
          };
          document.addEventListener('mouseover', function(e) {
            var t = e.target;
            var link = (t && t.closest) ? t.closest('a[href]') : null;
            window.webkit.messageHandlers.WebviewPlusLinkHover.postMessage(link ? 'enter' : 'leave');
          }, true);
          document.addEventListener('mouseout', function(e) {
            window.webkit.messageHandlers.WebviewPlusLinkHover.postMessage('leave');
          }, true);
        })();
        """
    }

    fileprivate func handleScriptMessage(_ message: WKScriptMessage) {
        switch message.name {
        case "WebviewPlusChannel":
            if let text = message.body as? String {
                channel.invokeMethod("onMessageReceived", arguments: text)
            }
        case "WebviewPlusLinkHover":
            if let state = message.body as? String {
                isHoveringLink = (state == "enter")
            }
        case "WebviewPlusJsHandler":
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
                        "window.webview_plus && window.webview_plus._rejectCallback('\(callbackId)', \(literal));"
                    )
                } else if let res = response as? NSObject, res == FlutterMethodNotImplemented {
                    let literal = JsonLiteral.encode("Aucun handler côté Dart nommé \"\(handlerName)\"")
                    self.runScriptSafely(
                        "window.webview_plus && window.webview_plus._rejectCallback('\(callbackId)', \(literal));"
                    )
                } else {
                    let literal = JsonLiteral.encode(response)
                    self.runScriptSafely(
                        "window.webview_plus && window.webview_plus._resolveCallback('\(callbackId)', \(literal));"
                    )
                }
            }
        default:
            break
        }
    }

    private func runScriptSafely(_ script: String) {
        evaluateJavascript(script, completionHandler: nil)
    }

    // MARK: - Chargement

    private func loadFlutterAsset(_ assetPath: String) {
        let key = registrar.lookupKey(forAsset: assetPath)
        guard let path = Bundle.main.path(forResource: key, ofType: nil) else { return }
        let url = URL(fileURLWithPath: path)
        isNavigatingInternally = true
        
        // Au lieu de restreindre au dossier parent direct, on donne accès 
        // à l'intégralité du Bundle de l'application. 
        // Cela permet à WKWebView de chercher et lier tous les sous-assets de Flutter.
        let bundleUrl = Bundle.main.bundleURL
        
        loadFileURL(url, allowingReadAccessTo: bundleUrl)
    }

    private func loadFile(_ filePath: String) {
        if filePath.hasPrefix("http://") || filePath.hasPrefix("https://") || filePath.hasPrefix("file://") {
            if let url = URL(string: filePath) {
                isNavigatingInternally = true
                load(URLRequest(url: url))
            }
            return
        }
        let url = URL(fileURLWithPath: filePath)
        isNavigatingInternally = true
        loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    private func injectScriptFromUrl(_ urlFile: String) {
        let js = "(function(){var s=document.createElement('script');s.src=\(JsonLiteral.encode(urlFile));" +
            "(document.head||document.documentElement).appendChild(s);})();"
        evaluateJavascript(js, completionHandler: nil)
    }

    private func injectCssFromUrl(_ urlFile: String) {
        let js = "(function(){var l=document.createElement('link');l.rel='stylesheet';l.href=\(JsonLiteral.encode(urlFile));" +
            "(document.head||document.documentElement).appendChild(l);})();"
        evaluateJavascript(js, completionHandler: nil)
    }

    private func assetUrl(_ assetPath: String) -> String {
        let key = registrar.lookupKey(forAsset: assetPath)
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
            load(URLRequest(url: url))
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
            loadHTMLString(html, baseURL: baseUrl)
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
            load(
                data.data(using: .utf8) ?? Data(),
                mimeType: mimeType,
                characterEncodingName: encodingName,
                baseURL: baseUrl
            )
            result(nil)

        case "evaluateJavascript":
            guard let args = call.arguments as? [String: Any], let code = args["code"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "code manquant", details: nil))
                return
            }
            // WKWebView décode déjà nativement le résultat JS en types
            // Objective-C pontés (NSNumber/NSString/NSArray/NSDictionary/
            // NSNull), directement compatibles avec StandardMethodCodec.
            evaluateJavascript(code) { value, error in
                if let error = error {
                    result(FlutterError(code: "JS_ERROR", message: error.localizedDescription, details: nil))
                    return
                }
                result(value is NSNull ? nil : value)
            }

        case "getHtml":
            evaluateJavascript("document.documentElement.outerHTML") { value, _ in
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
            reload()
            result(nil)

        case "goBack":
            isNavigatingInternally = true
            goBack()
            result(nil)

        case "goForward":
            isNavigatingInternally = true
            goForward()
            result(nil)

        case "canGoBack":
            result(canGoBack)

        case "canGoForward":
            result(canGoForward)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebviewPlusPlatformView: WKNavigationDelegate {
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

// MARK: - WKUIDelegate

extension WebviewPlusPlatformView: WKUIDelegate {
    // Laisse s'ouvrir les popups/nouveaux onglets (window.open, target=_blank)
    // dans la même Webview plutôt que de les avaler silencieusement.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

// MARK: - WKScriptMessageHandler (évite les cycles de rétention forts)

/// `WKUserContentController` retient fortement son `WKScriptMessageHandler` :
/// on passe donc par un intermédiaire faible pour éviter une fuite mémoire
/// (le PlatformView ne serait jamais désalloué sinon).
private class LeakAvoidingScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var owner: WebviewPlusPlatformView?

    init(_ owner: WebviewPlusPlatformView) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handleScriptMessage(message)
    }
}

/// Encode une valeur Dart (String/NSNumber/Bool/Array/Dictionary/nil) en un
/// littéral JS/JSON valide, embarquable tel quel dans un appel à
/// `evaluateJavascript`.
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
