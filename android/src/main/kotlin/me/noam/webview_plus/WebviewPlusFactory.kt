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
        return WebviewPlusPlatformView(
            context ?: appContext,
            messenger,
            viewId,
            creationParams
        )
    }
}
