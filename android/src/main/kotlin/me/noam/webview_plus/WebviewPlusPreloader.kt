package me.noam.webview_plus

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient

/// Gère deux mécanismes distincts d'optimisation du temps de chargement
/// des Webview Android, tous deux volontairement séparés de la
/// [WebviewPlusPlatformView] "réelle" affichée à l'écran, pour éviter tout
/// risque d'incohérence d'évènements (onLoadStart/onLoadStop) côté Dart :
///
/// 1. `enginePool` (voir [warmUp] / [acquireWarmedEngine]) : des instances
///    `WebView` totalement vierges (jamais `loadUrl` appelé), construites à
///    l'avance. Le coût dominant de la toute première `WebView` créée dans
///    un process Android est le chargement du moteur Chromium natif
///    (`libwebviewchromium.so`, démarrage du process `:webview_service`,
///    etc.) — un coût *par process*, pas par instance. En sortant cette
///    construction du chemin critique (ex. juste après le premier frame de
///    l'app plutôt qu'au moment où l'utilisateur ouvre le premier écran
///    contenant une Webview), l'ouverture visible par l'utilisateur devient
///    quasi instantanée. `WebviewPlusFactory` consomme ce pool avant de
///    faire un `WebView(context)` classique.
///
/// 2. `activePreloads` (voir [preloadUrl]) : des `WebView` headless,
///    jamais attachées à une fenêtre ni affichées, dont le seul but est de
///    déclencher le téléchargement réseau (DNS, TLS, HTML, JS, CSS,
///    images...) d'une URL donnée en avance. Le cache HTTP disque de
///    `WebView` est partagé par toutes les instances de l'application
///    (même répertoire de données) : quand la vraie Webview affichée
///    charge ensuite la même URL, les ressources dont les en-têtes
///    `Cache-Control`/`ETag` le permettent sont servies depuis le cache
///    local au lieu d'être retéléchargées. Ces instances sont détruites
///    peu après pour ne pas consommer de mémoire inutilement.
object WebviewPlusPreloader {

    private val mainHandler = Handler(Looper.getMainLooper())

    private val enginePool = ArrayDeque<WebView>()
    private val activePreloads = mutableMapOf<String, WebView>()

    // Durée après laquelle une Webview de préchargement réseau est détruite
    // si elle n'a pas déjà été nettoyée par `onPageFinished`. Filet de
    // sécurité pour les URLs qui ne finissent jamais de charger.
    private const val PRELOAD_SAFETY_TIMEOUT_MS = 30_000L

    /// Construit à l'avance [count] `WebView` vierges. Idempotent : si le
    /// pool contient déjà suffisamment d'instances, ne fait rien. Doit être
    /// appelé depuis le thread principal (redirige automatiquement sinon).
    @SuppressLint("SetJavaScriptEnabled")
    fun warmUp(context: Context, count: Int) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { warmUp(context, count) }
            return
        }
        val appContext = context.applicationContext
        val missing = count - enginePool.size
        if (missing <= 0) return
        repeat(missing) {
            val webView = WebView(appContext)
            webView.settings.javaScriptEnabled = true
            webView.settings.domStorageEnabled = true
            webView.settings.cacheMode = WebSettings.LOAD_DEFAULT
            enginePool.addLast(webView)
        }
    }

    /// Retire et renvoie une `WebView` pré-construite du pool si
    /// disponible, sinon `null` (l'appelant doit alors construire une
    /// `WebView` normalement). Doit être appelé depuis le thread principal.
    fun acquireWarmedEngine(): WebView? {
        return enginePool.removeFirstOrNull()
    }

    /// Déclenche un préchargement réseau best-effort de [url] : les
    /// ressources récupérées iront dans le cache HTTP partagé, au bénéfice
    /// de la prochaine vraie Webview qui chargera cette URL. N'offre aucune
    /// garantie si le serveur envoie des en-têtes de cache restrictifs
    /// (`no-store`, etc.) — dans ce cas, cet appel n'a simplement aucun
    /// effet mesurable. Doit être appelé depuis le thread principal.
    @SuppressLint("SetJavaScriptEnabled")
    fun preloadUrl(context: Context, url: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { preloadUrl(context, url) }
            return
        }
        if (activePreloads.containsKey(url)) return // déjà en cours

        val appContext = context.applicationContext
        val webView = enginePool.removeFirstOrNull() ?: WebView(appContext).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
        }
        webView.settings.cacheMode = WebSettings.LOAD_DEFAULT

        val cleanupRunnable = Runnable { disposePreload(url) }

        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, finishedUrl: String) {
                // On laisse un court délai après le chargement principal
                // pour que les ressources chargées de façon asynchrone
                // (fetch/XHR différés, images lazy-load déclenchées par du
                // JS au chargement...) aient une chance d'atteindre le
                // cache avant destruction de l'instance.
                mainHandler.removeCallbacks(cleanupRunnable)
                mainHandler.postDelayed(cleanupRunnable, 2_000)
            }
        }

        activePreloads[url] = webView
        mainHandler.postDelayed(cleanupRunnable, PRELOAD_SAFETY_TIMEOUT_MS)
        webView.loadUrl(url)
    }

    private fun disposePreload(url: String) {
        val webView = activePreloads.remove(url) ?: return
        webView.webViewClient = WebViewClient()
        webView.stopLoading()
        webView.destroy()
    }

    /// Détruit toutes les instances en attente (pool moteur + préchargements
    /// en cours). Utile en tests, ou si l'app veut libérer explicitement la
    /// mémoire associée (ex. `onTrimMemory`).
    fun clear() {
        enginePool.forEach { it.destroy() }
        enginePool.clear()
        activePreloads.keys.toList().forEach { disposePreload(it) }
    }
}
