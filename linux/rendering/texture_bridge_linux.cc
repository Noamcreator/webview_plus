#include "rendering/texture_bridge_linux.h"

#include <cstring>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

// -- Principe -------------------------------------------------------------
// WebKitGTK n'est pas un simple widget de dessin : il pilote un vrai
// sous-processus web et s'appuie sur de vraies fenêtres X11. Un
// `GtkOffscreenWindow` ne convient donc pas ("drawable is not a native X11
// window"). On héberge le WebKitWebView dans une VRAIE fenêtre GTK
// top-level, non décorée, en override-redirect et positionnée hors de tout
// écran. On en capture le contenu via `gdk_pixbuf_get_from_window` et on le
// republie comme `FlPixelBufferTexture`, comme WebView2 est composé côté
// Windows (`windows/rendering/texture_bridge.cc`).
//
// LIMITE CONNUE : `gtk_window_move` / override-redirect sont des notions X11.
// Sous Wayland pur, la fenêtre hôte ne peut pas être cachée. Lancer
// l'application avec `GDK_BACKEND=x11` (XWayland) ou forcer le backend dans
// `main.cc` (voir le README / CHANGELOG).
//
// -- Corrections de robustesse (crash au lancement d'une page WebView) -----
// 1. Use-after-free du buffer de pixels : `copy_pixels` est appelée par le
//    thread raster de Flutter ; l'ancien code retournait un pointeur vers
//    un buffer que le thread principal pouvait `g_free` (redimensionnement)
//    pendant que le moteur le lisait. Désormais la texture possède DEUX
//    buffers : `frame_*` (écrit par le thread GTK sous verrou) et `out_*`
//    (copie privée au thread raster, stable jusqu'au prochain appel).
// 2. La texture ne référence plus le bridge (pointeur pendant après
//    `linux_texture_bridge_free`) : elle possède ses données.
// 3. Les erreurs X11 (BadMatch/BadWindow sur `XGetImage` pendant un
//    redimensionnement ou si la fenêtre n'est pas encore affichable) sont
//    piégées avec `gdk_x11_display_error_trap_*` au lieu de tuer tout le
//    processus (comportement par défaut de GDK).
// 4. Capture à la demande (signal "draw") plutôt que 60 fps permanents :
//    CPU ~0 quand la page ne bouge pas, rendu plus fluide quand elle
//    bouge, avec un rafraîchissement de sécurité toutes les 250 ms.

namespace {
constexpr int kOffscreenX = -10000;
constexpr int kOffscreenY = -10000;
constexpr guint kCaptureIntervalMs = 16;        // ~60 fps max
constexpr gint64 kIdleRefreshUs = 250 * 1000;   // filet de sécurité
constexpr gint kDirtyFramesOnDraw = 3;
}  // namespace

struct _LinuxTextureBridge {
  FlTextureRegistrar *registrar;
  FlPixelBufferTexture *texture;  // référence possédée par le bridge
  WebKitWebView *web_view;
  GtkWidget *host_window;  // vraie fenêtre top-level, positionnée hors écran

  guint capture_timeout_id;
  gulong draw_handler_id;
  guint pressed_buttons_mask;  // GDK_BUTTONx_MASK combinés

  gint dirty_frames;       // > 0 : le contenu a changé, à recapturer
  gint64 last_capture_us;  // monotonic
  gboolean registered;
  gboolean stopped;
};

// -- Sous-classe GObject de FlPixelBufferTexture --------------------------
G_DECLARE_FINAL_TYPE(WebviewPlusPixelBufferTexture,
                     webview_plus_pixel_buffer_texture, WEBVIEW_PLUS,
                     PIXEL_BUFFER_TEXTURE, FlPixelBufferTexture)

struct _WebviewPlusPixelBufferTexture {
  FlPixelBufferTexture parent_instance;

