#ifndef webview_plus_TEXTURE_BRIDGE_LINUX_H_
#define webview_plus_TEXTURE_BRIDGE_LINUX_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

G_BEGIN_DECLS

// Équivalent Linux de `windows/rendering/texture_bridge.h` : au lieu de
// capturer WebView2 via Windows.Graphics.Capture dans une ID3D11Texture2D,
// on héberge le WebKitWebView dans une vraie fenêtre GTK top-level
// positionnée hors de l'écran visible (jamais un GtkOffscreenWindow, qui
// n'est pas une fenêtre X11 native et fait planter WebKitGTK — voir le
// commentaire en tête de `texture_bridge_linux.cc`), et on en capture
// périodiquement le contenu pour le republier comme FlPixelBufferTexture.
// Côté Dart, ceci permet d'utiliser un widget `Texture(textureId: ...)`
// normal, donc soumis au z-order Flutter (recouvrable par un Dialog, etc.)
// au lieu du GtkOverlay natif précédent qui restait toujours au-dessus.
//
// Comme le WebKitWebView ne reçoit plus jamais d'événements X11/Wayland
// réels (il n'est jamais mappé à l'écran), TOUT événement pointeur/clavier
// doit être synthétisé à partir des coordonnées/touches reçues depuis Dart
// (voir `linux_texture_bridge_dispatch_pointer/dispatch_key`) — c'est le
// pendant Linux de la traduction de coordonnées que WebView2 effectue déjà
// côté Windows en mode composition ("windowless").
typedef struct _LinuxTextureBridge LinuxTextureBridge;

// `registrar` : le FlTextureRegistrar du moteur
// (fl_plugin_registrar_get_texture_registrar).
// `web_view`  : la WebKitWebView à héberger hors écran. Doit avoir déjà été
// créée (webkit_web_view_new_with_user_content_manager) mais PAS encore
// parentée : ce constructeur la parente lui-même dans le GtkOffscreenWindow.
LinuxTextureBridge *linux_texture_bridge_new(FlTextureRegistrar *registrar,
                                             WebKitWebView *web_view);

// Enregistre la texture auprès du moteur et retourne son texture_id
// (à renvoyer à Dart dans la réponse de `create`, cf. `linux_webview.cc`).
int64_t linux_texture_bridge_start(LinuxTextureBridge *bridge);

// Redimensionne le GtkOffscreenWindow (donc le rendu WebKit) — appelé
// depuis `setSize` (remplace l'ancien `setFrame` positionnel).
void linux_texture_bridge_resize(LinuxTextureBridge *bridge, int width,
                                 int height);

// -- Entrée synthétique ---------------------------------------------------
//
// `type` : GDK_MOTION_NOTIFY (déplacement), GDK_BUTTON_PRESS/
// GDK_BUTTON_RELEASE (clic), ou GDK_SCROLL (molette, auquel cas
// `scroll_dx`/`scroll_dy` sont utilisés et `button` est ignoré).
// `x`/`y` sont en coordonnées locales au widget (0,0 = coin haut-gauche de
// la Webview), exactement comme `event.localPosition` côté
// `Listener`/`onPointerXxx` dans `webview_plus_widget.dart`.
void linux_texture_bridge_dispatch_pointer(LinuxTextureBridge *bridge,
                                           GdkEventType type, double x,
                                           double y, guint button,
                                           double scroll_dx, double scroll_dy);

// `type` : GDK_KEY_PRESS ou GDK_KEY_RELEASE. `keyval`/`state`/
// `hardware_keycode` proviennent du `KeyEvent` Flutter côté Dart (voir
// `sendKeyEvent` sur le canal `plugins.noam.me/webview_plus_linux`).
void linux_texture_bridge_dispatch_key(LinuxTextureBridge *bridge,
                                       GdkEventType type, guint keyval,
                                       guint state, guint16 hardware_keycode);

void linux_texture_bridge_stop(LinuxTextureBridge *bridge);
void linux_texture_bridge_free(LinuxTextureBridge *bridge);

G_END_DECLS

#endif  // webview_plus_TEXTURE_BRIDGE_LINUX_H_
