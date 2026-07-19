package me.noam.webview_plus

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.view.ActionMode
import android.view.ContextThemeWrapper
import android.view.Menu
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
// --- CORRECTIF #1 -----------------------------------------------------
// API native "document-start" (AndroidX WebKit). Contrairement à
// `evaluateJavascript` appelé depuis `onPageStarted`, cette API garantit
// l'exécution du script AVANT le premier script/paint de la page, quelle
// que soit la vitesse de chargement (cas des pages locales file:// qui
// peuvent peindre avant qu'un `evaluateJavascript` asynchrone n'ait eu la
// main). Nécessite androidx.webkit:webkit >= 1.4.0 et WebView >= 106 côté
// device ; on vérifie via `WebViewFeature.isFeatureSupported` et on garde
// l'ancien mécanisme (`injectBridgeScript` + evaluateJavascript) comme
// filet de sécurité sur les appareils plus anciens.
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import android.webkit.CookieManager
import android.webkit.ValueCallback
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.util.Collections
import java.util.WeakHashMap

class WebviewPlusPlatformView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    creationParams: Map<String, Any?>?,
    preWarmedWebView: WebView? = null
) : PlatformView, MethodChannel.MethodCallHandler {

    companion object {
        // IDs de base pour les entrées personnalisées du menu de sélection
        // (`ActionMode`), en dehors de la plage utilisée par le système.
        private const val CUSTOM_MENU_ITEM_BASE_ID = 20001

        // Registre global Webview -> PlatformView, utilisé par
        // `ActionModeWindowCallbackWrapper` (voir WebviewPlusPlugin.kt)
        // pour retrouver l'instance concernée par un `ActionMode` donné, ce
        // dernier n'exposant pas directement la vue qui l'a démarré.
        private val registry = Collections.synchronizedMap(
            WeakHashMap<WebView, WebviewPlusPlatformView>()
        )

        fun forWebview(webView: WebView): WebviewPlusPlatformView? = registry[webView]
    }

    // Réutilise l'instance fournie par WebviewPlusPreloader.warmUp (via
    // WebviewPlusFactory) si disponible ; ces instances sont garanties
    // "vierges" (jamais `loadUrl` appelé dessus), donc aucun risque de
    // rater un évènement onLoadStart/onLoadStop côté Dart en les réutilisant
    // ici comme si elles venaient d'être construites normalement.
    //
    // `WebviewPlusSelectionTheme` (voir res/values/styles.xml) surcharge
    // uniquement `android:colorControlActivated`, attribut que Chromium
    // résout depuis le thème du Context passé au constructeur pour teinter
    // les poignées de sélection natives. Sa valeur par défaut est fournie
    // par `@color/webview_plus_selection_handle_color` (res/values/colors.xml),
    // surchargeable par l'application hôte (mécanisme standard de
    // surcharge de ressources d'une librairie Android). ⚠️ Ne s'applique
    // pas aux instances pré-chauffées (`preWarmedWebView`), leur Context
    // étant déjà figé au moment du `warmUp`.
    private val webView: WebView = preWarmedWebView
        ?: WebView(ContextThemeWrapper(context, R.style.WebviewPlusSelectionTheme))
    private val channel = MethodChannel(messenger, "webview_plus_$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())

    // -- Réglages dérivés de `initialSettings` -----------------------------
    private var disableContextMenu = false
    private var disableLongPressLinks = false
    private var selectionCssColor: String? = null
    private var disabledDefaultContextMenuItems: Set<String> = emptySet()

    // CSS brut fourni via `WebviewWidget(initialCss: ...)` côté Dart,
    // réinjecté à chaque chargement de page (voir `injectBridgeScript`).
    private var initialCss: String? = null

    // --- CORRECTIF #2 -------------------------------------------------
    // Mémorisé pour pouvoir être consulté depuis `onPageFinished` (voir
    // plus bas) : on ne doit PAS repasser en LAYER_TYPE_HARDWARE quand le
    // fond est transparent, car `setBackgroundColor(Color.TRANSPARENT)`
    // ne se compose fiablement (avec alpha) que sur un layer SOFTWARE sur
    // une bonne partie des versions/GPU Android. Forcer le hardware layer
    // dans ce cas provoque un flash noir (frame opaque sans alpha) juste
    // après le chargement de la page.
    private var isTransparentBackground = false

    // Scripts `initialUserScripts` (voir webview_plus_user_script.dart),
    // partitionnés par moment d'injection.
    private var userScriptsAtStart: List<String> = emptyList()
    private var userScriptsAtEnd: List<String> = emptyList()

    // --- CORRECTIF #1 (suite) ------------------------------------------
    // `true` si `userScriptsAtStart` a pu être injecté nativement via
    // `WebViewCompat.addDocumentStartJavaScript`. Dans ce cas on NE DOIT
    // PAS le réexécuter dans `injectBridgeScript` (qui reste utilisé pour
    // le pont `window.webview_plus` et le CSS de sélection), sous peine
    // de double-exécution des scripts utilisateur au document-start.
    private var documentStartScriptsInjectedNatively = false

    // -- Éléments personnalisés du menu de sélection (`ContextMenuItem`) ---
    // Liste de (id, name) ; seule la correspondance id -> callback Dart est
    // gérée côté Dart (voir `WebviewPlusController.setContextMenuItems`).
    private var customContextMenuItems: List<Pair<String, String>> = emptyList()

    init {
        registry[webView] = this
        channel.setMethodCallHandler(this)

        @Suppress("UNCHECKED_CAST")
        val settings = creationParams?.get("initialSettings") as? Map<String, Any?>
        initialCss = creationParams?.get("initialCss") as? String
        setupWebview(context, settings)

        @Suppress("UNCHECKED_CAST")
        val initialContextMenuItems =
            creationParams?.get("contextMenuItems") as? List<Map<String, Any?>>
        if (initialContextMenuItems != null) {
            customContextMenuItems = parseContextMenuItems(initialContextMenuItems)
        }

        val initialAsset = creationParams?.get("initialAsset") as? String
        val initialUrl = creationParams?.get("initialUrl") as? String
        val initialFile = creationParams?.get("initialFile") as? String
        @Suppress("UNCHECKED_CAST")
        val initialData = creationParams?.get("initialData") as? Map<String, Any?>
        when {
            initialAsset != null -> loadFlutterAsset(initialAsset)
            initialFile != null -> loadFile(initialFile)
            initialUrl != null -> webView.loadUrl(initialUrl)
            initialData != null -> loadInitialData(initialData)
            else -> {}
        }
    }

    /// Charge le contenu initial fourni via `WebviewWidget(initialData: ...)`
    /// (voir `WebviewInitialData` côté Dart). Équivalent, à la création, de
    /// l'appel `loadData` exposé après coup sur le canal par-instance.
    private fun loadInitialData(data: Map<String, Any?>) {
        val content = data["data"] as? String ?: return
        val mimeType = data["mimeType"] as? String ?: "text/html"
        val encoding = data["encoding"] as? String ?: "utf8"
        val baseUrl = data["baseUrl"] as? String
        val historyUrl = data["androidHistoryUrl"] as? String
        webView.loadDataWithBaseURL(baseUrl, content, mimeType, encoding, historyUrl)
    }

    private fun parseContextMenuItems(raw: List<Map<String, Any?>>): List<Pair<String, String>> {
        return raw.mapNotNull { entry ->
            val id = entry["id"] as? String
            val name = entry["name"] as? String
            if (id != null && name != null) id to name else null
        }
    }

    @SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
    private fun setupWebview(context: Context, settings: Map<String, Any?>?) {
        // Optimisation matérielle pour un défilement fluide
        webView.setLayerType(View.LAYER_TYPE_SOFTWARE, null)

        // Supprime l'effet "glow" en haut/bas de page au scroll : évite un
        // repaint supplémentaire à chaque frame de dépassement de bord.
        webView.overScrollMode = View.OVER_SCROLL_NEVER

        // Permet à la WebView de coopérer avec un éventuel ancêtre à
        // défilement imbriqué (nested scrolling), pour un fling plus
        // continu lorsqu'elle est composée avec d'autres vues à défilement.
        webView.isNestedScrollingEnabled = true

        applySettings(settings)

        // --- CORRECTIF #1 (suite) --------------------------------------
        // Injecte `userScriptsAtStart` (ex : le script de sync de thème
        // Dart) via la vraie API document-start si le device la supporte.
        // Doit être fait APRES `applySettings` (qui remplit
        // `userScriptsAtStart`) et AVANT tout `loadUrl`/`loadFile` déclenché
        // plus bas dans `init {}`.
        if (userScriptsAtStart.isNotEmpty() &&
            WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
        ) {
            userScriptsAtStart.forEach { source ->
                WebViewCompat.addDocumentStartJavaScript(
                    webView,
                    "(function(){ $source })();",
                    setOf("*")
                )
            }
            documentStartScriptsInjectedNatively = true
        }

        webView.setOnFocusChangeListener { _, hasFocus ->
            mainHandler.post {
                if (hasFocus) {
                    channel.invokeMethod("onWindowFocus", null)
                } else {
                    channel.invokeMethod("onWindowBlur", null)
                }
            }
        }

        webView.addJavascriptInterface(
            WebviewPlusJsBridge { message ->
                mainHandler.post {
                    channel.invokeMethod("onMessageReceived", message)
                }
            },
            "WebviewPlusChannel"
        )

        webView.addJavascriptInterface(
            WebviewPlusDomContentLoadedBridge { url ->
                mainHandler.post {
                    channel.invokeMethod("onDOMContentLoaded", url)
                }
            },
            "WebviewPlusDomContentLoaded"
        )

        webView.addJavascriptInterface(
            WebviewPlusFontsLoadedBridge { familiesJson ->
                mainHandler.post {
                    channel.invokeMethod("onFontsIsLoaded", familiesJson)
                }
            },
            "WebviewPlusFontsLoaded"
        )

        // Pont utilisé par `window.webview_plus.callHandler(...)` côté JS
        // pour appeler les handlers Dart enregistrés via
        // `controller.addJavaScriptHandler(...)`.
        webView.addJavascriptInterface(
            WebviewPlusJsHandlerBridge { handlerName, argsJson, callbackId ->
                mainHandler.post {
                    channel.invokeMethod(
                        "onJavaScriptHandler",
                        mapOf("handlerName" to handlerName, "args" to argsJson),
                        object : MethodChannel.Result {
                            override fun success(resultObj: Any?) {
                                val json = resultToJsonLiteral(resultObj)
                                mainHandler.post {
                                    webView.evaluateJavascript(
                                        "window.webview_plus && window.webview_plus._resolveCallback('$callbackId', $json);",
                                        null
                                    )
                                }
                            }

                            override fun error(
                                errorCode: String,
                                errorMessage: String?,
                                errorDetails: Any?
                            ) {
                                val msg = resultToJsonLiteral(errorMessage ?: errorCode)
                                mainHandler.post {
                                    webView.evaluateJavascript(
                                        "window.webview_plus && window.webview_plus._rejectCallback('$callbackId', $msg);",
                                        null
                                    )
                                }
                            }

                            override fun notImplemented() {
                                error("NOT_IMPLEMENTED", "Aucun handler côté Dart", null)
                            }
                        }
                    )
                }
            },
            "WebviewPlusJsHandler"
        )

        setupContextMenuHandling()

        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                injectBridgeScript()
                mainHandler.post { channel.invokeMethod("onLoadStart", url) }
            }

            override fun onPageFinished(view: WebView, url: String) {
                // --- CORRECTIF #2 --------------------------------------
                // Ne repasse en hardware layer que si le fond n'est PAS
                // transparent : c'est cette combinaison précise
                // (setBackgroundColor(TRANSPARENT) + LAYER_TYPE_HARDWARE)
                // qui casse la composition de l'alpha et provoque un
                // flash noir juste après le chargement de la page.
                if (!isTransparentBackground) {
                    webView.setLayerType(View.LAYER_TYPE_HARDWARE, null)
                }
                mainHandler.post { channel.invokeMethod("onLoadStop", url) }
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError
            ) {
                if (request.isForMainFrame) {
                    mainHandler.post {
                        channel.invokeMethod(
                            "onReceivedError",
                            mapOf(
                                "url" to request.url.toString(),
                                "code" to error.errorCode,
                                "description" to error.description.toString()
                            )
                        )
                    }
                }
            }

            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest
            ): Boolean {
                val url = request.url.toString()
                handleNavigationRequest(url)
                return true
            }

            @Suppress("OverridingDeprecatedMember")
            override fun shouldOverrideUrlLoading(
                view: WebView,
                url: String
            ): Boolean {
                handleNavigationRequest(url)
                return true
            }
        }
    }

    private fun applySettings(settings: Map<String, Any?>?) {
        val s = webView.settings
        s.javaScriptEnabled = (settings?.get("javaScriptEnabled") as? Boolean) ?: true
        s.domStorageEnabled = (settings?.get("domStorageEnabled") as? Boolean) ?: true
        s.allowFileAccess = (settings?.get("allowFileAccess") as? Boolean) ?: true
        s.allowContentAccess = (settings?.get("allowContentAccess") as? Boolean) ?: true
        s.setSupportZoom((settings?.get("supportZoom") as? Boolean) ?: true)
        s.builtInZoomControls = (settings?.get("builtInZoomControls") as? Boolean) ?: true
        s.displayZoomControls = (settings?.get("displayZoomControls") as? Boolean) ?: false
        s.mediaPlaybackRequiresUserGesture = (settings?.get("mediaPlaybackRequiresUserGesture") as? Boolean) ?: true

        // Cache HTTP standard (respecte les en-têtes serveur type
        // Cache-Control/ETag) : c'est déjà la valeur par défaut d'Android,
        // on la rend explicite ici car c'est elle qui permet à
        // `WebviewPlusPreloader.preloadUrl` d'accélérer les chargements
        // suivants de la même URL (cache partagé entre toutes les
        // instances WebView de l'app).
        s.cacheMode = WebSettings.LOAD_DEFAULT

        // Évite un premier rendu "zoomé" en desktop puis un re-layout vers
        // la taille mobile sur les pages sans meta viewport adapté :
        // accélère le premier paint perçu par l'utilisateur. Ignoré par
        // les pages qui définissent déjà leur propre meta viewport.
        s.useWideViewPort = (settings?.get("useWideViewPort") as? Boolean) ?: true
        s.loadWithOverviewMode = (settings?.get("loadWithOverviewMode") as? Boolean) ?: true

        // -- Gestion du WebviewContentMode (Desktop / Mobile / Recommended) --
        val contentMode = settings?.get("webviewContentMode") as? String
        when (contentMode) {
            "desktop" -> {
                // Modifie l'User-Agent pour se faire passer pour un ordinateur de bureau (Chrome sur Linux)
                val desktopUserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
                s.userAgentString = desktopUserAgent
                s.useWideViewPort = true
                s.loadWithOverviewMode = true
            }
            "mobile" -> {
                // Force le comportement Mobile standard en réinitialisant l'User-Agent par défaut
                s.userAgentString = WebSettings.getDefaultUserAgent(webView.context)
                s.useWideViewPort = false
                s.loadWithOverviewMode = false
            }
            else -> {
                // Mode "recommended" ou par défaut : on utilise ce qui a été défini par les paramètres individuels
                s.useWideViewPort = (settings?.get("useWideViewPort") as? Boolean) ?: true
                s.loadWithOverviewMode = (settings?.get("loadWithOverviewMode") as? Boolean) ?: true
                (settings?.get("userAgent") as? String)?.let { s.userAgentString = it }
            }
        }

        (settings?.get("userAgent") as? String)?.let { s.userAgentString = it }

        // --- CORRECTIF #2 (suite) --------------------------------------
        // On mémorise l'état dans `isTransparentBackground` (propriété de
        // classe) au lieu d'une simple variable locale, pour pouvoir le
        // relire depuis `onPageFinished`.
        isTransparentBackground = (settings?.get("transparentBackground") as? Boolean) == true
        if (isTransparentBackground) {
            webView.setBackgroundColor(Color.TRANSPARENT)
        }

        if ((settings?.get("isInspectable") as? Boolean) == true) {
            WebView.setWebContentsDebuggingEnabled(true)
        }

        disableContextMenu = (settings?.get("disableContextMenu") as? Boolean) ?: false
        disableLongPressLinks =
            (settings?.get("disableLongPressContextMenuOnLinks") as? Boolean) ?: false

        @Suppress("UNCHECKED_CAST")
        val disabledItems = settings?.get("disabledDefaultContextMenuItems") as? List<String>
        disabledDefaultContextMenuItems = disabledItems?.toSet() ?: emptySet()

        val colorValue = when (val raw = settings?.get("selectionTextColor")) {
            is Int -> raw.toLong()
            is Long -> raw
            else -> null
        }
        selectionCssColor = colorValue?.let { argbToCssRgba(it.toInt()) }

        @Suppress("UNCHECKED_CAST")
        val rawUserScripts = settings?.get("initialUserScripts") as? List<Map<String, Any?>>
        val start = mutableListOf<String>()
        val end = mutableListOf<String>()
        rawUserScripts?.forEach { entry ->
            val source = entry["source"] as? String ?: return@forEach
            when (entry["injectionTime"] as? String) {
                "atDocumentEnd" -> end.add(source)
                else -> start.add(source)
            }
        }
        userScriptsAtStart = start
        userScriptsAtEnd = end

        val disableKeyboardResize = (settings?.get("disableKeyboardResize") as? Boolean) ?: false
        applyKeyboardResizeSetting(disableKeyboardResize)

        // -- Nouveaux réglages génériques ------------------------------------

        val incognito = (settings?.get("incognito") as? Boolean) ?: false
        val cacheEnabled = (settings?.get("cacheEnabled") as? Boolean) ?: true
        s.cacheMode = when {
            incognito -> WebSettings.LOAD_NO_CACHE
            cacheEnabled -> WebSettings.LOAD_DEFAULT
            else -> WebSettings.LOAD_NO_CACHE
        }
        s.domStorageEnabled = s.domStorageEnabled && !incognito

        (settings?.get("applicationNameForUserAgent") as? String)?.let { appName ->
            if (appName.isNotEmpty()) {
                s.userAgentString = "${s.userAgentString} $appName"
            }
        }

        (settings?.get("textZoom") as? Int)?.let { s.textZoom = it }

        (settings?.get("minimumFontSize") as? Int)?.let { s.minimumFontSize = it }

        (settings?.get("initialScale") as? Int)?.let { webView.setInitialScale(it) }

        val thirdPartyCookies = (settings?.get("thirdPartyCookiesEnabled") as? Boolean) ?: true
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, thirdPartyCookies)

        s.setGeolocationEnabled((settings?.get("geolocationEnabled") as? Boolean) ?: false)

        s.javaScriptCanOpenWindowsAutomatically =
            (settings?.get("javaScriptCanOpenWindowsAutomatically") as? Boolean) ?: false

        if (WebViewFeature.isFeatureSupported(WebViewFeature.SAFE_BROWSING_ENABLE)) {
            WebSettingsCompat.setSafeBrowsingEnabled(
                s, (settings?.get("safeBrowsingEnabled") as? Boolean) ?: true)
        }

        s.mixedContentMode = if ((settings?.get("allowMixedContent") as? Boolean) == true) {
            WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
        } else {
            WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
        }

        if (WebViewFeature.isFeatureSupported(WebViewFeature.FORCE_DARK)) {
            @Suppress("DEPRECATION")
            WebSettingsCompat.setForceDark(
                s,
                if ((settings?.get("forceDarkMode") as? Boolean) == true) {
                    WebSettingsCompat.FORCE_DARK_ON
                } else {
                    WebSettingsCompat.FORCE_DARK_OFF
                }
            )
        }

        webView.overScrollMode = when (settings?.get("overScrollMode") as? String) {
            "always" -> View.OVER_SCROLL_ALWAYS
            "never" -> View.OVER_SCROLL_NEVER
            else -> View.OVER_SCROLL_IF_CONTENT_SCROLLS
        }

        val hideNativeScrollbars = (settings?.get("hideNativeScrollbars") as? Boolean) ?: false
        webView.isVerticalScrollBarEnabled = !hideNativeScrollbars
        webView.isHorizontalScrollBarEnabled = !hideNativeScrollbars
    }

    /// Empêche la WebView de réagir au changement de hauteur de l'inset IME
    /// (clavier virtuel) lorsque [disable] vaut `true`, en le mettant
    /// systématiquement à zéro avant que la vue (et donc le moteur Chromium
    /// sous-jacent, qui redimensionne son viewport interne d'après cet
    /// inset) ne le voie. Approche 100% native basée sur
    /// `WindowInsetsCompat`, sans aucun script s'appuyant sur
    /// `window.innerHeight`.
    private fun applyKeyboardResizeSetting(disable: Boolean) {
        if (!disable) {
            ViewCompat.setOnApplyWindowInsetsListener(webView, null)
            return
        }
        ViewCompat.setOnApplyWindowInsetsListener(webView) { view, insets ->
            val stripped = WindowInsetsCompat.Builder(insets)
                .setInsets(WindowInsetsCompat.Type.ime(), Insets.NONE)
                .build()
            ViewCompat.onApplyWindowInsets(view, stripped)
        }
    }

    private fun argbToCssRgba(argb: Int): String {
        val a = (argb shr 24) and 0xFF
        val r = (argb shr 16) and 0xFF
        val g = (argb shr 8) and 0xFF
        val b = argb and 0xFF
        return "rgba($r,$g,$b,${a / 255.0})"
    }

    /// Appelé par `ActionModeWindowCallbackWrapper` (voir
    /// WebviewPlusPlugin.kt) à chaque affichage du menu de sélection de
    /// texte natif au-dessus de cette Webview : retire les entrées par
    /// défaut désactivées via `disabledDefaultContextMenuItems`, puis ajoute
    /// les [customContextMenuItems] enregistrés depuis Dart.
    fun customizeSelectionActionMenu(mode: ActionMode, menu: Menu) {
        if (disableContextMenu) {
            // Le menu de sélection ne devrait normalement déjà plus pouvoir
            // apparaître (voir `setupContextMenuHandling`), mais on ferme
            // par sécurité si l'appui long a tout de même déclenché un
            // `ActionMode` (ex: sélection lancée par le système lui-même).
            mode.finish()
            return
        }

        if (disabledDefaultContextMenuItems.isNotEmpty()) {
            val idsToRemove = mutableListOf<Int>()
            if (disabledDefaultContextMenuItems.contains("copy")) idsToRemove.add(android.R.id.copy)
            if (disabledDefaultContextMenuItems.contains("cut")) idsToRemove.add(android.R.id.cut)
            if (disabledDefaultContextMenuItems.contains("paste")) idsToRemove.add(android.R.id.paste)
            if (disabledDefaultContextMenuItems.contains("selectAll")) idsToRemove.add(android.R.id.selectAll)
            for (id in idsToRemove) {
                menu.removeItem(id)
            }
        }

        if (customContextMenuItems.isEmpty()) return

        customContextMenuItems.forEachIndexed { index, (id, name) ->
            menu.add(0, CUSTOM_MENU_ITEM_BASE_ID + index, index, name).apply {
                setShowAsAction(android.view.MenuItem.SHOW_AS_ACTION_IF_ROOM)
                setOnMenuItemClickListener {
                    invokeCustomContextMenuAction(id, mode)
                    true
                }
            }
        }
    }

    /// Récupère le texte actuellement sélectionné dans la page puis notifie
    /// Dart via `onContextMenuAction`, avant de fermer le menu. Reproduit la
    /// séquence blur clavier -> lecture sélection -> fermeture du menu déjà
    /// utilisée avant l'intégration de ce plugin (voir historique du projet).
    private fun invokeCustomContextMenuAction(id: String, mode: ActionMode) {
        webView.evaluateJavascript("document.activeElement && document.activeElement.blur();", null)

        val jsScript = "(function(){ var txt; if (window.getSelection) { " +
            "txt = window.getSelection().toString(); } else if (window.document.getSelection) { " +
            "txt = window.document.getSelection().toString(); } return txt; })();"

        webView.evaluateJavascript(jsScript) { rawValue ->
            var selectedText = ""
            if (rawValue != null && rawValue != "null" && rawValue.length > 2) {
                selectedText = try {
                    JSONTokener(rawValue).nextValue() as? String ?: ""
                } catch (e: Exception) {
                    rawValue.trim('"')
                }
            }
            mainHandler.post {
                channel.invokeMethod(
                    "onContextMenuAction",
                    mapOf("id" to id, "text" to selectedText)
                )
            }
            mode.finish()
        }
    }

    /// Désactive tout ou partie du menu contextuel natif déclenché par un
    /// appui long, selon [disableContextMenu] / [disableLongPressLinks].
    private fun setupContextMenuHandling() {
        webView.setOnLongClickListener {
            if (disableContextMenu) return@setOnLongClickListener true

            if (disableLongPressLinks) {
                val hitTest = webView.hitTestResult
                if (hitTest.type == WebView.HitTestResult.SRC_ANCHOR_TYPE ||
                    hitTest.type == WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE
                ) {
                    return@setOnLongClickListener true
                }
            }
            false
        }
    }

    /// Injecte, au tout début du chargement d'une page, le pont
    /// `window.webview_plus.callHandler(...)` ainsi que le CSS de
    /// couleur de sélection s'il a été configuré.
    private fun injectBridgeScript() {
        val cssInjection = selectionCssColor?.let { color ->
            """
            var __fwStyle = document.createElement('style');
            __fwStyle.innerHTML = '::selection{background:$color;}';
            (document.head || document.documentElement).appendChild(__fwStyle);
            """.trimIndent()
        } ?: ""

        // `initialCss` (voir `WebviewWidget.initialCss` côté Dart) : réinjecté
        // à chaque chargement de page, au même titre que le CSS de sélection.
        val initialCssInjection = initialCss?.takeIf { it.isNotEmpty() }?.let { css ->
            """
            var __fwInitialCssStyle = document.createElement('style');
            __fwInitialCssStyle.id = '__fw_initial_css';
            __fwInitialCssStyle.appendChild(document.createTextNode(${JSONObject.quote(css)}));
            (document.head || document.documentElement).appendChild(__fwInitialCssStyle);
            """.trimIndent()
        } ?: ""

        // --- CORRECTIF #1 (suite) --------------------------------------
        // Si `userScriptsAtStart` a déjà été injecté nativement via
        // `WebViewCompat.addDocumentStartJavaScript` (voir `setupWebview`),
        // on NE LE RÉINJECTE PAS ici pour éviter une double exécution.
        // On ne garde ce fallback `evaluateJavascript` que pour les
        // appareils ne supportant pas l'API native.
        val startUserScripts = if (documentStartScriptsInjectedNatively) {
            ""
        } else {
            userScriptsAtStart.joinToString("\n") { "(function(){ $it })();" }
        }

        // `initialUserScripts` en atDocumentEnd : exécutés juste après
        // DOMContentLoaded, avant la notification `onDOMContentLoaded` de
        // Dart.
        val endUserScripts = userScriptsAtEnd.joinToString("\n") { "(function(){ $it })();" }

        val fontsReadyScript = """
            if (window.document.fonts && window.document.fonts.ready) {
              window.document.fonts.ready.then(function(fontFaceSet) {
                var families = [];
                fontFaceSet.forEach(function(f) { families.push(f.family); });
                if (window.WebviewPlusFontsLoaded) {
                  window.WebviewPlusFontsLoaded.onFontsIsLoaded(JSON.stringify(families));
                }
              });
            }
            """.trimIndent()

        val js = """
            (function() {
              $startUserScripts

              if (window.webview_plus) return;

              function __fwNotifyDomContentLoaded() {
                $cssInjection
                $initialCssInjection
                $endUserScripts
                $fontsReadyScript
                if (window.WebviewPlusDomContentLoaded) {
                  window.WebviewPlusDomContentLoaded.onDOMContentLoaded(window.location.href);
                }
              }

              // Ce script est injecté de façon asynchrone depuis onPageStarted
              // (evaluateJavascript), ce qui n'offre aucune garantie de timing :
              // sur une page qui charge très vite (peu/pas de script bloquant),
              // l'évènement DOMContentLoaded peut déjà avoir eu lieu avant que ce
              // script n'ait eu la main pour attacher son listener — auquel cas
              // il ne se redéclenchera jamais. On couvre donc les deux cas :
              // écouter l'évènement s'il n'a pas encore eu lieu, ou notifier
              // immédiatement si le document est déjà prêt.
              if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', __fwNotifyDomContentLoaded);
              } else {
                __fwNotifyDomContentLoaded();
              }

              var __fwCallbackId = 0;
              var __fwCallbacks = {};
              window.webview_plus = {
                callHandler: function(handlerName) {
                  var args = Array.prototype.slice.call(arguments, 1);
                  var id = 'cb_' + (__fwCallbackId++);
                  return new Promise(function(resolve, reject) {
                    __fwCallbacks[id] = { resolve: resolve, reject: reject };
                    window.WebviewPlusJsHandler.callHandler(handlerName, JSON.stringify(args), id);
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
            })();
        """.trimIndent()
        webView.evaluateJavascript(js, null)
    }

    private fun handleNavigationRequest(url: String) {
        mainHandler.post {
            channel.invokeMethod(
                "onNavigationRequest",
                url,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        val allow = result as? Boolean ?: true
                        if (allow) {
                            mainHandler.post { webView.loadUrl(url) }
                        }
                    }

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?
                    ) {
                        mainHandler.post { webView.loadUrl(url) }
                    }

                    override fun notImplemented() {
                        mainHandler.post { webView.loadUrl(url) }
                    }
                }
            )
        }
    }

    private fun loadFlutterAsset(assetPath: String) {
        webView.loadUrl("file:///android_asset/flutter_assets/$assetPath")
    }

    private fun loadFile(filePath: String) {
        val uri = if (filePath.startsWith("file://") ||
            filePath.startsWith("http://") ||
            filePath.startsWith("https://")
        ) {
            filePath
        } else {
            "file://$filePath"
        }
        webView.loadUrl(uri)
    }

    private fun injectJsFromUrl(url: String) {
        val js = """
            (function() {
              var s = document.createElement('script');
              s.src = ${JSONObject.quote(url)};
              (document.head || document.documentElement).appendChild(s);
            })();
        """.trimIndent()
        webView.evaluateJavascript(js, null)
    }

    private fun injectCssFromUrl(url: String) {
        val js = """
            (function() {
              var l = document.createElement('link');
              l.rel = 'stylesheet';
              l.type = 'text/css';
              l.href = ${JSONObject.quote(url)};
              (document.head || document.documentElement).appendChild(l);
            })();
        """.trimIndent()
        webView.evaluateJavascript(js, null)
    }

    /// Injecte du code JavaScript brut directement dans la page en cours
    /// (voir `WebviewPlusController.injectJsData` côté Dart).
    private fun injectJsData(jsData: String) {
        webView.evaluateJavascript(jsData, null)
    }

    /// Injecte du CSS brut directement dans la page en cours, via une
    /// balise `<style>` ajoutée à la volée (voir
    /// `WebviewPlusController.injectCssData` côté Dart).
    private fun injectCssData(cssData: String) {
        val js = """
            (function() {
              var s = document.createElement('style');
              s.type = 'text/css';
              s.appendChild(document.createTextNode(${JSONObject.quote(cssData)}));
              (document.head || document.documentElement).appendChild(s);
            })();
        """.trimIndent()
        webView.evaluateJavascript(js, null)
    }

    private fun resultToJsonLiteral(obj: Any?): String {
        if (obj == null) return "null"
        return when (obj) {
            is String -> JSONObject.quote(obj)
            is Number, is Boolean -> obj.toString()
            is List<*> -> JSONArray(obj).toString()
            is Map<*, *> -> JSONObject(obj).toString()
            else -> JSONObject.quote(obj.toString())
        }
    }

    override fun getView(): View {
        return webView
    }

    override fun dispose() {
        registry.remove(webView)
        channel.setMethodCallHandler(null)
        webView.webViewClient = WebViewClient()
        webView.clearHistory()
        webView.loadUrl("about:blank")
        webView.removeAllViews()
        webView.destroy()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadUrl" -> {
                val url = call.argument<String>("url")
                if (url != null) {
                    webView.loadUrl(url)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "URL manquante", null)
                }
            }
            "loadFlutterAsset" -> {
                val assetPath = call.argument<String>("assetPath")
                if (assetPath != null) {
                    loadFlutterAsset(assetPath)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "assetPath manquant", null)
                }
            }
            "loadFile" -> {
                val filePath = call.argument<String>("filePath")
                if (filePath != null) {
                    loadFile(filePath)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "filePath manquant", null)
                }
            }
            "loadHtmlString" -> {
                val html = call.argument<String>("html")
                val baseUrl = call.argument<String>("baseUrl")
                if (html != null) {
                    webView.loadDataWithBaseURL(baseUrl, html, "text/html", "utf-8", null)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "Contenu HTML manquant", null)
                }
            }
            "loadData" -> {
                val data = call.argument<String>("data")
                val mimeType = call.argument<String>("mimeType") ?: "text/html"
                val encoding = call.argument<String>("encoding") ?: "utf8"
                val baseUrl = call.argument<String>("baseUrl")
                if (data != null) {
                    webView.loadDataWithBaseURL(baseUrl, data, mimeType, encoding, null)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "Data manquante", null)
                }
            }
            "evaluateJavascript" -> {
                val code = call.argument<String>("code")
                if (code != null) {
                    webView.evaluateJavascript(code) { value ->
                        if (value == null) {
                            result.success(null)
                        } else {
                            try {
                                // Tente de parser la valeur pour renvoyer des types natifs à Flutter (Int, Boolean...)
                                val parsed = JSONTokener(value).nextValue()
                                if (parsed == JSONObject.NULL) {
                                    result.success(null)
                                } else {
                                    result.success(parsed)
                                }
                            } catch (e: Exception) {
                                result.success(value)
                            }
                        }
                    }
                } else {
                    result.error("INVALID_ARGUMENT", "Code JavaScript manquant", null)
                }
            }
            "getHtml" -> {
                webView.evaluateJavascript("(function() { return document.documentElement.outerHTML; })();") { value ->
                    if (value == null || value == "null") {
                        result.success(null)
                    } else {
                        // Nettoyage de la chaîne JSON renvoyée par evaluateJavascript (enlève les guillemets de début/fin et déséchappe)
                        try {
                            val parsed = JSONTokener(value).nextValue()
                            result.success(parsed.toString())
                        } catch (e: Exception) {
                            result.success(value)
                        }
                    }
                }
            }
            "injectJsData" -> {
                val jsData = call.argument<String>("jsData")
                if (jsData != null) {
                    injectJsData(jsData)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "jsData manquant", null)
                }
            }
            "injectCssData" -> {
                val cssData = call.argument<String>("cssData")
                if (cssData != null) {
                    injectCssData(cssData)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "cssData manquant", null)
                }
            }
            "injectJavascriptFileFromUrl" -> {
                val urlFile = call.argument<String>("url")
                if (urlFile != null) {
                    injectJsFromUrl(urlFile)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "URL manquante", null)
                }
            }
            "injectJavascriptFileFromAsset" -> {
                val assetFilePath = call.argument<String>("assetFilePath")
                if (assetFilePath != null) {
                    injectJsFromUrl(assetUrl(assetFilePath))
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "assetFilePath manquant", null)
                }
            }
            "injectCSSFileFromUrl" -> {
                val urlFile = call.argument<String>("url")
                if (urlFile != null) {
                    injectCssFromUrl(urlFile)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "URL manquante", null)
                }
            }
            "injectCSSFileFromAsset" -> {
                val assetFilePath = call.argument<String>("assetFilePath")
                if (assetFilePath != null) {
                    injectCssFromUrl(assetUrl(assetFilePath))
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "assetFilePath manquant", null)
                }
            }
            "reload" -> {
                webView.reload()
                result.success(null)
            }
            "goBack" -> {
                if (webView.canGoBack()) webView.goBack()
                result.success(null)
            }
            "goForward" -> {
                if (webView.canGoForward()) webView.goForward()
                result.success(null)
            }
            "setContextMenuItems" -> {
                @Suppress("UNCHECKED_CAST")
                val items = call.argument<List<Map<String, Any?>>>("items")
                customContextMenuItems = if (items != null) parseContextMenuItems(items) else emptyList()
                result.success(null)
            }
            "canGoBack" -> result.success(webView.canGoBack())
            "canGoForward" -> result.success(webView.canGoForward())
            else -> result.notImplemented()
        }
    }

    private fun assetUrl(assetPath: String): String {
        return "file:///android_asset/flutter_assets/$assetPath"
    }
}

