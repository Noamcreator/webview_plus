#include "rendering/texture_bridge_linux.h"

#include <cstring>
#include <mutex>

// ATTENTION — NON COMPILÉ NI TESTÉ ICI : cet environnement ne dispose pas
// des headers de développement GTK3/WebKitGTK ni du SDK Flutter Linux
// (`flutter_linux/*.h`), donc ce fichier n'a pas pu être passé au
// compilateur. Corrige au besoin en le compilant chez toi.
//
// -- Historique : pourquoi pas un GtkOffscreenWindow ? --------------------
// Une première version hébergeait le WebKitWebView dans un
// `GtkOffscreenWindow`. Ça compile, mais ça plante à l'exécution
// ("drawable is not a native X11 window", assertions GDK_IS_WINDOW) :
// `GtkOffscreenWindow` fournit une `GdkWindow` de type `GDK_WINDOW_OFFSCREEN`
// qui n'est PAS une fenêtre X11 native. Or WebKitGTK n'est pas un simple
// widget de dessin : il pilote un vrai sous-processus web (WebProcess) et
// s'appuie en interne sur de vraies fenêtres/surfaces X11/EGL pour
// communiquer avec lui. De nombreux chemins internes de GTK/WebKit
// (positionnement de popups, tooltips, calcul de coordonnées écran, DnD…)
// appellent des fonctions X11 qui exigent une fenêtre native et plantent
// sinon. `GtkOffscreenWindow` est prévu pour des snapshots de widgets
// simples (boutons, labels...), pas pour héberger un widget aussi complexe
// que WebKitGTK.
//
// -- La technique retenue : vraie fenêtre, positionnée hors écran --------
// On utilise donc une VRAIE fenêtre GTK top-level (non décorée), mais
// déplacée à des coordonnées très négatives (hors de tout écran visible).
// C'est une fenêtre X11 native comme une autre : WebKitGTK y fonctionne
// normalement (y compris son sous-processus, son rendu, ses popups
// internes…). L'utilisateur ne la voit simplement jamais, parce qu'aucun
// moniteur ne couvre ces coordonnées.
// On en capture le contenu périodiquement via `gdk_pixbuf_get_from_window`
// (qui, lui, exige justement une fenêtre native — donc fonctionne ici,
// contrairement à l'offscreen), et on republie chaque frame comme
// `FlPixelBufferTexture`, exactement comme WebView2 est composé côté
// Windows via Windows.Graphics.Capture (`windows/rendering/texture_bridge.cc`).
//
// LIMITE CONNUE : ce positionnement par coordonnées négatives est une
// notion X11 (`gtk_window_move`) ; sous Wayland pur, un client ne peut pas
// positionner lui-même ses fenêtres top-level, cette technique ne
// fonctionnera donc pas telle quelle (il faudrait un protocole compositeur
// dédié, ex. wlr-layer-shell, hors périmètre de ce correctif). D'après ta
// trace d'erreur (`gdk/x11/gdkwindow-x11.c`), tu es actuellement sur le
// backend X11 (ou XWayland), donc ça s'applique directement à ton cas.

namespace {
constexpr int kOffscreenX = -10000;
constexpr int kOffscreenY = -10000;
constexpr guint kCaptureIntervalMs = 16;  // ~60 fps
}  // namespace

struct _LinuxTextureBridge {
  FlTextureRegistrar *registrar;
  FlPixelBufferTexture *texture;  // instance de WebviewPlusPixelBufferTexture
  WebKitWebView *web_view;
  GtkWidget *host_window;  // vraie fenêtre top-level, positionnée hors écran

  std::mutex frame_mutex;
  guchar *frame_data;  // RGBA, propriété du bridge
  int frame_width;
  int frame_height;

  guint capture_timeout_id;
  guint pressed_buttons_mask;  // GDK_BUTTONx_MASK combinés, boutons actuellement enfoncés
};

// -- Sous-classe GObject de FlPixelBufferTexture --------------------------
//
// `FlPixelBufferTexture` (flutter_linux) n'expose pas de constructeur à
// callback : c'est un type abstrait fait pour être dérivé (comme un widget
// GTK en C), avec une vfunc `copy_pixels` à surcharger dans la classe
// dérivée. On définit donc ici un petit type dédié qui porte juste un
// pointeur non-possédant vers le `LinuxTextureBridge` propriétaire, pour
// aller lire son dernier buffer capturé au moment où le moteur Flutter
// demande à peindre la texture.
G_DECLARE_FINAL_TYPE(WebviewPlusPixelBufferTexture,
                     webview_plus_pixel_buffer_texture, WEBVIEW_PLUS,
                     PIXEL_BUFFER_TEXTURE, FlPixelBufferTexture)

