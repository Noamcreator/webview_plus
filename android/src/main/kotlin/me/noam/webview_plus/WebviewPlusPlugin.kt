package me.noam.webview_plus

import android.app.Activity
import android.content.Context
import android.os.Build
import android.view.ActionMode
import android.view.Window
import android.webkit.WebView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel

class WebviewPlusPlugin : FlutterPlugin, ActivityAware {

    private var factory: WebviewPlusFactory? = null
    private var appContext: Context? = null

    // Canal global (indépendant de chaque instance de Webview) permettant
    // au côté Dart de connaître l'API level Android au runtime, afin de
    // choisir entre `initSurfaceAndroidView` (Texture Layer Hybrid
    // Composition, nécessite API 23+) et les modes historiques
    // (`initExpensiveAndroidView` / Virtual Display) sur les appareils
    // plus anciens (voir `webview_plus_widget.dart`, `_getAndroidSdkInt`),
    // ainsi que le préchauffage/préchargement de Webview (voir
    // `WebviewPlusPreloader` côté natif et son pendant côté Dart dans
    // `webview_plus_controller.dart`).
    private var infoChannel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        factory = WebviewPlusFactory(
            binding.binaryMessenger,
            binding.applicationContext
        )
        binding.platformViewRegistry.registerViewFactory(
            "plugins.noam.me/webview_plus",
            factory!!
        )

        infoChannel = MethodChannel(binding.binaryMessenger, "plugins.noam.me/webview_plus_info")
        infoChannel?.setMethodCallHandler { call, result ->
            val ctx = appContext
            when (call.method) {
                "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                "warmUp" -> {
                    if (ctx == null) {
                        result.error("NO_CONTEXT", "Plugin non attaché", null)
                    } else {
                        val count = (call.argument<Int>("count") ?: 1).coerceIn(1, 5)
                        WebviewPlusPreloader.warmUp(ctx, count)
                        result.success(null)
                    }
                }
                "preloadUrl" -> {
                    val url = call.argument<String>("url")
                    if (ctx == null) {
                        result.error("NO_CONTEXT", "Plugin non attaché", null)
                    } else if (url == null) {
                        result.error("INVALID_ARGUMENT", "url manquante", null)
                    } else {
                        WebviewPlusPreloader.preloadUrl(ctx, url)
                        result.success(null)
                    }
                }
                // -- WebviewCacheManager (voir webview_plus_controller.dart) --
                //
                // `WebView` n'expose `clearCache`/`clearHistory`/`clearFormData`
                // qu'en tant que méthodes d'instance : on en crée une jetable,
                // le temps de l'appel, plutôt que d'exiger qu'une Webview soit
                // déjà affichée (contrairement à Windows, voir `g_default_profile`
                // côté C++).
                "clearCache" -> {
                    if (ctx == null) {
                        result.error("NO_CONTEXT", "Plugin non attaché", null)
                    } else {
                        val tmp = WebView(ctx)
                        tmp.clearCache(true)
                        tmp.destroy()
                        result.success(null)
                    }
                }
                "clearCookies" -> {
                    val cookieManager = android.webkit.CookieManager.getInstance()
                    cookieManager.removeAllCookies(null)
                    cookieManager.flush()
                    result.success(null)
                }
                "clearAllData" -> {
                    if (ctx == null) {
                        result.error("NO_CONTEXT", "Plugin non attaché", null)
                    } else {
                        val tmp = WebView(ctx)
                        tmp.clearCache(true)
                        tmp.clearHistory()
                        tmp.clearFormData()
                        tmp.destroy()
                        val cookieManager = android.webkit.CookieManager.getInstance()
                        cookieManager.removeAllCookies(null)
                        cookieManager.flush()
                        android.webkit.WebStorage.getInstance().deleteAllData()
                        result.success(null)
                    }
                }
                // Voir `WebviewPlusController.setWebContentsDebuggingEnabled` côté
                // Dart : API Android native, globale et immédiate, à la
                // différence de `WebviewSettings.isInspectable` (par instance).
                "setWebContentsDebuggingEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    WebView.setWebContentsDebuggingEnabled(enabled)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        factory = null
        infoChannel?.setMethodCallHandler(null)
        infoChannel = null
        appContext = null
        WebviewPlusPreloader.clear()
    }

    // -- ActivityAware --------------------------------------------------
    //
    // Nécessaire pour personnaliser le menu de sélection de texte natif
    // (`ActionMode`, la barre flottante copier/coller/tout sélectionner) :
    // contrairement au menu contextuel déclenché par appui long dans un
    // <div>, ce menu est piloté par le `Window.Callback` de l'Activity et
    // non par la `Webview` elle-même (voir `ActionModeWindowCallbackWrapper`).

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        installActionModeCallbackWrapper(binding.activity)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        installActionModeCallbackWrapper(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {}

    override fun onDetachedFromActivity() {}

    private fun installActionModeCallbackWrapper(activity: Activity) {
        val window = activity.window ?: return
        val current = window.callback
        if (current is ActionModeWindowCallbackWrapper) return
        window.callback = ActionModeWindowCallbackWrapper(window, current)
    }
}

/// Enrobe le `Window.Callback` existant de l'Activity hôte pour intercepter
/// `onActionModeStarted`, déclenché à chaque affichage du menu de sélection
/// de texte natif (copier/coller/tout sélectionner) au-dessus de n'importe
/// quelle `Webview`, y compris celles gérées par ce plugin.
///
/// Reste totalement transparent pour le reste de l'application : toutes les
/// autres méthodes de `Window.Callback` sont déléguées telles quelles via
/// `by original` (délégation d'interface Kotlin).
private class ActionModeWindowCallbackWrapper(
    private val window: Window,
    private val original: Window.Callback
) : Window.Callback by original {

    override fun onActionModeStarted(mode: ActionMode?) {
        original.onActionModeStarted(mode)
        val menu = mode?.menu ?: return
        // `ActionMode` n'expose pas directement la vue qui l'a démarré : la
        // vue actuellement focus est la façon la plus fiable de la
        // retrouver lorsqu'il s'agit du menu de sélection de texte.
        val focused = window.currentFocus as? WebView ?: return
        val platformView = WebviewPlusPlatformView.forWebview(focused) ?: return
        platformView.customizeSelectionActionMenu(mode, menu)
    }
}
