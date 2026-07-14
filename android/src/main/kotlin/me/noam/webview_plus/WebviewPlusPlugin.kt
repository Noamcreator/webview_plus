package me.noam.webview_plus

import android.app.Activity
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

    // Canal global (indépendant de chaque instance de Webview) permettant
    // au côté Dart de connaître l'API level Android au runtime, afin de
    // choisir entre `initSurfaceAndroidView` (Texture Layer Hybrid
    // Composition, nécessite API 23+) et les modes historiques
    // (`initExpensiveAndroidView` / Virtual Display) sur les appareils
    // plus anciens. Voir `webview_plus_widget.dart` (_getAndroidSdkInt).
    private var infoChannel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
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
            when (call.method) {
                "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                else -> result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        factory = null
        infoChannel?.setMethodCallHandler(null)
        infoChannel = null
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