struct _WebviewPlusPixelBufferTexture {
  FlPixelBufferTexture parent_instance;
  LinuxTextureBridge *bridge;  // non possédé : le bridge possède la texture
};

G_DEFINE_TYPE(WebviewPlusPixelBufferTexture, webview_plus_pixel_buffer_texture,
             fl_pixel_buffer_texture_get_type())

static gboolean webview_plus_pixel_buffer_texture_copy_pixels(
    FlPixelBufferTexture *texture, const uint8_t **out_buffer,
    uint32_t *width, uint32_t *height, GError **error) {
  WebviewPlusPixelBufferTexture *self =
      WEBVIEW_PLUS_PIXEL_BUFFER_TEXTURE(texture);
  LinuxTextureBridge *bridge = self->bridge;
  if (bridge == nullptr) {
    *out_buffer = nullptr;
    *width = 0;
    *height = 0;
    return FALSE;
  }

  std::lock_guard<std::mutex> lock(bridge->frame_mutex);
  if (bridge->frame_data == nullptr) {
    *out_buffer = nullptr;
    *width = 0;
    *height = 0;
    return FALSE;
  }
  *out_buffer = bridge->frame_data;
  *width = static_cast<uint32_t>(bridge->frame_width);
  *height = static_cast<uint32_t>(bridge->frame_height);
  return TRUE;
}

static void webview_plus_pixel_buffer_texture_class_init(
    WebviewPlusPixelBufferTextureClass *klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      webview_plus_pixel_buffer_texture_copy_pixels;
}

static void webview_plus_pixel_buffer_texture_init(
    WebviewPlusPixelBufferTexture *self) {
  self->bridge = nullptr;
}

static FlPixelBufferTexture *webview_plus_pixel_buffer_texture_new(
    LinuxTextureBridge *bridge) {
  WebviewPlusPixelBufferTexture *self = WEBVIEW_PLUS_PIXEL_BUFFER_TEXTURE(
      g_object_new(webview_plus_pixel_buffer_texture_get_type(), nullptr));
  self->bridge = bridge;
  return FL_PIXEL_BUFFER_TEXTURE(self);
}

namespace {

// Copie le dernier pixbuf capturé de `host_window` dans `bridge->frame_data`
// (RGBA) et notifie le moteur Flutter qu'une nouvelle frame est disponible.
// Rappelée en boucle (~60 fps) tant que le bridge est actif — plus simple et
// plus robuste ici qu'un hook sur un signal de dommage, qui n'existe pas de
// façon fiable pour une fenêtre X11 normale hébergeant un sous-processus web.
gboolean capture_frame(gpointer user_data) {
  LinuxTextureBridge *bridge = static_cast<LinuxTextureBridge *>(user_data);

  GdkWindow *gdk_window = gtk_widget_get_window(bridge->host_window);
  if (gdk_window == nullptr || !GDK_IS_WINDOW(gdk_window)) {
    return G_SOURCE_CONTINUE;
  }

  const int width = gdk_window_get_width(gdk_window);
  const int height = gdk_window_get_height(gdk_window);
  if (width <= 0 || height <= 0) {
    return G_SOURCE_CONTINUE;
  }

  GdkPixbuf *pixbuf =
      gdk_pixbuf_get_from_window(gdk_window, 0, 0, width, height);
  if (pixbuf == nullptr) {
    return G_SOURCE_CONTINUE;
  }

  const int pb_width = gdk_pixbuf_get_width(pixbuf);
  const int pb_height = gdk_pixbuf_get_height(pixbuf);
  const int rowstride = gdk_pixbuf_get_rowstride(pixbuf);
  const int n_channels = gdk_pixbuf_get_n_channels(pixbuf);
  const guchar *pixels = gdk_pixbuf_get_pixels(pixbuf);

  {
    std::lock_guard<std::mutex> lock(bridge->frame_mutex);
    if (bridge->frame_width != pb_width || bridge->frame_height != pb_height ||
        bridge->frame_data == nullptr) {
      g_free(bridge->frame_data);
      bridge->frame_data = static_cast<guchar *>(
          g_malloc(static_cast<gsize>(pb_width) * pb_height * 4));
      bridge->frame_width = pb_width;
      bridge->frame_height = pb_height;
    }
    // `gdk_pixbuf_get_from_window` renvoie du RGB (3 canaux) ou RGBA
    // (4 canaux) selon que la fenêtre a un canal alpha ; on normalise en
    // RGBA opaque dans les deux cas, ce que `FlPixelBufferTexture` attend.
    for (int y = 0; y < pb_height; y++) {
      const guchar *src_row = pixels + y * rowstride;
      guchar *dst_row = bridge->frame_data + y * pb_width * 4;
      for (int x = 0; x < pb_width; x++) {
        const guchar *src = src_row + x * n_channels;
        guchar *dst = dst_row + x * 4;
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        dst[3] = n_channels >= 4 ? src[3] : 0xFF;
      }
    }
  }

  g_object_unref(pixbuf);

  fl_texture_registrar_mark_texture_frame_available(bridge->registrar,
                                                     FL_TEXTURE(bridge->texture));
  return G_SOURCE_CONTINUE;
}

}  // namespace