  GMutex lock;
  // Écrit par le thread GTK (capture_frame), sous `lock`.
  guchar *frame_data;
  gsize frame_capacity;
  int frame_width;
  int frame_height;
  // Lu/écrit uniquement par le thread raster (copy_pixels).
  guchar *out_data;
  gsize out_capacity;
};

G_DEFINE_TYPE(WebviewPlusPixelBufferTexture, webview_plus_pixel_buffer_texture,
              fl_pixel_buffer_texture_get_type())

static gboolean webview_plus_pixel_buffer_texture_copy_pixels(
    FlPixelBufferTexture *texture, const uint8_t **out_buffer, uint32_t *width,
    uint32_t *height, GError **error) {
  (void)error;
  WebviewPlusPixelBufferTexture *self =
      WEBVIEW_PLUS_PIXEL_BUFFER_TEXTURE(texture);

  g_mutex_lock(&self->lock);
  if (self->frame_data == nullptr || self->frame_width <= 0 ||
      self->frame_height <= 0) {
    g_mutex_unlock(&self->lock);
    *out_buffer = nullptr;
    *width = 0;
    *height = 0;
    return FALSE;
  }
  const gsize size =
      static_cast<gsize>(self->frame_width) * self->frame_height * 4;
  if (self->out_capacity < size) {
    g_free(self->out_data);
    self->out_data = static_cast<guchar *>(g_malloc(size));
    self->out_capacity = size;
  }
  memcpy(self->out_data, self->frame_data, size);
  *width = static_cast<uint32_t>(self->frame_width);
  *height = static_cast<uint32_t>(self->frame_height);
  g_mutex_unlock(&self->lock);

  // `out_data` n'est modifié que par le prochain appel à copy_pixels (même
  // thread), donc stable pendant que le moteur l'envoie au GPU.
  *out_buffer = self->out_data;
  return TRUE;
}

static void webview_plus_pixel_buffer_texture_finalize(GObject *object) {
  WebviewPlusPixelBufferTexture *self =
      WEBVIEW_PLUS_PIXEL_BUFFER_TEXTURE(object);
  g_free(self->frame_data);
  g_free(self->out_data);
  g_mutex_clear(&self->lock);
  G_OBJECT_CLASS(webview_plus_pixel_buffer_texture_parent_class)
      ->finalize(object);
}

static void webview_plus_pixel_buffer_texture_class_init(
    WebviewPlusPixelBufferTextureClass *klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      webview_plus_pixel_buffer_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->finalize = webview_plus_pixel_buffer_texture_finalize;
}

static void webview_plus_pixel_buffer_texture_init(
    WebviewPlusPixelBufferTexture *self) {
  g_mutex_init(&self->lock);
}

static FlPixelBufferTexture *webview_plus_pixel_buffer_texture_new() {
  return FL_PIXEL_BUFFER_TEXTURE(
      g_object_new(webview_plus_pixel_buffer_texture_get_type(), nullptr));
}

// Copie [pixbuf] (RGB ou RGBA) dans le buffer de frame de la texture.
static void texture_publish_pixbuf(WebviewPlusPixelBufferTexture *self,
                                   GdkPixbuf *pixbuf) {
  const int w = gdk_pixbuf_get_width(pixbuf);
  const int h = gdk_pixbuf_get_height(pixbuf);
  const int rowstride = gdk_pixbuf_get_rowstride(pixbuf);
  const int n_channels = gdk_pixbuf_get_n_channels(pixbuf);
  const guchar *pixels = gdk_pixbuf_get_pixels(pixbuf);
  const int dst_rowstride = w * 4;
  const gsize size = static_cast<gsize>(dst_rowstride) * h;

  g_mutex_lock(&self->lock);
  if (self->frame_capacity < size) {
    g_free(self->frame_data);
    self->frame_data = static_cast<guchar *>(g_malloc(size));
    self->frame_capacity = size;
  }
  self->frame_width = w;
  self->frame_height = h;

  if (n_channels == 4 && rowstride == dst_rowstride) {
    memcpy(self->frame_data, pixels, size);
  } else {
    for (int y = 0; y < h; y++) {
      const guchar *src_row = pixels + static_cast<gsize>(y) * rowstride;
      guchar *dst_row = self->frame_data + static_cast<gsize>(y) * dst_rowstride;
      if (n_channels == 4) {
        memcpy(dst_row, src_row, static_cast<size_t>(dst_rowstride));
        continue;
      }
      for (int x = 0; x < w; x++) {
        const guchar *src = src_row + x * n_channels;
        guchar *dst = dst_row + x * 4;
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        dst[3] = 0xFF;
      }
    }
  }
  g_mutex_unlock(&self->lock);
}

