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

// -- Mode intégré (recommandé) ----------------------------------------------
//
// Au lieu de capturer le WebKitWebView dans une texture (lent, et
// `FlPixelBufferTexture` est instable sur les moteurs récents : erreurs
// `glGetError 501`), le WebKitWebView est un VRAI widget GTK, enfant
// « overlay » placé SOUS la FlView. La FlView (fond transparent) est dessinée
// par dessus ; côté Dart, le widget Webview "perce" un trou transparent
// (`BlendMode.clear`) à son emplacement et indique son rectangle via
// `setRect`. Résultat : WebKit se dessine nativement (fluide, GPU), et les
// widgets Flutter (dialogs, barres, spinners) restent AU-DESSUS.
//
// Prérequis côté application (runner) : la FlView doit être un enfant
// OVERLAY d'un `GtkOverlay` (voir `my_application.cc` fourni). Sinon (c'est le
// cas des fenêtres secondaires créées par le moteur), repli automatique sur le
// mode texture. Forçage du repli : WEBVIEW_PLUS_LINUX_MODE=texture.
//
// `view` doit être la FlView qui AFFICHE le widget Dart (fenêtre principale
// ou secondaire) : voir `find_flutter_view` dans `linux_webview.cc`.
gboolean linux_texture_bridge_can_embed(FlView *view);
LinuxTextureBridge *linux_texture_bridge_new_embedded(WebKitWebView *web_view,
                                                      FlView *view);
gboolean linux_texture_bridge_is_embedded(LinuxTextureBridge *bridge);
// Marque la Webview comme active (focus interne WebKit), sans voler le focus
// clavier GTK de la FlView.
void linux_texture_bridge_request_focus(LinuxTextureBridge *bridge);
// Rectangle en pixels LOGIQUES, relatif à l'angle haut-gauche de la FlView.
void linux_texture_bridge_set_rect(LinuxTextureBridge *bridge, int x, int y,
                                   int width, int height);
// Visibilité pilotée par Dart : la Webview est masquée quand son widget n'est
// plus à l'écran (page recouverte par une autre route, etc.) et, à
// l'affichage, remontée AU-DESSUS des autres Webviews (mais sous la FlView).
void linux_texture_bridge_set_visible(LinuxTextureBridge *bridge,
                                      gboolean visible);
// Saisie de texte : quand un champ éditable de la page prend le focus, la
// Webview reçoit le VRAI focus clavier GTK (IME, touches mortes, AltGr...) ;
// quand il le perd, le focus retourne à la FlView (clavier Flutter).
void linux_texture_bridge_set_text_focus(LinuxTextureBridge *bridge,
                                         gboolean on);
gboolean linux_texture_bridge_has_text_focus(LinuxTextureBridge *bridge);
// À appeler quand WebKit affiche son menu contextuel natif : le relâchement
// (synthétique) du clic droit qui suit est alors absorbé, pour ne pas
// activer un élément du menu par erreur.
void linux_texture_bridge_note_context_menu(LinuxTextureBridge *bridge);

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
