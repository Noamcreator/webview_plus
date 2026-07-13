#ifndef webview_plus_WEBVIEW_INTERNAL_H_
#define webview_plus_WEBVIEW_INTERNAL_H_

#include "webview_plus_plugin_private.h"

// linux_webview.cc
void apply_bridge_script(LinuxWebview *webview, const gchar *selection_css);
void begin_navigation(LinuxWebview *webview, const gchar *uri);
gchar *asset_uri(const gchar *asset_path);

// webview_method_handler.cc
void handle_instance_method_call(LinuxWebview *webview,
                                 FlMethodCall *method_call);

#endif  // webview_plus_WEBVIEW_INTERNAL_H_