namespace {

// Le contenu de la webview vient d'être (re)peint par GTK : à recapturer.
gboolean on_web_view_draw(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
  (void)widget;
  (void)cr;
  LinuxTextureBridge *bridge = static_cast<LinuxTextureBridge *>(user_data);
  bridge->dirty_frames = kDirtyFramesOnDraw;
  return FALSE;  // ne pas interrompre le dessin
}

gboolean capture_frame(gpointer user_data) {
  LinuxTextureBridge *bridge = static_cast<LinuxTextureBridge *>(user_data);
  if (bridge->stopped || bridge->host_window == nullptr) {
    return G_SOURCE_CONTINUE;
  }

  const gint64 now = g_get_monotonic_time();
  const gboolean idle_refresh = (now - bridge->last_capture_us) >= kIdleRefreshUs;
  if (bridge->dirty_frames <= 0 && !idle_refresh) {
    return G_SOURCE_CONTINUE;
  }

  GdkWindow *gdk_window = gtk_widget_get_window(bridge->host_window);
  if (gdk_window == nullptr || !GDK_IS_WINDOW(gdk_window) ||
      !gdk_window_is_visible(gdk_window)) {
    return G_SOURCE_CONTINUE;
  }

  const int width = gdk_window_get_width(gdk_window);
  const int height = gdk_window_get_height(gdk_window);
  if (width <= 0 || height <= 0) {
    return G_SOURCE_CONTINUE;
  }

  GdkDisplay *display = gdk_window_get_display(gdk_window);
#ifdef GDK_WINDOWING_X11
  const gboolean is_x11 = GDK_IS_X11_DISPLAY(display);
  if (is_x11) {
    gdk_x11_display_error_trap_push(display);
  }
#endif

  GdkPixbuf *pixbuf = gdk_pixbuf_get_from_window(gdk_window, 0, 0, width, height);

#ifdef GDK_WINDOWING_X11
  if (is_x11 && gdk_x11_display_error_trap_pop(display) != 0) {
    // BadMatch/BadWindow : fenêtre pas (encore) capturable. On réessaie à
    // la prochaine itération au lieu de faire tomber l'application.
    if (pixbuf != nullptr) {
      g_object_unref(pixbuf);
      pixbuf = nullptr;
    }
  }
#else
  (void)display;
#endif

  if (pixbuf == nullptr) {
    return G_SOURCE_CONTINUE;
  }

  texture_publish_pixbuf(WEBVIEW_PLUS_PIXEL_BUFFER_TEXTURE(bridge->texture),
                         pixbuf);
  g_object_unref(pixbuf);

  bridge->last_capture_us = now;
  if (bridge->dirty_frames > 0) {
    bridge->dirty_frames--;
  }
  if (bridge->registered) {
    fl_texture_registrar_mark_texture_frame_available(
        bridge->registrar, FL_TEXTURE(bridge->texture));
  }
  return G_SOURCE_CONTINUE;
}

}  // namespace

