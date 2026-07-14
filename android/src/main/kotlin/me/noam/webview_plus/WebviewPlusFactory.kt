package me.noam.webview_plus

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class WebviewPlusFactory(
    private val messenger: BinaryMessenger,
    private val appContext: Context
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val creationParams = args as? Map<String, Any?>
        val resolvedContext = context ?: appContext
        // Réutilise une WebView déjà construite par WebviewPlusPreloader.warmUp
        // si disponible : évite de repayer le coût d'initialisation du
        // moteur Chromium sur ce qui serait sinon la première Webview
        // visible de l'app. Aucune incidence fonctionnelle si le pool est
        // vide : on retombe simplement sur la construction normale, faite
        // à l'intérieur de WebviewPlusPlatformView.
        val preWarmedWebView = WebviewPlusPreloader.acquireWarmedEngine()
        return WebviewPlusPlatformView(
            resolvedContext,
            messenger,
            viewId,
            creationParams,
            preWarmedWebView
        )
    }
}
