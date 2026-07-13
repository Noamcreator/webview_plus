#include "webview/webview_internal.h"
#include "common/method_channel_utils.h"

#include <unistd.h>
#include <climits>
#include <cstring>

namespace {

constexpr const gchar *kInstanceKey = "webview_plus_instance";

LinuxWebview *webview_from_object(gpointer object) {
  return static_cast<LinuxWebview *>(
      g_object_get_data(G_OBJECT(object), kInstanceKey));
}

// Encode n'importe quelle FlValue en JSON via le codec JSON intégré à
// flutter_linux : bien plus fiable qu'une sérialisation manuelle, et
// utilisé aussi bien pour encoder les réponses natif -> JS que pour
// décoder les résultats JS -> Dart (voir `evaluate_javascript`,
// méthode "evaluateJavaScript" dans webview_method_handler.cc).
gchar *json_encode_value(FlValue *value) {
  g_autoptr(FlJsonMessageCodec) codec = fl_json_message_codec_new();
  g_autoptr(GError) error = nullptr;
  gchar *json = fl_json_message_codec_encode(
      codec, value != nullptr ? value : fl_value_new_null(), &error);
  return json != nullptr ? json : g_strdup("null");
}

gchar *json_encode_string(const gchar *s) {
  g_autoptr(FlValue) value = fl_value_new_string(s != nullptr ? s : "");
  return json_encode_value(value);
}

void invoke_method(LinuxWebview *webview, const gchar *method, FlValue *args) {
  fl_method_channel_invoke_method(webview->channel, method, args, nullptr,
                                  nullptr, nullptr);
}

// -- Pont JS <-> Dart -----------------------------------------------------
//
// Reproduit le protocole déjà utilisé par Android/iOS/macOS :
// `window.webview_plus.callHandler(name, ...args)` (résolu/rejeté de
// façon asynchrone via `onJavaScriptHandler`) et
// `window.WebviewPlusChannel.postMessage(msg)` (-> `onMessageReceived`).
typedef struct {
  LinuxWebview *webview;
  gchar *callback_id;
} JsHandlerContext;

static void js_handler_finished_cb(GObject *object, GAsyncResult *result,
                                   gpointer user_data) {
  JsHandlerContext *ctx = static_cast<JsHandlerContext *>(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response =
      fl_method_channel_invoke_method_finish(FL_METHOD_CHANNEL(object),
                                             result, &error);

  gchar *literal = nullptr;
  gboolean is_reject = FALSE;

  if (error != nullptr) {
    literal = json_encode_string(error->message);
    is_reject = TRUE;
  } else if (FL_IS_METHOD_ERROR_RESPONSE(response)) {
    literal = json_encode_string(fl_method_error_response_get_message(
        FL_METHOD_ERROR_RESPONSE(response)));
    is_reject = TRUE;
  } else if (!FL_IS_METHOD_SUCCESS_RESPONSE(response)) {
    // Réponse "not implemented" : aucun handler Dart de ce nom.
    literal = json_encode_string(
        "Aucun handler côté Dart n'a été enregistré pour ce nom "
        "(addJavaScriptHandler).");
    is_reject = TRUE;
  } else {
    literal = json_encode_value(fl_method_success_response_get_result(
        FL_METHOD_SUCCESS_RESPONSE(response)));
  }

  g_autofree gchar *script = g_strdup_printf(
      "window.webview_plus && window.webview_plus.%s('%s', %s);",
      is_reject ? "_rejectCallback" : "_resolveCallback", ctx->callback_id,
      literal);
  webkit_web_view_evaluate_javascript(ctx->webview->web_view, script, -1,
                                      nullptr, nullptr, nullptr, nullptr,
                                      nullptr);

  g_free(literal);
  g_free(ctx->callback_id);
  g_free(ctx);
}

static void js_handler_message_cb(WebKitUserContentManager *manager,
                                  WebKitJavascriptResult *js_result,
                                  gpointer user_data) {
  LinuxWebview *webview = static_cast<LinuxWebview *>(user_data);
  JSCValue *value = webkit_javascript_result_get_js_value(js_result);
  if (!jsc_value_is_object(value)) {
    return;
  }

  g_autoptr(JSCValue) handler_name_v =
      jsc_value_object_get_property(value, "handlerName");
  g_autoptr(JSCValue) args_v = jsc_value_object_get_property(value, "args");
  g_autoptr(JSCValue) callback_id_v =
      jsc_value_object_get_property(value, "callbackId");

  g_autofree gchar *handler_name = jsc_value_to_string(handler_name_v);
  g_autofree gchar *args_json = jsc_value_to_string(args_v);
  g_autofree gchar *callback_id = jsc_value_to_string(callback_id_v);
  if (handler_name == nullptr || callback_id == nullptr) {
    return;
  }

  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "handlerName",
                           fl_value_new_string(handler_name));
  fl_value_set_string_take(
      args, "args", fl_value_new_string(args_json != nullptr ? args_json : "[]"));

  JsHandlerContext *ctx = g_new0(JsHandlerContext, 1);
  ctx->webview = webview;
  ctx->callback_id = g_strdup(callback_id);

  fl_method_channel_invoke_method(webview->channel, "onJavaScriptHandler",
                                  args, nullptr, js_handler_finished_cb, ctx);
}

static void channel_message_cb(WebKitUserContentManager *manager,
                               WebKitJavascriptResult *js_result,
                               gpointer user_data) {
  LinuxWebview *webview = static_cast<LinuxWebview *>(user_data);
  JSCValue *value = webkit_javascript_result_get_js_value(js_result);
  g_autofree gchar *text = jsc_value_to_string(value);
  if (text == nullptr) {
    return;
  }
  g_autoptr(FlValue) args = fl_value_new_string(text);
  invoke_method(webview, "onMessageReceived", args);
}

// -- Navigation -------------------------------------------------------

static void navigation_request_finished_cb(GObject *object,
                                           GAsyncResult *result,
                                           gpointer user_data) {
  WebKitPolicyDecision *decision = WEBKIT_POLICY_DECISION(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response =
      fl_method_channel_invoke_method_finish(FL_METHOD_CHANNEL(object),
                                             result, &error);

  gboolean allow = TRUE;
  if (error == nullptr && FL_IS_METHOD_SUCCESS_RESPONSE(response)) {
    FlValue *value = fl_method_success_response_get_result(
        FL_METHOD_SUCCESS_RESPONSE(response));
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL) {
      allow = fl_value_get_bool(value);
    }
  }

  if (allow) {
    webkit_policy_decision_use(decision);
  } else {
    webkit_policy_decision_ignore(decision);
  }
  g_object_unref(decision);
}

static gboolean decide_policy_cb(WebKitWebview *widget,
                                 WebKitPolicyDecision *decision,
                                 WebKitPolicyDecisionType type,
                                 gpointer user_data) {
  if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION &&
      type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
    // Laisse WebKit gérer normalement les décisions de type "réponse"
    // (téléchargements, sous-ressources, etc.).
    return FALSE;
  }

