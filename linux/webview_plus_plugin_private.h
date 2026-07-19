#ifndef webview_plus_PLUGIN_PRIVATE_H_
#define webview_plus_PLUGIN_PRIVATE_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#include "include/webview_plus/webview_plus_plugin.h"

// -- Plugin racine -----------------------------------------------------
//
// Enregistré une seule fois par moteur Flutter. Porte le canal racine
// (`plugins.noam.me/webview_plus_linux`), gère le cycle de vie
// (create/setFrame/dispose) et la table des Webviews actives, ainsi que
// le `GtkOverlay` dans lequel chaque Webview est superposée à la vue
// Flutter (voir `platform/flutter_view.cc`).
struct _WebviewPlusPlugin {
  GObject parent_instance;

  FlPluginRegistrar *registrar;
  FlMethodChannel *legacy_channel;   // "webview_plus" (getPlatformVersion)
  FlMethodChannel *root_channel;     // "plugins.noam.me/webview_plus_linux"
  GtkOverlay *overlay;
  GHashTable *webviews;              // viewId (gint64*) -> LinuxWebview*
};

// -- Instance de Webview -------------------------------------------------
//
// Une entrée par Webview créée depuis Dart. Porte son propre
// `WebKitWebView`, son propre `FlMethodChannel` (`webview_plus_$viewId`,
// même convention de nommage qu'Android/iOS/macOS) et l'état nécessaire au
// pont JS <-> Dart ainsi qu'au menu contextuel.
typedef struct {
  WebviewPlusPlugin *plugin;
  gint64 view_id;

  WebKitUserContentManager *content_manager;
  WebKitWebView *web_view;
  FlMethodChannel *channel;

  gint frame_x;
  gint frame_y;
  gint frame_width;
  gint frame_height;
  gboolean visible;

  gboolean disable_context_menu;
  gboolean disable_long_press_links;
  gchar *selection_css_color;  // ex: "rgba(255,0,0,0.4)", nullable
  gchar *selection_text_css_color;
  gboolean disable_printing;

  // Empêche de renvoyer `onNavigationRequest` pour les navigations
  // déclenchées nous-mêmes (loadUrl/reload/goBack/goForward/...), pour
  // éviter une boucle infinie. Cf. équivalent Android/iOS/macOS.
  gboolean is_navigating_internally;
} LinuxWebview;

// platform/flutter_view.cc
GtkOverlay *ensure_overlay(WebviewPlusPlugin *self);
void update_flutter_view_input_region(WebviewPlusPlugin *self);

// webview/linux_webview.cc
LinuxWebview *create_linux_webview(WebviewPlusPlugin *self, gint64 view_id,
                                   FlValue *creation_params);
void destroy_linux_webview(gpointer data);
void root_method_call_cb(FlMethodChannel *channel, FlMethodCall *method_call,
                         gpointer user_data);
void instance_method_call_cb(FlMethodChannel *channel,
                             FlMethodCall *method_call, gpointer user_data);
gchar *flutter_assets_path();

#endif  // webview_plus_PLUGIN_PRIVATE_H_
