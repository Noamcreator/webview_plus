#include "include/webview_plus/webview_plus_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "webview_plus_plugin.h"

void WebviewPlusPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  webview_plus::WebViewPlusPluginCApi::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