  LinuxWebview *webview = static_cast<LinuxWebview *>(user_data);
  WebKitNavigationPolicyDecision *nav_decision =
      WEBKIT_NAVIGATION_POLICY_DECISION(decision);
  WebKitNavigationAction *action =
      webkit_navigation_policy_decision_get_navigation_action(nav_decision);
  WebKitURIRequest *request = webkit_navigation_action_get_request(action);
  const gchar *uri = webkit_uri_request_get_uri(request);

  if (webview->is_navigating_internally) {
    webview->is_navigating_internally = FALSE;
    if (type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION &&
        uri != nullptr) {
      webkit_web_view_load_uri(widget, uri);
      webkit_policy_decision_ignore(decision);
      return TRUE;
    }
    webkit_policy_decision_use(decision);
    return TRUE;
  }

  if (type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
    // WebKitGTK n'ouvre jamais de fenêtre de lui-même : sans ce
    // traitement, `target="_blank"` ou `window.open()` ne ferait
    // simplement rien. On charge donc la cible dans la même Webview,
    // à l'instar du `createWebviewWith` utilisé côté macOS.
    if (uri != nullptr && *uri != '\0') {
      webkit_web_view_load_uri(widget, uri);
    }
    webkit_policy_decision_ignore(decision);
    return TRUE;
  }

  if (uri == nullptr) {
    return FALSE;
  }

  g_object_ref(decision);
  g_autoptr(FlValue) args = fl_value_new_string(uri);
  fl_method_channel_invoke_method(webview->channel, "onNavigationRequest",
                                  args, nullptr,
                                  navigation_request_finished_cb, decision);
  return TRUE;
}

