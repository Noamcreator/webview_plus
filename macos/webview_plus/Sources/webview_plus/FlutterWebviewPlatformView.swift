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

    // -- Registre global des instances vivantes ------------------------------
    //
    // Voir le pendant iOS (même mécanisme) : permet à
    // `WebviewPlusController.setWebContentsDebuggingEnabled` (canal
    // `plugins.noam.me/webview_plus_info` dans `WebviewPlusPlugin.swift`) de
    // basculer `isInspectable` sur toutes les instances déjà créées.
    private static let liveInstances = NSHashTable<WebviewPlusPlatformView>.weakObjects()
    // `false` par défaut, à l'image du comportement natif macOS
    // (`WKWebView.isInspectable` est désactivé tant qu'on ne l'active pas
    // explicitement).
    private static var webContentsDebuggingEnabled = false

    static func setWebContentsDebuggingEnabled(_ enabled: Bool) {
        webContentsDebuggingEnabled = enabled
        if #available(macOS 13.3, *) {
            for instance in liveInstances.allObjects {
                instance.isInspectable = enabled
            }
        }
    }

    // -- Réglages dérivés de `initialSettings` ------------------------------
    private var disableContextMenu = false
    private var disableLongPressLinks = false
    private var selectionCssColor: String?
    private var selectionTextCssColor: String?

    /// Voir `WebviewSettings.disablePrinting` côté Dart : bloque
    /// `window.print()` (injecté dans `bridgeScript`) et le raccourci
    /// clavier Cmd+P (voir `performKeyEquivalent`).
    private var disablePrinting = false

    // Mis à jour en continu par le script injecté (mouseover/mouseout) afin
    // de savoir, au moment du clic droit, si le curseur survole un lien —
    // macOS n'exposant pas d'équivalent public au `hitTestResult` Android.
    private var isHoveringLink = false

    // Empêche de renvoyer `onNavigationRequest` pour les navigations que
    // l'on a nous-mêmes déclenchées suite à une validation Dart (ou via
    // loadUrl/reload/goBack/goForward), pour éviter une boucle infinie.
    private var isNavigatingInternally = false

    // Dernier script CSS de thème de scrollbar généré (voir
    // `buildScrollbarCssScript`), rejoué tel quel par `setScrollbarTheme`
    // pour une mise à jour à chaud du document courant.
    private var scrollbarCssScript: String = ""

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

        configuration.preferences.javaScriptCanOpenWindowsAutomatically =
            (settings?["javaScriptCanOpenWindowsAutomatically"] as? Bool) ?? false

        // Lecture automatique des médias : bloque toute lecture audio/vidéo
        // tant qu'un geste utilisateur ne l'a pas déclenchée (API unifiée
        // remplaçant l'ancien booléen `requiresUserActionForMediaPlayback`).
        let mediaPlaybackRequiresUserGesture =
            (settings?["mediaPlaybackRequiresUserGesture"] as? Bool) ?? true
        configuration.mediaTypesRequiringUserActionForPlayback =
            mediaPlaybackRequiresUserGesture ? .all : []

        // Pas de désactivation directe du DOM storage sur WKWebView ; on
        // utilise un websiteDataStore non-persistant en approximation quand
        // `domStorageEnabled == false` ou `incognito == true` (données en
        // mémoire, effacées à la destruction de la vue). `cacheEnabled ==
        // false` reçoit le même traitement : WKWebView ne permet pas de
        // désactiver le cache HTTP indépendamment du reste des données du
        // site.
        let incognito = (settings?["incognito"] as? Bool) ?? false
        let cacheEnabled = (settings?["cacheEnabled"] as? Bool) ?? true
        if (settings?["domStorageEnabled"] as? Bool) == false || incognito || !cacheEnabled {
            configuration.websiteDataStore = .nonPersistent()
        }

        // Accès `file://` élargi (voir `WebviewSettings.allowFileAccessFromFileURLs`
        // / `.allowUniversalAccessFromFileURLs` côté Dart). Sans ça, une page
        // chargée depuis le disque (`loadFile`/`loadFlutterAsset`) ne peut
        // pas récupérer d'autres fichiers locaux via `fetch`/XHR — la cause
        // la plus fréquente d'un fichier local qui "ne s'ouvre pas".
        // `allowFileAccessFromFileURLs` est une clé privée de `WKPreferences`,
        // `allowUniversalAccessFromFileURLs` une clé privée de
        // `WKWebViewConfiguration` elle-même : ce sont des clés KVC non
        // documentées publiquement mais stables et largement utilisées
        // (WebKit open-source les expose bien sous ces noms).
        let allowFileAccessFromFileURLs =
            (settings?["allowFileAccessFromFileURLs"] as? Bool) ?? false
        let allowUniversalAccessFromFileURLs =
            (settings?["allowUniversalAccessFromFileURLs"] as? Bool) ?? false
        if allowFileAccessFromFileURLs || allowUniversalAccessFromFileURLs {
            configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        }
        if allowUniversalAccessFromFileURLs {
            configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        }

        super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: configuration)

        Self.liveInstances.add(self)

        wantsLayer = true

        self.wantsLayer = wantsLayer
        self.autoresizingMask = [.width, .height]

        userContentController.add(
            LeakAvoidingScriptMessageHandler(self), name: "WebviewPlusChannel")
        userContentController.add(
            LeakAvoidingScriptMessageHandler(self), name: "WebviewPlusJsHandler")
        userContentController.add(
            LeakAvoidingScriptMessageHandler(self), name: "WebviewPlusLinkHover")
        userContentController.add(
            LeakAvoidingScriptMessageHandler(self), name: "WebviewPlusDomContentLoaded")
        userContentController.add(
            LeakAvoidingScriptMessageHandler(self), name: "WebviewPlusFontsLoaded")

        applySettings(settings)

        // `initialUserScripts` : injectés en plus du script de pont
        // ci-dessous, chacun avec son propre `injectionTime`. Un
        // `WKUserScript` par entrée (plutôt que de les concaténer dans
        // `bridgeScript()`) afin de respecter individuellement le réglage
        // `forMainFrameOnly` de chacun.
        for userScript in parseUserScripts(settings) {
            userContentController.addUserScript(userScript)
        }

        // Le script de pont dépend de `selectionCssColor`, calculé par
        // `applySettings` : on l'ajoute donc après coup.
        userContentController.addUserScript(WKUserScript(
            source: bridgeScript(initialCss: creationParams?["initialCss"] as? String),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        // Thème des barres de défilement (voir `WebviewWidget._resolveWindowsScrollbarTheme`
        // côté Dart, réutilisé tel quel pour macOS/Linux) : injecté en tant
        // que `WKUserScript` persistant, à l'instar du script de pont.
        // `hideNativeScrollbars` (voir `WebviewSettings`) a priorité sur
        // `scrollbarTheme`, comme sur Windows.
        let hideNativeScrollbars = (settings?["hideNativeScrollbars"] as? Bool) ?? false
        let scrollbarTheme = creationParams?["scrollbarTheme"] as? [String: Any?]
        if hideNativeScrollbars {
            scrollbarCssScript = Self.buildScrollbarCssScript(["mode": "hidden"])
            userContentController.addUserScript(WKUserScript(
                source: scrollbarCssScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        } else if let scrollbarTheme = scrollbarTheme {
            scrollbarCssScript = Self.buildScrollbarCssScript(scrollbarTheme)
            userContentController.addUserScript(WKUserScript(
                source: scrollbarCssScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }

        // `forceDarkMode` (voir `WebviewSettings`) : force `prefers-color-scheme:
        // dark` en imposant l'apparence effective de la vue — WKWebView en
        // hérite pour évaluer ce media query CSS, sans toucher au thème
        // système de l'app hôte.
        if (settings?["forceDarkMode"] as? Bool) == true {
            appearance = NSAppearance(named: .darkAqua)
        }

        navigationDelegate = self
        uiDelegate = self

        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        let initialAsset = creationParams?["initialAsset"] as? String
        let initialUrl = creationParams?["initialUrl"] as? String
        let initialFile = creationParams?["initialFile"] as? String
        let initialData = creationParams?["initialData"] as? [String: Any?]
        if let initialAsset = initialAsset {
            loadFlutterAsset(initialAsset)
        } else if let initialFile = initialFile {
            loadFile(initialFile)
        } else if let initialUrl = initialUrl, let url = URL(string: initialUrl) {
            isNavigatingInternally = true
            load(URLRequest(url: url))
        } else if let initialData = initialData {
            loadInitialData(initialData)
        }
    }

    /// Charge le contenu initial fourni via `WebviewWidget(initialData: ...)`
    /// (voir `WebviewInitialData` côté Dart).
    private func loadInitialData(_ data: [String: Any?]) {
        guard let content = data["data"] as? String else { return }
        let mimeType = (data["mimeType"] as? String) ?? "text/html"
        let encodingName = (data["encoding"] as? String) ?? "utf8"
        let baseUrl = (data["baseUrl"] as? String).flatMap { URL(string: $0) } ?? URL(string: "about:blank")!
        isNavigatingInternally = true
        load(
            content.data(using: .utf8) ?? Data(),
            mimeType: mimeType,
            characterEncodingName: encodingName,
            baseURL: baseUrl
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) non supporté")
    }

    deinit {
        Self.liveInstances.remove(self)
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
        } else if let bgColorValue = settings?["initialBackgroundColor"] as? Int {
            // Couleur de secours peinte pendant le chargement initial (voir
            // `WebviewSettings.initialBackgroundColor`). Sans effet si
            // `transparentBackground == true` (le fond doit alors rester
            // transparent pour laisser voir le contenu Flutter derrière).
            setValue(false, forKey: "drawsBackground")
            layer?.backgroundColor = cgColor(fromArgb: bgColorValue)
        }

        if let userAgent = settings?["userAgent"] as? String {
            customUserAgent = userAgent
        }

        if #available(macOS 13.3, *) {
            // `setWebContentsDebuggingEnabled` (global) sert de valeur par
            // défaut ; `isInspectable` (par instance) peut l'outrepasser
            // explicitement à `true`.
            isInspectable =
                Self.webContentsDebuggingEnabled || (settings?["isInspectable"] as? Bool) == true
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
        disablePrinting = (settings?["disablePrinting"] as? Bool) ?? false

        if let colorValue = settings?["selectionTextColor"] as? Int {
            selectionCssColor = argbToCssRgba(colorValue)
        }

        // NB : macOS n'a pas d'équivalent de la teinte native des "poignées"
        // de sélection Android — `selectionHandleColor` n'a donc pas de
        // contrepartie ici, seul `selectionTextColor` (CSS `::selection`)
        // s'applique.

        if let appName = settings?["applicationNameForUserAgent"] as? String, !appName.isEmpty {
            configuration.applicationNameForUserAgent = appName
        }

        if #available(macOS 11.3, *), let minSize = settings?["minimumFontSize"] as? Int {
            configuration.preferences.minimumFontSize = CGFloat(minSize)
        }
    }

    /// Traduit `WebviewSettings.initialUserScripts` (liste de `Map` côté
    /// Dart, voir `UserScript.toMap()`) en `WKUserScript`.
    private func parseUserScripts(_ settings: [String: Any?]?) -> [WKUserScript] {
        guard let rawScripts = settings?["initialUserScripts"] as? [[String: Any?]] else {
            return []
        }
        return rawScripts.compactMap { entry -> WKUserScript? in
            guard let source = entry["source"] as? String else { return nil }
            let injectionTime: WKUserScriptInjectionTime =
                (entry["injectionTime"] as? String) == "atDocumentEnd" ? .atDocumentEnd : .atDocumentStart
            let forMainFrameOnly = (entry["forMainFrameOnly"] as? Bool) ?? true
            return WKUserScript(
                source: source,
                injectionTime: injectionTime,
                forMainFrameOnly: forMainFrameOnly
            )
        }
    }

    private func argbToCssRgba(_ argb: Int) -> String {
        let a = (argb >> 24) & 0xFF
        let r = (argb >> 16) & 0xFF
        let g = (argb >> 8) & 0xFF
        let b = argb & 0xFF
        return "rgba(\(r),\(g),\(b),\(Double(a) / 255.0))"
    }

    /// Convertit un entier ARGB (voir `Color.toARGB32()` côté Dart) en
    /// `CGColor`, pour `layer?.backgroundColor` (voir
    /// `WebviewSettings.initialBackgroundColor`).
    private func cgColor(fromArgb argb: Int) -> CGColor {
        let a = CGFloat((argb >> 24) & 0xFF) / 255.0
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: a).cgColor
    }

    // MARK: - Thème des barres de défilement (scrollbar)
    //
    // macOS n'a pas de scrollbar système "surchargeable" pour un WKWebView
    // hébergé en mode composition, mais WebKit (moteur macOS ⊂ WebKit)
    // respecte les pseudo-éléments `::-webkit-scrollbar*` au même titre que
    // Linux/WebKitGTK. On réutilise donc la même structure de données que
    // `scrollbarTheme` côté Windows (`WebviewWidget._resolveWindowsScrollbarTheme`)
    // pour générer un bloc CSS équivalent.

    private static func argbField(_ theme: [String: Any?]?, _ key: String, _ fallback: String) -> String {
        guard let value = theme?[key] as? Int else { return fallback }
        let a = (value >> 24) & 0xFF
        let r = (value >> 16) & 0xFF
        let g = (value >> 8) & 0xFF
        let b = value & 0xFF
        return "rgba(\(r),\(g),\(b),\(Double(a) / 255.0))"
    }

    /// Construit le script auto-suffisant qui crée/met à jour la balise
    /// `<style id="__fw_scrollbar_style">` reflétant [theme] (voir
    /// `WebViewPlusInstance::SetScrollbarTheme` côté Windows, dont ce code
    /// est le pendant macOS).
    private static func buildScrollbarCssScript(_ theme: [String: Any?]?) -> String {
        let mode = (theme?["mode"] as? String) ?? "light"
        let css: String
        if mode == "hidden" {
            css = "::-webkit-scrollbar{display:none;}html{scrollbar-width:none;}"
        } else {
            let width = (theme?["width"] as? NSNumber)?.doubleValue ?? 12.0
            let track = argbField(theme, "trackColor", "#f0f0f0")
            let thumb = argbField(theme, "thumbColor", "rgba(0,0,0,0.4)")
            let thumbHover = argbField(theme, "thumbHoverColor", "#757575")
            let widthStr = String(format: "%.0f", width)
            css = "::-webkit-scrollbar{width:\(widthStr)px;height:\(widthStr)px;}" +
                "::-webkit-scrollbar-track{background:\(track);}" +
                "::-webkit-scrollbar-thumb{background:\(thumb);border-radius:8px;}" +
                "::-webkit-scrollbar-thumb:hover{background:\(thumbHover);}" +
                "html{scrollbar-width:auto;}"
        }
        return "(function(){" +
            "var el=document.getElementById('__fw_scrollbar_style');" +
            "if(!el){el=document.createElement('style');el.id='__fw_scrollbar_style';" +
            "(document.head||document.documentElement).appendChild(el);}" +
            "el.innerHTML=\(JsonLiteral.encode(css));})();"
    }

    // MARK: - Impression (Cmd+P)

    /// `window.print()` est neutralisé côté JS (voir `bridgeScript`), mais le
    /// raccourci Cmd+P déclenche l'impression native de `WKWebView` avant
    /// même que la page ne reçoive l'événement clavier : on l'intercepte
    /// donc aussi ici, comme sur Windows.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if disablePrinting,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "p" {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Menu contextuel (clic droit)

    /// Empêche AppKit de construire/afficher le menu contextuel natif.
    ///
    /// C'est le point d'accroche principal (appelé *avant* toute
    /// construction de `NSMenu`) : renvoyer `nil` ici empêche totalement
    /// l'apparition du menu, y compris le menu de sélection de mot ("Copier",
    /// "Rechercher avec Google", "Look Up"...) qui, sur `WKWebView`, n'est
    /// pas toujours intercepté à temps par `willOpenMenu(_:with:)` seul —
    /// c'était la cause du menu qui s'affichait encore malgré
    /// `disableContextMenu = true`.
    override func menu(for event: NSEvent) -> NSMenu? {
        if disableContextMenu {
            return nil
        }
        if disableLongPressLinks && isHoveringLink {
            return nil
        }
        return super.menu(for: event)
    }

    /// Filet de sécurité : si un menu a malgré tout été construit (chemin
    /// interne différent selon la version de WebKit), on le vide et on
    /// annule explicitement son affichage plutôt que de le laisser
    /// apparaître vide.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        if disableContextMenu {
            menu.removeAllItems()
            menu.cancelTrackingWithoutAnimation()
            return
        }
        if disableLongPressLinks && isHoveringLink {
            menu.removeAllItems()
            menu.cancelTrackingWithoutAnimation()
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
    private func bridgeScript(initialCss: String?) -> String {
        let cssBlock: String
        if selectionCssColor != nil || selectionTextCssColor != nil {
            let backgroundRule = selectionCssColor.map { "background:\($0);" } ?? ""
            let colorRule = selectionTextCssColor.map { "color:\($0);" } ?? ""
            cssBlock = "document.addEventListener('DOMContentLoaded',function(){" +
                "var st=document.createElement('style');" +
                "st.innerHTML='::selection{\(backgroundRule)\(colorRule)}';" +
                "(document.head||document.documentElement).appendChild(st);});"
        } else {
            cssBlock = ""
        }

        // `initialCss` (voir `WebviewWidget.initialCss` côté Dart) : injecté à
        // chaque chargement de page, au même titre que le CSS de sélection.
        let initialCssBlock: String
        if let initialCss = initialCss, !initialCss.isEmpty {
            initialCssBlock = "document.addEventListener('DOMContentLoaded',function(){" +
                "var ist=document.createElement('style');ist.id='__fw_initial_css';" +
                "ist.appendChild(document.createTextNode(\(JsonLiteral.encode(initialCss))));" +
                "(document.head||document.documentElement).appendChild(ist);});"
        } else {
            initialCssBlock = ""
        }

        // Voir `WebviewSettings.disablePrinting` : neutralise `window.print()`
        // en plus de l'interception du raccourci Cmd+P (voir
        // `performKeyEquivalent`).
        let printBlock = disablePrinting ? "window.print=function(){};" : ""

        return """
        (function(){
          if (window.webview_plus) return;
          \(cssBlock)
          \(initialCssBlock)
          \(printBlock)

          // Prévient Dart quand le DOM est prêt (équivalent de l'implémentation
          // Android). Ce script est injecté via WKUserScript à
          // `.atDocumentStart`, ce qui offre une meilleure garantie de timing
          // qu'Android (evaluateJavascript depuis onPageStarted), mais on
          // couvre quand même le cas où le document serait déjà chargé au
          // moment où ce script s'exécute (frame secondaire tardive, etc.).
          function __fwNotifyDomContentLoaded() {
            window.webkit.messageHandlers.WebviewPlusDomContentLoaded.postMessage(window.location.href);
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', __fwNotifyDomContentLoaded);
          } else {
            __fwNotifyDomContentLoaded();
          }

          if (window.document.fonts && window.document.fonts.ready) {
            window.document.fonts.ready.then(function(fontFaceSet) {
              var families = [];
              fontFaceSet.forEach(function(f) { families.push(f.family); });
              window.webkit.messageHandlers.WebviewPlusFontsLoaded.postMessage(JSON.stringify(families));
            });
          }

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
        case "WebviewPlusDomContentLoaded":
            if let url = message.body as? String {
                channel.invokeMethod("onDOMContentLoaded", arguments: url)
            }
        case "WebviewPlusFontsLoaded":
            if let familiesJson = message.body as? String {
                channel.invokeMethod("onFontsIsLoaded", arguments: familiesJson)
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
        evaluateJavaScript(script, completionHandler: nil)
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
        evaluateJavaScript(js, completionHandler: nil)
    }

    private func injectCssFromUrl(_ urlFile: String) {
        let js = "(function(){var l=document.createElement('link');l.rel='stylesheet';l.href=\(JsonLiteral.encode(urlFile));" +
            "(document.head||document.documentElement).appendChild(l);})();"
        evaluateJavaScript(js, completionHandler: nil)
    }

    /// Injecte du code JavaScript brut directement dans la page en cours
    /// (voir `WebviewPlusController.injectJsData` côté Dart).
    private func injectJsData(_ jsData: String) {
        evaluateJavaScript(jsData, completionHandler: nil)
    }

    /// Injecte du CSS brut directement dans la page en cours, via une
    /// balise `<style>` ajoutée à la volée (voir
    /// `WebviewPlusController.injectCssData` côté Dart).
    private func injectCssData(_ cssData: String) {
        let js = "(function(){var s=document.createElement('style');s.type='text/css';" +
            "s.appendChild(document.createTextNode(\(JsonLiteral.encode(cssData))));" +
            "(document.head||document.documentElement).appendChild(s);})();"
        evaluateJavaScript(js, completionHandler: nil)
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
            evaluateJavaScript(code) { value, error in
                if let error = error {
                    result(FlutterError(code: "JS_ERROR", message: error.localizedDescription, details: nil))
                    return
                }
                result(value is NSNull ? nil : value)
            }

        case "getHtml":
            evaluateJavaScript("document.documentElement.outerHTML") { value, _ in
                result(value as? String)
            }

        case "injectJsData":
            guard let args = call.arguments as? [String: Any], let jsData = args["jsData"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "jsData manquant", details: nil))
                return
            }
            injectJsData(jsData)
            result(nil)

        case "injectCssData":
            guard let args = call.arguments as? [String: Any], let cssData = args["cssData"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "cssData manquant", details: nil))
                return
            }
            injectCssData(cssData)
            result(nil)

        case "setScrollbarTheme":
            let args = call.arguments as? [String: Any]
            let scrollbarTheme = args?["scrollbarTheme"] as? [String: Any?]
            scrollbarCssScript = Self.buildScrollbarCssScript(scrollbarTheme)
            evaluateJavaScript(scrollbarCssScript, completionHandler: nil)
            result(nil)

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