LinuxTextureBridge *linux_texture_bridge_new(FlTextureRegistrar *registrar,
                                             WebKitWebView *web_view) {
  LinuxTextureBridge *bridge = g_new0(LinuxTextureBridge, 1);
  bridge->registrar = registrar;
  bridge->web_view = web_view;
  bridge->frame_data = nullptr;
  bridge->frame_width = 0;
  bridge->frame_height = 0;

  // Vraie fenêtre top-level, non décorée, jamais présentée au window
  // manager comme une fenêtre "normale" et positionnée hors de tout écran
  // visible — voir le commentaire en tête de fichier pour le pourquoi.
  bridge->host_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_decorated(GTK_WINDOW(bridge->host_window), FALSE);
  gtk_window_set_skip_taskbar_hint(GTK_WINDOW(bridge->host_window), TRUE);
  gtk_window_set_skip_pager_hint(GTK_WINDOW(bridge->host_window), TRUE);
  gtk_container_add(GTK_CONTAINER(bridge->host_window), GTK_WIDGET(web_view));
  gtk_window_move(GTK_WINDOW(bridge->host_window), kOffscreenX, kOffscreenY);

  // IMPORTANT : override-redirect fait sortir cette fenêtre de la gestion du
  // window manager (pas de reparenting, pas de politique de focus décidée
  // par le WM). Sans ça, `gtk_window_set_accept_focus(FALSE)` (utilisé dans
  // une version précédente) empêchait la fenêtre de jamais devenir "active"
  // aux yeux de GTK/WebKit, qui ignorait alors tout événement souris/clavier
  // synthétique — d'où une Webview purement visuelle, sans interaction
  // possible. En override-redirect, on peut au contraire forcer nous-mêmes
  // le focus réel juste avant chaque interaction (voir
  // `ensure_bridge_focus` plus bas), sans qu'aucun WM ne s'y oppose.
  // Doit être réalisée AVANT d'être positionnée en override-redirect
  // (propriété de la GdkWindow, pas du widget), donc avant `show_all`.
  gtk_widget_realize(bridge->host_window);
  gdk_window_set_override_redirect(gtk_widget_get_window(bridge->host_window),
                                   TRUE);
  gtk_widget_show_all(bridge->host_window);
  gtk_widget_realize(GTK_WIDGET(web_view));

  bridge->capture_timeout_id =
      g_timeout_add(kCaptureIntervalMs, capture_frame, bridge);

  bridge->texture = webview_plus_pixel_buffer_texture_new(bridge);

  return bridge;
}

int64_t linux_texture_bridge_start(LinuxTextureBridge *bridge) {
  fl_texture_registrar_register_texture(bridge->registrar, FL_TEXTURE(bridge->texture));
  return fl_texture_get_id(FL_TEXTURE(bridge->texture));
}

void linux_texture_bridge_resize(LinuxTextureBridge *bridge, int width, int height) {
  if (bridge == nullptr || width <= 0 || height <= 0) return;
  gtk_widget_set_size_request(GTK_WIDGET(bridge->web_view), width, height);
  gtk_window_resize(GTK_WINDOW(bridge->host_window), width, height);
  // Sans window manager (override-redirect), aucun "clampage" automatique
  // à l'écran ne devrait se produire, mais on réaffirme la position par
  // sécurité (coûte rien, évite toute mauvaise surprise selon les
  // compositeurs/pilotes).
  gtk_window_move(GTK_WINDOW(bridge->host_window), kOffscreenX, kOffscreenY);
}