static void load_changed_cb(WebKitWebview *widget, WebKitLoadEvent load_event,
                            gpointer user_data) {
  LinuxWebview *webview = static_cast<LinuxWebview *>(user_data);
  const gchar *uri = webkit_web_view_get_uri(widget);
  g_autoptr(FlValue) args = fl_value_new_string(uri != nullptr ? uri : "");
  if (load_event == WEBKIT_LOAD_STARTED) {
    invoke_method(webview, "onLoadStart", args);
  } else if (load_event == WEBKIT_LOAD_FINISHED) {
    invoke_method(webview, "onLoadStop", args);
  }
}

static const gchar *error_description(GError *error) {
  return error != nullptr ? error->message : "Échec de la navigation.";
}

static void emit_load_error(LinuxWebview *webview, GError *error,
                            const gchar *failing_uri) {
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(
      args, "url", fl_value_new_string(failing_uri != nullptr ? failing_uri : ""));
  fl_value_set_string_take(args, "code",
                           fl_value_new_int(error != nullptr ? error->code : -1));
  fl_value_set_string_take(args, "description",
                           fl_value_new_string(error_description(error)));
  invoke_method(webview, "onReceivedError", args);
}

static gboolean load_failed_cb(WebKitWebview *widget,
                               WebKitLoadEvent load_event,
                               const gchar *failing_uri, GError *error,
                               gpointer user_data) {
  // Ignore l'annulation volontaire d'une navigation (ex: `loadUrl` appelé
  // pendant qu'un chargement précédent était encore en cours).
  if (error != nullptr && error->domain == webkit_network_error_quark() &&
      error->code == WEBKIT_NETWORK_ERROR_CANCELLED) {
    return FALSE;
  }
  emit_load_error(static_cast<LinuxWebview *>(user_data), error, failing_uri);
  return FALSE;
}

// -- Menu contextuel ----------------------------------------------------
//
// Les entrées de menu personnalisées (`ContextMenuItem`) et la
// désactivation individuelle des entrées par défaut
// (`disabledDefaultContextMenuItems`) sont réservées à Android/iOS : sur
// desktop, le clic droit ouvre le menu contextuel classique du navigateur
// (pas une barre de sélection tactile), donc ce plugin se contente ici de
// masquer entièrement le menu ou de bloquer les liens, comme avant.
static gboolean context_menu_cb(WebKitWebview *web_view,
                                WebKitContextMenu *context_menu,
                                GdkEvent *event,
                                WebKitHitTestResult *hit_test_result,
                                gpointer user_data) {
  LinuxWebview *webview = static_cast<LinuxWebview *>(user_data);
  if (webview->disable_context_menu) {
    return TRUE;  // Retourner TRUE sans toucher au menu = aucun menu affiché.
  }
  if (webview->disable_long_press_links &&
      webkit_hit_test_result_context_is_link(hit_test_result)) {
    return TRUE;
  }

  if (webview->disable_printing) {
    for (int i = webkit_context_menu_get_n_items(context_menu) - 1; i >= 0; --i) {
      WebKitContextMenuItem *item =
          webkit_context_menu_get_item_at_position(context_menu, i);
      if (item != nullptr &&
          webkit_context_menu_item_get_stock_action(item) ==
              WEBKIT_CONTEXT_MENU_ACTION_PRINT) {
        webkit_context_menu_remove(context_menu, item);
      }
    }
  }

  return FALSE;
}

// -- Impression (Ctrl+P / window.print()) --------------------------------
//
// Le raccourci clavier n'est pas intercepté par WebKitGTK lui-même : c'est
// l'appel à `window.print()` (déclenché par Ctrl+P dans la majorité des
// pages, ou par l'entrée "Imprimer" du menu contextuel, déjà filtrée
// ci-dessus) qui émet le signal "print". Le bloquer ici couvre donc les
// deux cas sans dépendre d'une capture clavier fragile au niveau widget.
static gboolean print_requested_cb(WebKitWebview *web_view,
                                   WebKitPrintOperation *print_operation,
                                   gpointer user_data) {
  LinuxWebview *webview = static_cast<LinuxWebview *>(user_data);
  return webview->disable_printing ? TRUE : FALSE;
}

}  // namespace


// -- Assets Flutter -------------------------------------------------------

gchar *flutter_assets_path() {
  gchar buffer[PATH_MAX];
  const ssize_t len = readlink("/proc/self/exe", buffer, sizeof(buffer) - 1);
  if (len <= 0) {
    return nullptr;
  }
  buffer[len] = '\0';
  g_autofree gchar *exe_dir = g_path_get_dirname(buffer);
  // Convention documentée par le moteur Flutter Linux : les assets sont
  // toujours à `data/flutter_assets` relativement à l'exécutable.
  return g_build_filename(exe_dir, "data", "flutter_assets", nullptr);
}

