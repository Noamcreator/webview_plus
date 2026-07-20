#ifndef webview_plus_PLUGIN_PRIVATE_H_
#define webview_plus_PLUGIN_PRIVATE_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#include "include/webview_plus/webview_plus_plugin.h"
#include "rendering/texture_bridge_linux.h"

// -- Plugin racine -----------------------------------------------------
//
// Enregistré une seule fois par moteur Flutter. Porte le canal racine
// (`plugins.noam.me/webview_plus_linux`), gère le cycle de vie
// (create/setSize/setCursorPos/setPointerButton/setScrollDelta/
// sendKeyEvent/dispose) et la table des Webviews actives.
//
// Chaque Webview n'est plus superposée en widget GTK natif au-dessus de la
// vue Flutter (ancien `GtkOverlay`, cf. historique git) : elle est rendue
// hors écran et republiée comme texture Flutter (voir
// `rendering/texture_bridge_linux.h`), exactement comme WebView2 est
// composé via Windows.Graphics.Capture côté Windows
// (`windows/rendering/texture_bridge.h`). Ceci permet à un `Dialog`/
// `Overlay` Flutter de recouvrir normalement la Webview, ce qui était
// impossible avec une fenêtre GTK externe toujours peinte au-dessus.
struct _WebviewPlusPlugin {
  GObject parent_instance;

  FlPluginRegistrar *registrar;
  FlMethodChannel *legacy_channel;   // "webview_plus" (getPlatformVersion)
  FlMethodChannel *root_channel;     // "plugins.noam.me/webview_plus_linux"
  GHashTable *webviews;              // viewId (gint64*) -> LinuxWebview*
};

// -- Instance de Webview -------------------------------------------------
//
// Une entrée par Webview créée depuis Dart. Porte son propre
// `WebKitWebView`, son propre `FlMethodChannel` (`webview_plus_$viewId`,
// même convention de nommage qu'Android/iOS/macOS), le pont texture qui
// l'héberge hors écran, et l'état nécessaire au pont JS <-> Dart ainsi
// qu'au menu contextuel.
typedef struct {
  WebviewPlusPlugin *plugin;
  gint64 view_id;

  WebKitUserContentManager *content_manager;
  WebKitWebView *web_view;
  FlMethodChannel *channel;

  // Pont d'hébergement hors écran + republication en texture Flutter (voir
  // `rendering/texture_bridge_linux.h`). Possède le GtkOffscreenWindow qui
  // parente `web_view`.
  LinuxTextureBridge *bridge;
  int64_t texture_id;

  gint frame_width;
  gint frame_height;

  // Dernière position pointeur connue (mise à jour par `setCursorPos`),
  // réutilisée pour synthétiser les événements bouton/molette qui, côté
  // Dart (voir `_buildLinuxWebview` dans `webview_plus_widget.dart`,
  // calqué sur `_buildWindowsWebview`), n'envoient que le delta/bouton
  // sans repasser la position à chaque fois.
  gdouble last_pointer_x;
  gdouble last_pointer_y;

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
