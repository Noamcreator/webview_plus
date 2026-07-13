import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'webview_plus_controller.dart';

/// Enregistrement du plugin côté Web, appelé automatiquement par
/// le mécanisme de plugin registration de Flutter Web.
class WebviewPlusPluginWeb {
  static void registerWith(Registrar registrar) {}
}

int _viewIdCounter = 0;

/// Inline extension type to safe-invoke evaluation code on an iframe's window object.
@JS()
@staticInterop
extension type JSWindow._(JSObject _) implements JSObject {
  external JSAny? eval(String code);
}

/// Contrôleur Web : encapsule directement un `HTMLIFrameElement`.
/// Implémente la même interface que le contrôleur natif afin que
/// l'API Dart exposée à l'utilisateur soit strictement identique.
///
/// ⚠️ Par nature (isolation cross-origin des iframes), plusieurs
/// fonctionnalités disponibles nativement (menu contextuel, injection
/// fiable de handlers JS, lecture du HTML d'une page distante...) sont
/// ici en mode "best effort" et peuvent échouer silencieusement selon
/// l'origine chargée.
class WebviewPlusWebController implements WebviewPlatformController {
  WebviewPlusWebController(this._iframe, this._channelName);

  final web.HTMLIFrameElement _iframe;
  // ignore: unused_field
  final String _channelName;

  final Map<String, JavaScriptHandlerCallback> _javaScriptHandlers =
      <String, JavaScriptHandlerCallback>{};

  JSWindow? get _win {
    final web.Window? win = _iframe.contentWindow;
    return win == null ? null : win as JSWindow;
  }

  @override
  Future<void> loadUrl(String url) async {
    _iframe.src = url;
  }

  @override
  Future<void> loadFlutterAsset(String assetPath) async {
    _iframe.src = 'assets/$assetPath';
  }

  @override
  Future<void> loadFile(String filePath) async {
    // Sur le Web, il n'existe pas d'accès générique au système de
    // fichiers local ; on tente un chargement direct si un chemin/URL
    // accessible a été fourni (ex. un fichier servi par le même serveur).
    _iframe.src = filePath;
  }

  @override
  Future<void> loadHtmlString(String html_, {String? baseUrl}) async {
    _iframe.srcdoc = html_.toJS;
  }

  @override
  Future<void> loadData(
    String data, {
    String mimeType = 'text/html',
    String encoding = 'utf8',
    String? baseUrl,
  }) async {
    _iframe.srcdoc = data.toJS;
  }

  @override
  Future<String?> evaluateJavaScript(String code) async {
    try {
      final jsWin = _win;
      if (jsWin == null) return null;
      final JSAny? result = jsWin.eval(code);
      return result?.dartify()?.toString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> getHtml() {
    return evaluateJavaScript('document.documentElement.outerHTML');
  }

  @override
  Future<void> injectJavascriptFileFromUrl(String urlFile) async {
    await evaluateJavaScript(
      "(function(){var s=document.createElement('script');s.src='${_escape(urlFile)}';document.head.appendChild(s);})();",
    );
  }

  @override
  Future<void> injectJavascriptFileFromAsset(String assetFilePath) async {
    await injectJavascriptFileFromUrl('assets/$assetFilePath');
  }

  @override
  Future<void> injectCSSFileFromUrl(String urlFile) async {
    await evaluateJavaScript(
      "(function(){var l=document.createElement('link');l.rel='stylesheet';l.href='${_escape(urlFile)}';document.head.appendChild(l);})();",
    );
  }

  @override
  Future<void> injectCSSFileFromAsset(String assetFilePath) async {
    await injectCSSFileFromUrl('assets/$assetFilePath');
  }

  String _escape(String s) => s.replaceAll("'", "\\'");

  @override
  Future<void> reload() async {
    final currentSrc = _iframe.src;
    _iframe.src = currentSrc;
  }

  @override
  Future<void> goBack() async {}

  @override
  Future<void> goForward() async {}

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<bool> canGoForward() async => false;

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required JavaScriptHandlerCallback callback,
  }) {
    _javaScriptHandlers[handlerName] = callback;
  }

  @override
  void removeJavaScriptHandler(String handlerName) {
    _javaScriptHandlers.remove(handlerName);
  }

  @override
  bool hasJavaScriptHandler(String handlerName) {
    return _javaScriptHandlers.containsKey(handlerName);
  }

  /// Utilisé en interne : dispatch un message reçu via `postMessage` vers
  /// le handler JS enregistré correspondant, si le message respecte le
  /// format `{handlerName, args}`.
  Future<dynamic> dispatchHandlerMessage(
      String handlerName, List<dynamic> args) async {
    final handler = _javaScriptHandlers[handlerName];
    if (handler == null) return null;
    return await handler(args);
  }
}

/// Construit le widget Web (HtmlElementView + iframe) utilisé par
/// `WebviewPlus` lorsque `kIsWeb` est vrai.
Widget buildWebview({
  required String? initialUrl,
  required String? initialAsset,
  required WebviewMessageCallback? onMessageReceived,
  required NavigationRequestCallback? onNavigationRequest,
  required void Function(WebviewPlatformController controller)
      onControllerCreated,
}) {
  final String viewType = 'webview_plus_iframe_${_viewIdCounter++}';
  
  // html.IFrameElement becomes web.HTMLIFrameElement
  final web.HTMLIFrameElement iframe = web.HTMLIFrameElement()
    ..style.border = 'none'
    ..style.height = '100%'
    ..style.width = '100%'
    ..allow = 'autoplay; camera; microphone';

  if (initialAsset != null) {
    iframe.src = 'assets/$initialAsset';
  } else if (initialUrl != null) {
    iframe.src = initialUrl;
  }

  ui_web.platformViewRegistry.registerViewFactory(viewType, (int id) {
    return iframe;
  });

  final controller = WebviewPlusWebController(iframe, viewType);

  // listen to window.onMessage using package:web
  web.window.onMessage.listen((web.MessageEvent event) {
    final JSAny? data = event.data;
    if (data == null) return;

    if (data.isA<JSString>()) {
      onMessageReceived?.call(controller, (data as JSString).toDart);
    } else if (data.isA<JSObject>()) {
      try {
        final jsObj = data as JSObject;
        // Wasm-safe property check replacing js_util.getProperty
        if (jsObj.has('message')) {
          final JSAny? messageValue = jsObj['message'];
          if (messageValue != null && messageValue.isA<JSString>()) {
            onMessageReceived?.call(controller, (messageValue as JSString).toDart);
          }
        }
        // Format `{handlerName, args}` -> pont vers addJavaScriptHandler.
        if (jsObj.has('handlerName')) {
          final JSAny? nameValue = jsObj['handlerName'];
          if (nameValue != null && nameValue.isA<JSString>()) {
            final handlerName = (nameValue as JSString).toDart;
            controller.dispatchHandlerMessage(handlerName, const []);
          }
        }
      } catch (_) {}
    }
  });

  iframe.onLoad.listen((_) async {
    onControllerCreated(controller);
    if (onNavigationRequest != null) {
      try {
        final currentUrl = iframe.src;
        await onNavigationRequest(controller, Uri.parse(currentUrl));
      } catch (_) {}
    }
    try {
      final web.Window? win = iframe.contentWindow;
      if (win != null) {
        final jsWin = win as JSWindow;
        jsWin.eval('''
          window.WebviewPlusChannel = {
            postMessage: function(msg) {
              window.parent.postMessage(msg, "*");
            }
          };
        ''');
      }
    } catch (_) {}
  });

  return HtmlElementView(viewType: viewType);
}