gchar *asset_uri(const gchar *asset_path) {
  g_autofree gchar *assets_dir = flutter_assets_path();
  if (assets_dir == nullptr || asset_path == nullptr) {
    return nullptr;
  }
  g_autofree gchar *full_path = g_build_filename(assets_dir, asset_path, nullptr);
  GError *error = nullptr;
  gchar *uri = g_filename_to_uri(full_path, nullptr, &error);
  if (error != nullptr) {
    g_clear_error(&error);
    return nullptr;
  }
  return uri;
}

void begin_navigation(LinuxWebview *webview, const gchar *uri) {
  webview->is_navigating_internally = TRUE;
  webkit_web_view_load_uri(webview->web_view, uri);
}

// -- Pont JS injecté au chargement de chaque page ------------------------

void apply_bridge_script(LinuxWebview *webview, const gchar *selection_css) {
  webkit_user_content_manager_remove_all_scripts(webview->content_manager);

  g_autofree gchar *css_block =
      selection_css != nullptr
          ? g_strdup_printf(
                "document.addEventListener('DOMContentLoaded',function(){"
                "var st=document.createElement('style');"
                "st.innerHTML='::selection{background:%s;}';"
                "(document.head||document.documentElement).appendChild(st);"
                "});",
                selection_css)
          : g_strdup("");

  g_autofree gchar *script = g_strdup_printf(
      "(function(){"
      "  if (window.webview_plus) return;"
      "  %s"
      "  var __fwCbId = 0;"
      "  var __fwCallbacks = {};"
      "  window.webview_plus = {"
      "    callHandler: function(handlerName) {"
      "      var args = Array.prototype.slice.call(arguments, 1);"
      "      var id = 'cb_' + (__fwCbId++);"
      "      return new Promise(function(resolve, reject) {"
      "        __fwCallbacks[id] = { resolve: resolve, reject: reject };"
      "        window.webkit.messageHandlers.WebviewPlusJsHandler.postMessage({"
      "          handlerName: handlerName, args: JSON.stringify(args), callbackId: id"
      "        });"
      "      });"
      "    },"
      "    _resolveCallback: function(id, result) {"
      "      var cb = __fwCallbacks[id];"
      "      if (cb) { cb.resolve(result); delete __fwCallbacks[id]; }"
      "    },"
      "    _rejectCallback: function(id, error) {"
      "      var cb = __fwCallbacks[id];"
      "      if (cb) { cb.reject(error); delete __fwCallbacks[id]; }"
      "    }"
      "  };"
      "  window.WebviewPlusChannel = {"
      "    postMessage: function(msg) {"
      "      window.webkit.messageHandlers.WebviewPlusChannel.postMessage(String(msg));"
      "    }"
      "  };"
      "})();",
      css_block);

  WebKitUserScript *user_script = webkit_user_script_new(
      script, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
      WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, nullptr, nullptr);
  webkit_user_content_manager_add_script(webview->content_manager, user_script);
  webkit_user_script_unref(user_script);
}

// -- Cycle de vie -----------------------------------------------------

void destroy_linux_webview(gpointer data) {
  LinuxWebview *webview = static_cast<LinuxWebview *>(data);
  if (webview == nullptr) {
    return;
  }
  if (webview->web_view != nullptr) {
    g_object_set_data(G_OBJECT(webview->web_view), kInstanceKey, nullptr);
    // `gtk_widget_destroy` détache le widget de son parent (l'overlay) et
    // libère la référence que le conteneur détenait ; celle prise via
    // `g_object_ref_sink` à la création (voir `create_linux_webview`)
    // doit être relâchée séparément ici, sans quoi le WebKitWebview ne
    // serait jamais finalisé.
    gtk_widget_destroy(GTK_WIDGET(webview->web_view));
    g_object_unref(webview->web_view);
  }
  g_clear_object(&webview->channel);
  g_clear_object(&webview->content_manager);
  g_free(webview->selection_css_color);
  g_free(webview);
}