namespace {

// Force le focus GTK interne sur le WebKitWebView (quel widget, dans cette
// fenêtre, reçoit les événements clavier). Purement une notion GTK — ça ne
// touche PAS le focus X11 réel de la fenêtre (voir la remarque ci-dessous),
// donc ça n'a aucun effet sur le reste de l'application Flutter.
//
// ATTENTION (historique) : une version précédente appelait aussi
// `gdk_window_focus()` ici, à CHAQUE événement (y compris les simples
// survols). Ça volait le focus clavier X11 réel de la fenêtre principale
// de l'application au profit de cette fenêtre hôte cachée — une fois volé,
// plus aucun widget Flutter (bouton, champ de texte...) ne pouvait
// recevoir de focus tant que l'utilisateur ne re-cliquait pas
// explicitement sur la fenêtre principale. D'où "tous les boutons Flutter
// deviennent intouchables après avoir touché la Webview". Le focus GTK
// interne (`gtk_widget_grab_focus`) suffit à faire fonctionner clic/clavier
// dans WebKit, sans ce problème.
void ensure_bridge_focus(LinuxTextureBridge *bridge) {
  GtkWidget *widget = GTK_WIDGET(bridge->web_view);
  GtkWindow *window = GTK_WINDOW(bridge->host_window);
  if (gtk_window_get_focus(window) != widget) {
    gtk_widget_grab_focus(widget);
  }
}

GdkWindow *bridge_input_window(LinuxTextureBridge *bridge) {
  GtkWidget *widget = GTK_WIDGET(bridge->web_view);
  if (!gtk_widget_get_realized(widget)) {
    gtk_widget_realize(widget);
  }
  return gtk_widget_get_window(widget);
}

// GDK_BUTTON_PRESS/RELEASE encodent le bouton via `event->button.button`
// (1=gauche, 2=milieu, 3=droit) — traduit depuis la convention Flutter
// utilisée côté Dart (`_kPrimaryMouseButton = 1`,
// `_kSecondaryMouseButton = 2`, `_kTertiaryMouseButton = 4`, voir
// `webview_plus_widget.dart`).
guint gdk_button_from_flutter(guint flutter_button) {
  switch (flutter_button) {
    case 2: return 3;   // secondaire (clic droit) -> GDK button 3
    case 4: return 2;   // tertiaire (molette cliquée) -> GDK button 2
    default: return 1;  // primaire (clic gauche) -> GDK button 1
  }
}

// Masque GDK correspondant à un bouton "actuellement enfoncé", à combiner
// dans `event->motion.state`/`event->button.state` — indispensable pour
// que WebKit reconnaisse un déplacement souris bouton enfoncé comme un
// drag de sélection de texte (sans ce bit, chaque `GDK_MOTION_NOTIFY`
// semble n'être qu'un simple survol, donc aucune sélection ne démarre).
guint gdk_state_mask_for_button(guint gdk_button) {
  switch (gdk_button) {
    case 1: return GDK_BUTTON1_MASK;
    case 2: return GDK_BUTTON2_MASK;
    case 3: return GDK_BUTTON3_MASK;
    default: return 0;
  }
}

}  // namespace

