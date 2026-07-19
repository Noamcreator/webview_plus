#include "include/webview_plus/webview_plus_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#include <cstring>

#ifndef WEBKIT_CONTEXT_MENU_ACTION_PRINT
#ifdef WEBKIT_CONTEXT_MENU_ACTION_PRINT_FRAME
#define WEBKIT_CONTEXT_MENU_ACTION_PRINT WEBKIT_CONTEXT_MENU_ACTION_PRINT_FRAME
#else
#define WEBKIT_CONTEXT_MENU_ACTION_PRINT 9999 // Valeur fallback si absente
#endif
#endif

#include "webview_plus_plugin_private.h"

#define webview_plus_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), webview_plus_plugin_get_type(), \
                              WebviewPlusPlugin))

G_DEFINE_TYPE(WebviewPlusPlugin, webview_plus_plugin, g_object_get_type())

// Canal historique conservé pour compatibilité (getPlatformVersion), à
// l'identique d'Android/iOS/macOS.
static void webview_plus_plugin_handle_method_call(
    WebviewPlusPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "getPlatformVersion") == 0) {
    struct utsname uname_data = {};
    uname(&uname_data);
    g_autofree gchar* version = g_strdup_printf("Linux %s", uname_data.version);
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_string(version)));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void legacy_method_call_cb(FlMethodChannel* channel,
                                  FlMethodCall* method_call,
                                  gpointer user_data) {
  webview_plus_plugin_handle_method_call(
      webview_plus_PLUGIN(user_data), method_call);
}

static void webview_plus_plugin_dispose(GObject* object) {
  WebviewPlusPlugin* self = webview_plus_PLUGIN(object);
  g_clear_object(&self->registrar);
  g_clear_object(&self->legacy_channel);
  g_clear_object(&self->root_channel);
  if (self->webviews != nullptr) {
    g_hash_table_destroy(self->webviews);
    self->webviews = nullptr;
  }
  G_OBJECT_CLASS(webview_plus_plugin_parent_class)->dispose(object);
}

static void webview_plus_plugin_class_init(WebviewPlusPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = webview_plus_plugin_dispose;
}

static void webview_plus_plugin_init(WebviewPlusPlugin* self) {
  self->overlay = nullptr;
  // Clé = gint64* (viewId choisi côté Dart, cf. webview_plus_widget.dart),
  // valeur détruite via `destroy_linux_webview` lorsqu'elle est retirée de
  // la table (dispose explicite ou destruction du plugin).
  self->webviews = g_hash_table_new_full(g_int64_hash, g_int64_equal, g_free,
                                         destroy_linux_webview);
}

void webview_plus_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  WebviewPlusPlugin* plugin = webview_plus_PLUGIN(
      g_object_new(webview_plus_plugin_get_type(), nullptr));

  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

  plugin->legacy_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "webview_plus",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->legacy_channel, legacy_method_call_cb, g_object_ref(plugin),
      g_object_unref);

  // Canal racine : cycle de vie des Webview (create/setFrame/dispose),
  // même convention de nommage que le pendant Windows
  // (`plugins.noam.me/webview_plus_windows`).
  plugin->root_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "plugins.noam.me/webview_plus_linux", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->root_channel, root_method_call_cb, g_object_ref(plugin),
      g_object_unref);

  g_object_unref(plugin);
}