LinuxWebview *create_linux_webview(WebviewPlusPlugin *self, gint64 view_id,
                                   FlValue *creation_params) {
  GtkOverlay *overlay = ensure_overlay(self);
  if (overlay == nullptr) {
    return nullptr;
  }

  LinuxWebview *webview = g_new0(LinuxWebview, 1);
  webview->plugin = self;
  webview->view_id = view_id;
  webview->content_manager = webkit_user_content_manager_new();
  webview->web_view = WEBKIT_WEB_VIEW(
      webkit_web_view_new_with_user_content_manager(webview->content_manager));
  g_object_set_data(G_OBJECT(webview->web_view), kInstanceKey, webview);
  g_object_ref_sink(webview->web_view);

  g_autofree gchar *channel_name = g_strdup_printf("webview_plus_%" G_GINT64_FORMAT, view_id);
  webview->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(self->registrar), channel_name,
      FL_METHOD_CODEC(fl_standard_method_codec_new()));
  fl_method_channel_set_method_call_handler(
      webview->channel, instance_method_call_cb, webview, nullptr);

  FlValue *settings = map_lookup(creation_params, "initialSettings");

  WebKitSettings *webkit_settings = webkit_web_view_get_settings(webview->web_view);
  webkit_settings_set_enable_javascript(
      webkit_settings, map_lookup_bool(settings, "javaScriptEnabled", TRUE));
  if (const gchar *user_agent = map_lookup_string(settings, "userAgent")) {
    webkit_settings_set_user_agent(webkit_settings, user_agent);
  }
  if (map_lookup_bool(settings, "isInspectable", FALSE)) {
    webkit_settings_set_enable_developer_extras(webkit_settings, TRUE);
  }

  if (map_lookup_bool(settings, "transparentBackground", FALSE)) {
    GdkRGBA transparent = {0, 0, 0, 0};
    webkit_web_view_set_background_color(webview->web_view, &transparent);
  }

  webview->disable_context_menu =
      map_lookup_bool(settings, "disableContextMenu", FALSE);
  webview->disable_long_press_links =
      map_lookup_bool(settings, "disableLongPressContextMenuOnLinks", FALSE);
  webview->disable_printing = map_lookup_bool(settings, "disablePrinting", FALSE);

  gint64 selection_color = map_lookup_int(settings, "selectionHandleColor", 0);
  if (selection_color != 0) {
    const gint a = (selection_color >> 24) & 0xFF;
    const gint r = (selection_color >> 16) & 0xFF;
    const gint g = (selection_color >> 8) & 0xFF;
    const gint b = selection_color & 0xFF;
    webview->selection_css_color =
        g_strdup_printf("rgba(%d,%d,%d,%.3f)", r, g, b, a / 255.0);
  }

  apply_bridge_script(webview, webview->selection_css_color);

  webkit_user_content_manager_register_script_message_handler(
      webview->content_manager, "WebviewPlusChannel");
  webkit_user_content_manager_register_script_message_handler(
      webview->content_manager, "WebviewPlusJsHandler");
  g_signal_connect(webview->content_manager,
                   "script-message-received::WebviewPlusChannel",
                   G_CALLBACK(channel_message_cb), webview);
  g_signal_connect(webview->content_manager,
                   "script-message-received::WebviewPlusJsHandler",
                   G_CALLBACK(js_handler_message_cb), webview);

  g_signal_connect(webview->web_view, "decide-policy",
                   G_CALLBACK(decide_policy_cb), webview);
  g_signal_connect(webview->web_view, "load-changed",
                   G_CALLBACK(load_changed_cb), webview);
  g_signal_connect(webview->web_view, "load-failed",
                   G_CALLBACK(load_failed_cb), webview);
  g_signal_connect(webview->web_view, "context-menu",
                   G_CALLBACK(context_menu_cb), webview);
  g_signal_connect(webview->web_view, "print",
                   G_CALLBACK(print_requested_cb), webview);

  gtk_widget_set_halign(GTK_WIDGET(webview->web_view), GTK_ALIGN_START);
  gtk_widget_set_valign(GTK_WIDGET(webview->web_view), GTK_ALIGN_START);
  gtk_widget_set_hexpand(GTK_WIDGET(webview->web_view), FALSE);
  gtk_widget_set_vexpand(GTK_WIDGET(webview->web_view), FALSE);
  gtk_widget_set_can_focus(GTK_WIDGET(webview->web_view), TRUE);
  gtk_widget_set_size_request(GTK_WIDGET(webview->web_view), 1, 1);
  gtk_widget_hide(GTK_WIDGET(webview->web_view));
  gtk_overlay_add_overlay(overlay, GTK_WIDGET(webview->web_view));
  gtk_overlay_set_overlay_pass_through(overlay, GTK_WIDGET(webview->web_view),
                                       FALSE);
  gtk_widget_show(GTK_WIDGET(webview->web_view));
  gtk_widget_hide(GTK_WIDGET(webview->web_view));

  const gchar *initial_asset = map_lookup_string(creation_params, "initialAsset");
  const gchar *initial_file = map_lookup_string(creation_params, "initialFile");
  const gchar *initial_url = map_lookup_string(creation_params, "initialUrl");
  if (initial_asset != nullptr) {
    g_autofree gchar *uri = asset_uri(initial_asset);
    if (uri != nullptr) begin_navigation(webview, uri);
  } else if (initial_file != nullptr) {
    if (g_str_has_prefix(initial_file, "http://") ||
        g_str_has_prefix(initial_file, "https://") ||
        g_str_has_prefix(initial_file, "file://")) {
      begin_navigation(webview, initial_file);
    } else {
      GError *error = nullptr;
      g_autofree gchar *uri = g_filename_to_uri(initial_file, nullptr, &error);
      if (error == nullptr) {
        begin_navigation(webview, uri);
      } else {
        g_clear_error(&error);
      }
    }
  } else if (initial_url != nullptr) {
    begin_navigation(webview, initial_url);
  }

  gint64 *key = g_new(gint64, 1);
  *key = view_id;
  g_hash_table_insert(self->webviews, key, webview);
  return webview;
}