LinuxTextureBridge *linux_texture_bridge_new(FlTextureRegistrar *registrar,
                                             WebKitWebView *web_view) {
  LinuxTextureBridge *bridge = g_new0(LinuxTextureBridge, 1);
  bridge->registrar = registrar;
  bridge->web_view = web_view;
  bridge->dirty_frames = 10;
  bridge->texture = webview_plus_pixel_buffer_texture_new();

#ifdef GDK_WINDOWING_X11
  GdkDisplay *default_display = gdk_display_get_default();
  if (default_display != nullptr && !GDK_IS_X11_DISPLAY(default_display)) {
    g_warning(
        "webview_plus: backend GDK non-X11 détecté (Wayland ?). La fenêtre "
        "hôte hors écran ne peut pas être cachée sous Wayland : lancez "
        "l'application avec GDK_BACKEND=x11.");
  }
#endif

  bridge->host_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_decorated(GTK_WINDOW(bridge->host_window), FALSE);
  gtk_window_set_skip_taskbar_hint(GTK_WINDOW(bridge->host_window), TRUE);
  gtk_window_set_skip_pager_hint(GTK_WINDOW(bridge->host_window), TRUE);
  gtk_container_add(GTK_CONTAINER(bridge->host_window), GTK_WIDGET(web_view));
  gtk_window_move(GTK_WINDOW(bridge->host_window), kOffscreenX, kOffscreenY);

  // override-redirect : hors gestion du window manager (pas de focus/
  // reparenting imposé). Doit être posé après `realize` et avant `show_all`.
  gtk_widget_realize(bridge->host_window);
  gdk_window_set_override_redirect(gtk_widget_get_window(bridge->host_window),
                                   TRUE);
  gtk_widget_show_all(bridge->host_window);
  gtk_widget_realize(GTK_WIDGET(web_view));

  bridge->draw_handler_id = g_signal_connect_after(
      web_view, "draw", G_CALLBACK(on_web_view_draw), bridge);
  bridge->capture_timeout_id =
      g_timeout_add(kCaptureIntervalMs, capture_frame, bridge);

  return bridge;
}

int64_t linux_texture_bridge_start(LinuxTextureBridge *bridge) {
  fl_texture_registrar_register_texture(bridge->registrar,
                                        FL_TEXTURE(bridge->texture));
  bridge->registered = TRUE;
  return fl_texture_get_id(FL_TEXTURE(bridge->texture));
}

void linux_texture_bridge_resize(LinuxTextureBridge *bridge, int width, int height) {
  if (bridge == nullptr || bridge->stopped || width <= 0 || height <= 0) return;
  gtk_widget_set_size_request(GTK_WIDGET(bridge->web_view), width, height);
  gtk_window_resize(GTK_WINDOW(bridge->host_window), width, height);
  gtk_window_move(GTK_WINDOW(bridge->host_window), kOffscreenX, kOffscreenY);
  bridge->dirty_frames = 10;  // forcer une recapture à la nouvelle taille
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
  if (bridge == nullptr || bridge->stopped) return;
  bridge->stopped = TRUE;
  if (bridge->capture_timeout_id != 0) {
    g_source_remove(bridge->capture_timeout_id);
    bridge->capture_timeout_id = 0;
  }
  if (bridge->draw_handler_id != 0 && bridge->web_view != nullptr) {
    g_signal_handler_disconnect(bridge->web_view, bridge->draw_handler_id);
    bridge->draw_handler_id = 0;
  }
  if (bridge->registered) {
    fl_texture_registrar_unregister_texture(bridge->registrar,
                                            FL_TEXTURE(bridge->texture));
    bridge->registered = FALSE;
  }
}

void linux_texture_bridge_free(LinuxTextureBridge *bridge) {
  if (bridge == nullptr) return;
  linux_texture_bridge_stop(bridge);  // idempotent
  if (bridge->host_window != nullptr) {
    // Détruit aussi `web_view`, qui lui est parenté.
    gtk_widget_destroy(bridge->host_window);
    bridge->host_window = nullptr;
    bridge->web_view = nullptr;
  }
  // Le moteur détient sa propre référence tant qu'il peut encore appeler
  // `copy_pixels` ; la texture possède ses buffers, aucun pointeur pendant.
  g_clear_object(&bridge->texture);
  g_free(bridge);
}