void linux_texture_bridge_dispatch_pointer(LinuxTextureBridge *bridge,
                                           GdkEventType type, double x, double y,
                                           guint button, double scroll_dx,
                                           double scroll_dy) {
  if (bridge == nullptr) return;
  GdkWindow *window = bridge_input_window(bridge);
  if (window == nullptr) return;

  GdkDisplay *display = gdk_window_get_display(window);
  GdkSeat *seat = gdk_display_get_default_seat(display);
  GdkDevice *pointer = seat != nullptr ? gdk_seat_get_pointer(seat) : nullptr;

  if (type == GDK_MOTION_NOTIFY) {
    GdkEvent *event = gdk_event_new(GDK_MOTION_NOTIFY);
    event->motion.window = static_cast<GdkWindow *>(g_object_ref(window));
    event->motion.send_event = TRUE;
    event->motion.time = GDK_CURRENT_TIME;
    event->motion.x = x;
    event->motion.y = y;
    event->motion.x_root = x;
    event->motion.y_root = y;
    // Indique à WebKit si un bouton est maintenu enfoncé pendant ce
    // déplacement (nécessaire pour reconnaître un drag de sélection, voir
    // `gdk_state_mask_for_button`).
    event->motion.state = bridge->pressed_buttons_mask;
    event->motion.device = pointer;
    gtk_main_do_event(event);
    gdk_event_free(event);
  } else if (type == GDK_BUTTON_PRESS || type == GDK_BUTTON_RELEASE ||
             type == GDK_2BUTTON_PRESS) {
    // Le focus GTK interne n'a besoin d'être (re)posé que sur un vrai clic,
    // pas à chaque survol — voir `ensure_bridge_focus`.
    ensure_bridge_focus(bridge);
    const guint gdk_button = gdk_button_from_flutter(button);
    const guint button_mask = gdk_state_mask_for_button(gdk_button);
    const gboolean is_press = (type == GDK_BUTTON_PRESS || type == GDK_2BUTTON_PRESS);
    GdkEvent *event = gdk_event_new(type);
    event->button.window = static_cast<GdkWindow *>(g_object_ref(window));
    event->button.send_event = TRUE;
    event->button.time = GDK_CURRENT_TIME;
    event->button.x = x;
    event->button.y = y;
    event->button.x_root = x;
    event->button.y_root = y;
    event->button.button = gdk_button;
    event->button.device = pointer;
    // Convention GDK : `state` reflète l'état des boutons AVANT ce press
    // (donc sans son propre bit), mais ENCORE enfoncés au moment de ce
    // release (donc avec son propre bit). On synchronise
    // `pressed_buttons_mask` juste après avoir construit l'événement.
    event->button.state = is_press
        ? bridge->pressed_buttons_mask
        : (bridge->pressed_buttons_mask | button_mask);
    gtk_main_do_event(event);
    gdk_event_free(event);

    if (is_press) {
      bridge->pressed_buttons_mask |= button_mask;
    } else {
      bridge->pressed_buttons_mask &= ~button_mask;
    }
  } else if (type == GDK_SCROLL) {
    GdkEvent *event = gdk_event_new(GDK_SCROLL);
    event->scroll.window = static_cast<GdkWindow *>(g_object_ref(window));
    event->scroll.send_event = TRUE;
    event->scroll.time = GDK_CURRENT_TIME;
    event->scroll.x = x;
    event->scroll.y = y;
    event->scroll.x_root = x;
    event->scroll.y_root = y;
    event->scroll.direction = GDK_SCROLL_SMOOTH;
    event->scroll.delta_x = scroll_dx;
    event->scroll.delta_y = scroll_dy;
    event->scroll.state = bridge->pressed_buttons_mask;
    event->scroll.device = pointer;
    gtk_main_do_event(event);
    gdk_event_free(event);
  }
}

void linux_texture_bridge_dispatch_key(LinuxTextureBridge *bridge, GdkEventType type,
                                       guint keyval, guint state,
                                       guint16 hardware_keycode) {
  if (bridge == nullptr) return;
  if (type != GDK_KEY_PRESS && type != GDK_KEY_RELEASE) return;

  GdkWindow *window = bridge_input_window(bridge);
  if (window == nullptr) return;
  ensure_bridge_focus(bridge);

  GdkEvent *event = gdk_event_new(type);
  event->key.window = static_cast<GdkWindow *>(g_object_ref(window));
  event->key.send_event = TRUE;
  event->key.time = GDK_CURRENT_TIME;
  event->key.keyval = keyval;
  event->key.state = state;
  event->key.hardware_keycode = hardware_keycode;
  event->key.length = 0;
  event->key.string = nullptr;
  event->key.group = 0;
  event->key.is_modifier = 0;
  gtk_main_do_event(event);
  gdk_event_free(event);
}

void linux_texture_bridge_stop(LinuxTextureBridge *bridge) {
  if (bridge == nullptr) return;
  if (bridge->capture_timeout_id != 0) {
    g_source_remove(bridge->capture_timeout_id);
    bridge->capture_timeout_id = 0;
  }
  fl_texture_registrar_unregister_texture(bridge->registrar, FL_TEXTURE(bridge->texture));
}

void linux_texture_bridge_free(LinuxTextureBridge *bridge) {
  if (bridge == nullptr) return;
  g_free(bridge->frame_data);
  if (bridge->host_window != nullptr) {
    // Détruit aussi `web_view`, qui lui est parenté : `destroy_linux_webview`
    // (voir `linux_webview.cc`) ne doit donc plus appeler
    // `gtk_widget_destroy` dessus séparément.
    gtk_widget_destroy(bridge->host_window);
  }
  if (bridge->texture != nullptr) {
    g_object_unref(bridge->texture);
  }
  g_free(bridge);
}
