#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

// Le runner repose sur FlApplication (Flutter >= 3.38 / stable récent) : le
// moteur demande la fenêtre de CHAQUE vue (principale ET secondaires créées
// par l'API multi-fenêtres) via `create_window`, avant tout rendu.
struct _MyApplication {
  FlApplication parent_instance;
};

G_DEFINE_TYPE(MyApplication, my_application, fl_application_get_type())

// Implements FlApplication::create_window.
//
// webview_plus (mode intégré) : les Webviews sont de vrais widgets GTK
// ajoutés PAR LE PLUGIN comme enfants overlay SOUS la vue Flutter. La vue
// Flutter est dessinée par dessus avec un fond TRANSPARENT ; le widget Webview
// de Dart perce un trou à son emplacement. WebKit se dessine donc nativement
// (fluide) et les widgets Flutter (dialogs, barres, spinners) restent
// au-dessus. Fonctionne aussi sous Wayland.
//
// Cette structure doit être créée ICI, avant que la FlView soit réalisée :
// la réorganiser après coup corrompt le contexte OpenGL du moteur. C'est
// pourquoi les fenêtres secondaires doivent passer par ce même code.
//
// Contraintes :
//  - la FlView doit être un enfant OVERLAY (pas l'enfant principal) ;
//  - l'enfant principal (`backdrop`) peut être n'importe quel widget vide,
//    sans taille minimale (sinon la fenêtre ne pourrait plus rétrécir).
// Sans cette structure, le plugin retombe sur le mode texture (instable).
static GtkWindow* my_application_create_window(FlApplication* application,
                                               FlView* view) {
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    // Pas de titre explicite sur la header bar : elle affiche le titre de la
    // fenêtre, que Dart peut changer (fenêtres secondaires).
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  }
  gtk_window_set_title(window, "JW Life");
  gtk_window_set_default_size(window, 1280, 720);

  GtkWidget* overlay = gtk_overlay_new();
  GtkWidget* backdrop = gtk_fixed_new();
  gtk_container_add(GTK_CONTAINER(overlay), backdrop);  // tout en dessous
  gtk_widget_show(backdrop);

  GdkRGBA background_color = {0.0, 0.0, 0.0, 0.0};  // transparent
  fl_view_set_background_color(view, &background_color);
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay), GTK_WIDGET(view));  // dessus
  gtk_widget_show(overlay);
  gtk_container_add(GTK_CONTAINER(window), overlay);

  // Fond noir derrière la vue : c'est ce qu'on voit dans le « trou » d'une
  // Webview masquée brièvement (maximisation / plein écran), au lieu de la
  // couleur du thème GTK (blanc/gris = flash). Installé une seule fois.
  static gboolean css_installed = FALSE;
  if (!css_installed) {
    css_installed = TRUE;
    GtkCssProvider* css = gtk_css_provider_new();
    gtk_css_provider_load_from_data(
        css, "window { background-color: #000000; }", -1, nullptr);
    gtk_style_context_add_provider_for_screen(
        gdk_screen_get_default(), GTK_STYLE_PROVIDER(css),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);
  }

  return window;
}

// Implements FlApplication::register_plugins.
static void my_application_register_plugins(FlApplication* application,
                                            FlPluginRegistry* registry) {
  fl_register_plugins(registry);
}

static void my_application_class_init(MyApplicationClass* klass) {
  FL_APPLICATION_CLASS(klass)->create_window = my_application_create_window;
  FL_APPLICATION_CLASS(klass)->register_plugins =
      my_application_register_plugins;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
