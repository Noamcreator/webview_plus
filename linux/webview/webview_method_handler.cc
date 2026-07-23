#include "webview/webview_internal.h"
#include "common/method_channel_utils.h"

#include <cstring>

namespace {

gchar *js_string_literal(const gchar *value) {
  g_autoptr(FlValue) v = fl_value_new_string(value != nullptr ? value : "");
  g_autoptr(FlJsonMessageCodec) codec = fl_json_message_codec_new();
  g_autoptr(GError) error = nullptr;
  gchar *json = fl_json_message_codec_encode(codec, v, &error);
  return json != nullptr ? json : g_strdup("\"\"");
}

void inject_script_from_url(WebKitWebView *web_view, const gchar *url) {
  g_autofree gchar *literal = js_string_literal(url);
  g_autofree gchar *js = g_strdup_printf(
      "(function(){var s=document.createElement('script');s.src=%s;"
      "(document.head||document.documentElement).appendChild(s);})();",
      literal);
  webkit_web_view_evaluate_javascript(web_view, js, -1, nullptr, nullptr,
                                      nullptr, nullptr, nullptr);
}

void inject_css_from_url(WebKitWebView *web_view, const gchar *url) {
  g_autofree gchar *literal = js_string_literal(url);
  g_autofree gchar *js = g_strdup_printf(
      "(function(){var l=document.createElement('link');l.rel='stylesheet';"
      "l.href=%s;(document.head||document.documentElement).appendChild(l);})();",
      literal);
  webkit_web_view_evaluate_javascript(web_view, js, -1, nullptr, nullptr,
                                      nullptr, nullptr, nullptr);
}

// -- evaluateJavascript --------------------------------------------------

void eval_finished_cb(GObject *object, GAsyncResult *result, gpointer user_data) {
  FlMethodCall *method_call = FL_METHOD_CALL(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(JSCValue) value = webkit_web_view_evaluate_javascript_finish(
      WEBKIT_WEB_VIEW(object), result, &error);

  if (error != nullptr) {
    respond(method_call, error_response("javascript_error", error->message));
    g_object_unref(method_call);
    return;
  }

  if (value == nullptr || jsc_value_is_null(value) || jsc_value_is_undefined(value)) {
    respond(method_call, success_response());
    g_object_unref(method_call);
    return;
  }

  // Sérialise en JSON puis redécode en FlValue via le codec JSON de
  // flutter_linux : on obtient un arbre de types Dart natifs
  // (bool/num/String/List/Map) exactement comme sur Android/iOS/macOS,
  // sans avoir à réimplémenter un mapping JSCValue -> FlValue à la main.
  g_autofree gchar *json = jsc_value_to_json(value, 0);
  if (json == nullptr) {
    respond(method_call, success_response());
    g_object_unref(method_call);
    return;
  }

  g_autoptr(FlJsonMessageCodec) codec = fl_json_message_codec_new();
  g_autoptr(GError) decode_error = nullptr;
  FlValue *decoded = fl_json_message_codec_decode(codec, json, &decode_error);
  respond(method_call, success_response(decoded));
  g_object_unref(method_call);
}

}  // namespace

void handle_instance_method_call(LinuxWebview *webview,
                                 FlMethodCall *method_call) {
  const gchar *method = fl_method_call_get_name(method_call);
  FlValue *args = fl_method_call_get_args(method_call);
  WebKitWebView *web_view = webview->web_view;

  if (strcmp(method, "loadUrl") == 0) {
    const gchar *url = map_lookup_string(args, "url");
    if (url == nullptr) {
      respond(method_call, error_response("invalid_argument", "url manquant."));
      return;
    }
    begin_navigation(webview, url);
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "loadFlutterAsset") == 0) {
    const gchar *asset_path = map_lookup_string(args, "assetPath");
    g_autofree gchar *uri = asset_path != nullptr ? asset_uri(asset_path) : nullptr;
    if (uri == nullptr) {
      respond(method_call,
              error_response("invalid_argument", "assetPath introuvable."));
      return;
    }
    begin_navigation(webview, uri);
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "loadFile") == 0) {
    const gchar *file_path = map_lookup_string(args, "filePath");
    if (file_path == nullptr) {
      respond(method_call,
              error_response("invalid_argument", "filePath manquant."));
      return;
    }
    if (g_str_has_prefix(file_path, "http://") ||
        g_str_has_prefix(file_path, "https://") ||
        g_str_has_prefix(file_path, "file://")) {
      begin_navigation(webview, file_path);
      respond(method_call, success_response());
      return;
    }
    GError *error = nullptr;
    g_autofree gchar *uri = g_filename_to_uri(file_path, nullptr, &error);
    if (error != nullptr) {
      respond(method_call, error_response("load_file_error", error->message));
      g_clear_error(&error);
      return;
    }
    begin_navigation(webview, uri);
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "loadHtmlString") == 0) {
    const gchar *html = map_lookup_string(args, "html");
    const gchar *base_url = map_lookup_string(args, "baseUrl");
    webview->is_navigating_internally = TRUE;
    webkit_web_view_load_html(web_view, html != nullptr ? html : "", base_url);
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "loadData") == 0) {
    const gchar *data = map_lookup_string(args, "data");
    const gchar *mime_type = map_lookup_string(args, "mimeType");
    const gchar *base_url = map_lookup_string(args, "baseUrl");
    // WebKitGTK ne propose pas de variante binaire générique de
    // `load_html` pour un `mimeType`/`encoding` arbitraires côté widget
    // public ; le HTML étant le cas d'usage very large majoritaire, on
    // retombe sur `load_html` (equivalent fonctionnel pour ce cas), et on
    // avertit dans le cas contraire.
    if (mime_type == nullptr || g_str_has_prefix(mime_type, "text/html")) {
      webview->is_navigating_internally = TRUE;
      webkit_web_view_load_html(web_view, data != nullptr ? data : "", base_url);
      respond(method_call, success_response());
      return;
    }
    GBytes *bytes = g_bytes_new(data, data != nullptr ? strlen(data) : 0);
    webview->is_navigating_internally = TRUE;
    webkit_web_view_load_bytes(web_view, bytes, mime_type, "UTF-8", base_url);
    g_bytes_unref(bytes);
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "evaluateJavascript") == 0) {
    const gchar *code = map_lookup_string(args, "code");
    if (code == nullptr) {
      respond(method_call, error_response("invalid_argument", "code manquant."));
      return;
    }
    g_object_ref(method_call);
    webkit_web_view_evaluate_javascript(web_view, code, -1, nullptr, nullptr,
                                        nullptr, eval_finished_cb, method_call);
    return;
  }

  if (strcmp(method, "getHtml") == 0) {
    g_object_ref(method_call);
    webkit_web_view_evaluate_javascript(
        web_view, "document.documentElement.outerHTML", -1, nullptr, nullptr,
        nullptr, eval_finished_cb, method_call);
    return;
  }

  if (strcmp(method, "injectJavascriptFileFromUrl") == 0) {
    const gchar *url = map_lookup_string(args, "url");
    inject_script_from_url(web_view, url);
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "injectJavascriptFileFromAsset") == 0) {
    const gchar *asset_file_path = map_lookup_string(args, "assetFilePath");
    g_autofree gchar *uri =
        asset_file_path != nullptr ? asset_uri(asset_file_path) : nullptr;
    inject_script_from_url(web_view, uri != nullptr ? uri : asset_file_path);
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "injectCSSFileFromUrl") == 0) {
    const gchar *url = map_lookup_string(args, "url");
    inject_css_from_url(web_view, url);
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "injectCSSFileFromAsset") == 0) {
    const gchar *asset_file_path = map_lookup_string(args, "assetFilePath");
    g_autofree gchar *uri =
        asset_file_path != nullptr ? asset_uri(asset_file_path) : nullptr;
    inject_css_from_url(web_view, uri != nullptr ? uri : asset_file_path);
    respond(method_call, success_response());
    return;
  }

  // `injectJsData`/`injectCssData` : injection de contenu déjà en mémoire
  // côté Dart (par opposition à `injectJavascriptFileFromUrl/Asset` et
  // `injectCSSFileFromUrl/Asset`, qui pointent vers une ressource externe à
  // charger). Ces deux méthodes étaient absentes de ce fichier, d'où le
  // `MissingPluginException` : `handle_instance_method_call` tombait dans
  // le `fl_method_not_implemented_response_new()` par défaut en bas de
  // fonction pour toute méthode inconnue.
  if (strcmp(method, "injectJsData") == 0) {
    const gchar *js_data = map_lookup_string(args, "jsData");
    if (js_data == nullptr) {
      respond(method_call, error_response("invalid_argument", "jsData manquant."));
      return;
    }
    webkit_web_view_evaluate_javascript(web_view, js_data, -1, nullptr, nullptr,
                                        nullptr, nullptr, nullptr);
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "injectCssData") == 0) {
    const gchar *css_data = map_lookup_string(args, "cssData");
    if (css_data == nullptr) {
      respond(method_call, error_response("invalid_argument", "cssData manquant."));
      return;
    }
    g_autofree gchar *css_literal = js_string_literal(css_data);
    g_autofree gchar *js = g_strdup_printf(
        "(function(){var st=document.createElement('style');"
        "st.appendChild(document.createTextNode(%s));"
        "(document.head||document.documentElement).appendChild(st);})();",
        css_literal);
    webkit_web_view_evaluate_javascript(web_view, js, -1, nullptr, nullptr,
                                        nullptr, nullptr, nullptr);
    respond(method_call, success_response());
    return;
  }

  // Le menu contextuel natif est intégralement supprimé côté Linux (voir
  // `context_menu_cb` dans `linux_webview.cc` : il se positionne en
  // coordonnées écran absolues, incompatibles avec la fenêtre offscreen
  // hébergeant le WebKitWebView). `setContextMenuItems` fait partie de
  // l'API partagée du controller et peut donc être appelée sans
  // vérification de plateforme côté Dart : on acquitte sans effet plutôt
  // que de renvoyer `not_implemented`, qui remonterait comme une
  // `MissingPluginException` côté appelant.
  if (strcmp(method, "setContextMenuItems") == 0) {
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "reload") == 0) {
    webview->is_navigating_internally = TRUE;
    webkit_web_view_reload(web_view);
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "goBack") == 0) {
    webview->is_navigating_internally = TRUE;
    webkit_web_view_go_back(web_view);
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "goForward") == 0) {
    webview->is_navigating_internally = TRUE;
    webkit_web_view_go_forward(web_view);
    respond(method_call, success_response());
    return;
  }

  if (strcmp(method, "canGoBack") == 0) {
    respond(method_call, success_response(
                             fl_value_new_bool(webkit_web_view_can_go_back(web_view))));
    return;
  }

  if (strcmp(method, "canGoForward") == 0) {
    respond(method_call,
            success_response(
                fl_value_new_bool(webkit_web_view_can_go_forward(web_view))));
    return;
  }

  respond(method_call,
          FL_METHOD_RESPONSE(fl_method_not_implemented_response_new()));
}

void instance_method_call_cb(FlMethodChannel *channel,
                             FlMethodCall *method_call, gpointer user_data) {
  LinuxWebview *webview = static_cast<LinuxWebview *>(user_data);
  handle_instance_method_call(webview, method_call);
}