// -- Canal racine -----------------------------------------------------

void root_method_call_cb(FlMethodChannel *channel, FlMethodCall *method_call,
                         gpointer user_data) {
  WebviewPlusPlugin *self = static_cast<WebviewPlusPlugin *>(user_data);
  const gchar *method = fl_method_call_get_name(method_call);
  FlValue *args = fl_method_call_get_args(method_call);

  if (strcmp(method, "create") == 0) {
    const gint64 view_id = map_lookup_int(args, "viewId", -1);
    if (view_id < 0) {
      respond(method_call,
              error_response("invalid_argument", "viewId manquant."));
      return;
    }
    LinuxWebview *webview = create_linux_webview(self, view_id, args);
    if (webview == nullptr) {
      respond(method_call,
              error_response("creation_error",
                             "Impossible de créer la Webview Linux : la vue "
                             "Flutter n'est pas encore disponible."));
      return;
    }
    respond(method_call, success_response());
    return;
  }

  const gint64 view_id = map_lookup_int(args, "viewId", -1);
  gint64 lookup_key = view_id;
  LinuxWebview *webview = view_id >= 0 ? static_cast<LinuxWebview *>(
                                             g_hash_table_lookup(self->webviews, &lookup_key))
                                       : nullptr;

  if (strcmp(method, "setFrame") == 0) {
    if (webview == nullptr) {
      respond(method_call, success_response());  // vue déjà détruite : no-op
      return;
    }
    GtkWidget *widget = GTK_WIDGET(webview->web_view);
    const double x = map_lookup_double(args, "x", 0);
    const double y = map_lookup_double(args, "y", 0);
    const double width = map_lookup_double(args, "width", 0);
    const double height = map_lookup_double(args, "height", 0);
    webview->frame_x = static_cast<gint>(x);
    webview->frame_y = static_cast<gint>(y);
    webview->frame_width = width > 0 ? static_cast<gint>(width) : 0;
    webview->frame_height = height > 0 ? static_cast<gint>(height) : 0;
    webview->visible = map_lookup_bool(args, "visible", TRUE) &&
                       webview->frame_width > 0 && webview->frame_height > 0;

    gtk_widget_set_margin_start(widget, webview->frame_x);
    gtk_widget_set_margin_top(widget, webview->frame_y);
    gtk_widget_set_size_request(widget, webview->frame_width,
                                webview->frame_height);
    if (webview->visible) {
      gtk_widget_show(widget);
    } else {
      gtk_widget_hide(widget);
    }
    update_flutter_view_input_region(self);
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "dispose") == 0) {
    if (webview != nullptr) {
      gint64 key_copy = view_id;
      g_hash_table_remove(self->webviews, &key_copy);  // -> destroy_linux_webview
      update_flutter_view_input_region(self);
    }
    respond(method_call, success_response());
    return;
  }

  respond(method_call,
          FL_METHOD_RESPONSE(fl_method_not_implemented_response_new()));
}