class WebviewPlusJsBridge(private val onMessage: (String) -> Unit) {
    @JavascriptInterface
    fun postMessage(message: String) {
        onMessage(message)
    }
}

class WebviewPlusDomContentLoadedBridge(private val callback: (String) -> Unit) {
    @JavascriptInterface
    fun onDOMContentLoaded(url: String) {
        callback(url)
    }
}

/// Pont JS -> Dart utilisé par le script injecté dans `injectBridgeScript`
/// pour notifier la résolution de `document.fonts.ready`. [familiesJson]
/// est un tableau JSON de noms de familles de police (ex : `["Roboto"]`),
/// décodé côté Dart dans `WebviewPlusController._onMethodCall`.
class WebviewPlusFontsLoadedBridge(private val callback: (String) -> Unit) {
    @JavascriptInterface
    fun onFontsIsLoaded(familiesJson: String) {
        callback(familiesJson)
    }
}

/// Pont JS <-> Dart utilisé par `window.webview_plus.callHandler(...)`.
/// `onCall` reçoit (nomDuHandler, argumentsEnJSON, idDeCallback) et est
/// invoqué sur le thread JS ; il doit poster sur le thread principal.
class WebviewPlusJsHandlerBridge(
    private val onCall: (handlerName: String, argsJson: String, callbackId: String) -> Unit
) {
    @JavascriptInterface
    fun callHandler(handlerName: String, argsJson: String, callbackId: String) {
        onCall(handlerName, argsJson, callbackId)
    }
}