package me.noam.webview_plus

import android.annotation.SuppressLint
import android.content.Context
import android.content.MutableContextWrapper
import android.view.ContextThemeWrapper
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
///
/// 3. `preloadedPages` (voir [preloadDocument] / [acquirePreloaded]) : une
///    `WebviewPlusPlatformView` COMPLÈTE (réglages, ponts JS, CSS initial)
///    créée détachée et qui charge déjà la page demandée. Son
///    `WebviewPlusEventChannel` garde les événements jusqu'à ce qu'un
///    `WebviewWidget` Dart de mêmes paramètres l'adopte (`attach`) et
///    signale `ready` : la page (HTML + centaines de Ko de JS analysés)
///    est alors déjà prête, ce qui rend l'ouverture quasi instantanée. Une
///    instance de remplacement est rechargée en arrière-plan ensuite.
object WebviewPlusPreloader {

    private val mainHandler = Handler(Looper.getMainLooper())

    private val enginePool = ArrayDeque<WebView>()
    private val activePreloads = mutableMapOf<String, WebView>()

    // Mémorisés lors du premier `warmUp`, pour pouvoir réapprovisionner le
    // pool tout seul depuis `acquireWarmedEngine` sans que l'appelant Dart
    // ait besoin de rappeler `warmUp` à chaque fois qu'une WebView est
    // consommée. Sans ça, seul le tout premier document ouvert dans la
    // session bénéficie d'une WebView pré-chauffée : le pool, rempli une
    // seule fois au démarrage avec `count: 1`, reste ensuite vide pour
    // toujours et chaque document suivant repart d'un `WebView(context)`
    // froid.
    private var appContextRef: Context? = null
    private var targetPoolSize: Int = 0

    // Pages préchargées (voir 3.) et paramètres de la dernière demande,
    // gardés pour recharger une instance après chaque adoption.
    private val preloadedPages = ArrayList<WebviewPlusPlatformView>()
    private var lastPreloadParams: Map<String, Any?>? = null
    private const val PRELOAD_REFILL_DELAY_MS = 1_000L

    /// WebView dont le Context est un `MutableContextWrapper` : rebranché
    /// sur l'Activité à l'adoption (voir `WebviewPlusPlatformView`), ce qui
    /// rétablit thème de sélection, dialogues et IME qu'une WebView créée
    /// avec le seul Context applicatif ne peut pas avoir.
    @SuppressLint("SetJavaScriptEnabled")
    private fun newDetachedWebView(appContext: Context): WebView {
        val wrapper = MutableContextWrapper(
            ContextThemeWrapper(appContext, R.style.WebviewPlusSelectionTheme)
        )
        val webView = WebView(wrapper)
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        webView.settings.cacheMode = WebSettings.LOAD_DEFAULT
        return webView
    }

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
        appContextRef = appContext
        targetPoolSize = maxOf(targetPoolSize, count)

        val missing = count - enginePool.size
        if (missing <= 0) return
        repeat(missing) {
            enginePool.addLast(newDetachedWebView(appContext))
        }
    }

    /// Retire et renvoie une `WebView` pré-construite du pool si
    /// disponible, sinon `null` (l'appelant doit alors construire une
    /// `WebView` normalement). Doit être appelé depuis le thread principal.
    ///
    /// Reconstruit aussitôt une WebView de remplacement en arrière-plan
    /// (idle, hors du chemin critique de l'ouverture en cours) pour que le
    /// pool reste à `targetPoolSize` : le document suivant profite lui
    /// aussi d'une instance pré-chauffée, pas seulement le premier.
    fun acquireWarmedEngine(): WebView? {
        val engine = enginePool.removeFirstOrNull()
        if (engine != null) {
            scheduleRefill()
        }
        return engine
    }

    private fun scheduleRefill() {
        val context = appContextRef ?: return
        if (enginePool.size >= targetPoolSize) return
        // `post` (et non `postDelayed`) : on laisse simplement passer la
        // frame en cours (celle qui affiche le document qui vient de
        // consommer une WebView du pool) avant de reconstruire, pour ne
        // jamais entrer en concurrence avec elle sur le thread principal.
        mainHandler.post { warmUp(context, targetPoolSize) }
    }

    /// Crée une page préchargée (voir 3. dans la doc de l'objet). [params]
    /// est exactement la `Map` de création que Dart passerait à une vue
    /// native (dont `preloadKey`). Idempotent par `preloadKey`. Thread
    /// principal (redirige sinon).
    fun preloadDocument(context: Context, params: Map<String, Any?>) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { preloadDocument(context, params) }
            return
        }
        val key = params["preloadKey"] as? String ?: return
        val appContext = context.applicationContext
        appContextRef = appContext
        lastPreloadParams = params
        if (preloadedPages.any { it.preloadKey == key }) return
        // Une seule page préchargée par clé suffit ; on borne le total pour
        // ne pas accumuler de Webviews si les paramètres changent souvent
        // (ex. bascule clair/sombre) : la plus ancienne est détruite.
        while (preloadedPages.size >= 2) {
            preloadedPages.removeAt(0).dispose()
        }
        val webView = enginePool.removeFirstOrNull() ?: newDetachedWebView(appContext)
        preloadedPages.add(
            WebviewPlusPlatformView(appContext, null, -1, params, webView)
        )
    }

    /// Retire et renvoie la page préchargée de clé [key], ou `null`.
    /// Planifie le rechargement d'une instance équivalente pour le document
    /// suivant, hors du chemin critique de l'ouverture en cours.
    fun acquirePreloaded(key: String): WebviewPlusPlatformView? {
        val index = preloadedPages.indexOfFirst { it.preloadKey == key }
        if (index < 0) return null
        val page = preloadedPages.removeAt(index)
        val context = appContextRef
        val params = lastPreloadParams
        if (context != null && params != null) {
            mainHandler.postDelayed(
                { preloadDocument(context, params) },
                PRELOAD_REFILL_DELAY_MS
            )
        }
        return page
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
        preloadedPages.forEach { it.dispose() }
        preloadedPages.clear()
        lastPreloadParams = null
        enginePool.forEach { it.destroy() }
        enginePool.clear()
        activePreloads.keys.toList().forEach { disposePreload(it) }
    }
}