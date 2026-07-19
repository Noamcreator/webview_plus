import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'webview_plus_controller.dart';
import 'webview_plus_initial_data.dart';

/// Enregistrement du plugin côté Web, appelé automatiquement par
/// le mécanisme de plugin registration de Flutter Web.
class WebviewPlusPluginWeb {
  static void registerWith(Registrar registrar) {}
}

int _viewIdCounter = 0;

/// Résout un chemin d'asset Flutter (`assets/...`) en URL absolue, ancrée
/// sur le `<base href>` réel de la page (`document.baseURI`) plutôt que sur
/// l'URL courante du navigateur (`Uri.base`/`window.location`).
///
/// Sans ça, un chemin relatif comme `'assets/$assetPath'` est résolu par le
/// navigateur par rapport à la route actuelle : si l'app tourne sur une
/// route non-racine (ex. `/demo`, routing sans `#`), le chemin obtenu ne
/// correspond plus au dossier où Flutter Web sert réellement ses propres
/// assets, et le chargement échoue silencieusement (page blanche dans
/// l'iframe, 404 dans l'onglet Réseau du navigateur).
String _resolveAssetUrl(String assetPath) {
  final String normalized =
      assetPath.startsWith('assets/') ? assetPath : 'assets/$assetPath';
  return Uri.parse(web.document.baseURI).resolve(normalized).toString();
}

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
class WebviewPlusWebController implements WebviewPlusController {
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

  /// Bascule l'iframe en mode "URL" : retire l'attribut `srcdoc` s'il est
  /// posé, faute de quoi le navigateur continue d'ignorer silencieusement
  /// tout changement de `src` (`srcdoc`, quand présent, a systématiquement
  /// priorité sur `src` d'après la spécification HTML — indépendamment de
  /// l'ordre ou du moment où `src` est modifié ensuite).
  void _switchToSrcMode(String url) {
    _iframe.removeAttribute('srcdoc');
    _iframe.src = url;
  }

  /// Bascule l'iframe en mode "contenu inline" : retire `src` par
  /// symétrie (évite un historique de navigation incohérent), même si
  /// `srcdoc` prendrait de toute façon le dessus tant qu'il est présent.
  void _switchToSrcDocMode(String html) {
    _iframe.removeAttribute('src');
    _iframe.srcdoc = html.toJS;
  }

  @override
  Future<void> loadUrl(String url) async {
    _switchToSrcMode(url);
  }

  @override
  Future<void> loadFlutterAsset(String assetPath) async {
    _switchToSrcMode(_resolveAssetUrl(assetPath));
  }

  @override
  Future<void> loadFile(String filePath) async {
    // Sur le Web, il n'existe pas d'accès générique au système de
    // fichiers local ; on tente un chargement direct si un chemin/URL
    // accessible a été fourni (ex. un fichier servi par le même serveur).
    _switchToSrcMode(filePath);
  }

  @override
  Future<void> loadHtmlString(String html_, {String? baseUrl}) async {
    _switchToSrcDocMode(html_);
  }

  @override
  Future<void> loadData(
    String data, {
    String mimeType = 'text/html',
    String encoding = 'utf8',
    String? baseUrl,
  }) async {
    _switchToSrcDocMode(data);
  }

  @override
  Future<String?> evaluateJavascript(String code) async {
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
    return evaluateJavascript('document.documentElement.outerHTML');
  }

  @override
  Future<void> injectJsData(String jsData) async {
    final escapedData = _escapeData(jsData);
    await evaluateJavascript(
      "(function(){var s=document.createElement('script');s.textContent='$escapedData';document.head.appendChild(s);})();",
    );
  }

  @override
  Future<void> injectJavascriptFileFromUrl(String urlFile) async {
    await evaluateJavascript(
      "(function(){var s=document.createElement('script');s.src='${_escapeData(urlFile)}';document.head.appendChild(s);})();",
    );
  }

  @override
  Future<void> injectJavascriptFileFromAsset(String assetFilePath) async {
    await injectJavascriptFileFromUrl(_resolveAssetUrl(assetFilePath));
  }

  @override
  Future<void> injectCssData(String cssData) async {
    final escapedData = _escapeData(cssData);
    await evaluateJavascript(
      "(function(){var s=document.createElement('style');s.textContent='$escapedData';document.head.appendChild(s);})();",
    );
  }

  @override
  Future<void> injectCSSFileFromUrl(String urlFile) async {
    await evaluateJavascript(
      "(function(){var l=document.createElement('link');l.rel='stylesheet';l.href='${_escapeData(urlFile)}';document.head.appendChild(l);})();",
    );
  }

  @override
  Future<void> injectCSSFileFromAsset(String assetFilePath) async {
    await injectCSSFileFromUrl(_resolveAssetUrl(assetFilePath));
  }

  String _escapeData(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r');
  }

  @override
  Future<void> reload() async {
    if (_iframe.hasAttribute('srcdoc')) {
      // Remise à la même valeur : ré-assigner l'attribut identique ne
      // redéclenche pas de chargement dans certains navigateurs. On force
      // en repassant momentanément par une valeur vide.
      final currentSrcDoc = _iframe.srcdoc;
      _iframe.srcdoc = ''.toJS;
      _iframe.srcdoc = currentSrcDoc;
    } else {
      final currentSrc = _iframe.src;
      _iframe.src = currentSrc;
    }
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

  /// Répond à un appel `window.webview_plus.callHandler(...)` initié côté
  /// JS (voir le script injecté dans `buildWebview`). Le résultat (ou
  /// l'erreur) est renvoyé en ré-évaluant du JS dans l'iframe plutôt qu'en
  /// utilisant `Window.postMessage` côté Dart : `evaluateJavascript` est
  /// déjà le mécanisme éprouvé pour parler à l'iframe, pas besoin d'un
  /// second canal.
  Future<void> respondToJsCall(
    String callId,
    String handlerName,
    List<dynamic> args,
  ) async {
    final handler = _javaScriptHandlers[handlerName];
    if (handler == null) {
      final message = 'Aucun handler JavaScript nommé "$handlerName" '
          "n'a été enregistré côté Dart (addJavaScriptHandler).";
      await evaluateJavascript(
        "window.webview_plus && window.webview_plus.__reject && "
        "window.webview_plus.__reject('$callId', '${_escapeData(message)}');",
      );
      return;
    }
    try {
      final dynamic result = await handler(args);
      final String resultJson = jsonEncode(result);
      await evaluateJavascript(
        "window.webview_plus && window.webview_plus.__resolve && "
        "window.webview_plus.__resolve('$callId', '${_escapeData(resultJson)}');",
      );
    } catch (e) {
      await evaluateJavascript(
        "window.webview_plus && window.webview_plus.__reject && "
        "window.webview_plus.__reject('$callId', '${_escapeData(e.toString())}');",
      );
    }
  }
}

/// Construit le widget Web (HtmlElementView + iframe) utilisé par
/// `WebviewPlus` lorsque `kIsWeb` est vrai.
Widget buildWebview({
  required String? initialUrl,
  required String? initialAsset,
  WebviewInitialData? initialData,
  required WebviewMessageCallback? onMessageReceived,
  required NavigationRequestCallback? onNavigationRequest,
  required void Function(WebviewPlusController controller)
      onControllerCreated,
}) {
  final String viewType = 'webview_plus_iframe_${_viewIdCounter++}';
  assert(() {
    // Diagnostic temporaire : si ce message apparaît plus d'une fois dans
    // la console pour une seule Webview affichée à l'écran, c'est la
    // preuve qu'une nouvelle iframe est bien recréée à chaque fois (donc
    // que le State parent est détruit/recréé, ou que buildWebview est
    // rappelé sans le cache attendu côté widget.dart). À retirer une fois
    // le diagnostic terminé.
    // ignore: avoid_print
    print('[webview_plus][DIAGNOSTIC] buildWebview() appelé → nouvelle iframe "$viewType"');
    return true;
  }());
  
  // html.IFrameElement becomes web.HTMLIFrameElement
  final web.HTMLIFrameElement iframe = web.HTMLIFrameElement()
    ..style.border = 'none'
    ..style.height = '100%'
    ..style.width = '100%'
    ..allow = 'autoplay; camera; microphone';

  if (initialAsset != null) {
    iframe.src = _resolveAssetUrl(initialAsset);
  } else if (initialUrl != null) {
    iframe.src = initialUrl;
  } else if (initialData != null) {
    // Équivalent Web de `loadData` : injecté via `srcdoc`, pas de vraie
    // origine réseau (comme sur Windows, voir `webview_plus_initial_data.dart`).
    // `initialData.baseUrl` n'a donc pas d'équivalent fiable ici.
    iframe.srcdoc = initialData.data.toJS;
  }

  ui_web.platformViewRegistry.registerViewFactory(viewType, (int id) {
    return iframe;
  });

  final controller = WebviewPlusWebController(iframe, viewType);
  bool controllerCreatedNotified = false;

  // listen to window.onMessage using package:web
  web.window.onMessage.listen((web.MessageEvent event) {
    final JSAny? data = event.data;
    if (data == null) return;

    if (data.isA<JSString>()) {
      onMessageReceived?.call(controller, (data as JSString).toDart);
    } else if (data.isA<JSObject>()) {
      try {
        final jsObj = data as JSObject;
        // Format `{__webviewPlusCall, id, handlerName, args}` -> vrai pont
        // `window.webview_plus.callHandler(...)`, avec réponse (résultat ou
        // erreur) renvoyée à l'iframe via `respondToJsCall`.
        if (jsObj.has('__webviewPlusCall')) {
          final JSAny? idValue = jsObj['id'];
          final JSAny? nameValue = jsObj['handlerName'];
          final JSAny? argsValue = jsObj['args'];
          if (idValue != null &&
              idValue.isA<JSString>() &&
              nameValue != null &&
              nameValue.isA<JSString>()) {
            final String callId = (idValue as JSString).toDart;
            final String handlerName = (nameValue as JSString).toDart;
            final List<dynamic> args =
                (argsValue?.dartify() as List<dynamic>?) ?? const <dynamic>[];
            unawaited(controller.respondToJsCall(callId, handlerName, args));
          }
          return;
        }
        // Wasm-safe property check replacing js_util.getProperty
        if (jsObj.has('message')) {
          final JSAny? messageValue = jsObj['message'];
          if (messageValue != null && messageValue.isA<JSString>()) {
            onMessageReceived?.call(controller, (messageValue as JSString).toDart);
          }
        }
        // Format `{handlerName, args}` historique, sans réponse (conservé
        // pour compatibilité) -> préférer `__webviewPlusCall` côté JS.
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
    if (!controllerCreatedNotified) {
      controllerCreatedNotified = true;
      onControllerCreated(controller);
    }
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
          (function() {
            if (!window.webview_plus) { window.webview_plus = {}; }
            var pending = {};
            var nextId = 1;
            window.webview_plus.callHandler = function(name) {
              var args = Array.prototype.slice.call(arguments, 1);
              var id = 'wpc_' + (nextId++);
              return new Promise(function(resolve, reject) {
                pending[id] = { resolve: resolve, reject: reject };
                window.parent.postMessage(
                  { __webviewPlusCall: true, id: id, handlerName: name, args: args },
                  '*'
                );
              });
            };
            window.webview_plus.__resolve = function(id, resultJson) {
              var p = pending[id];
              if (!p) return;
              delete pending[id];
              try { p.resolve(JSON.parse(resultJson)); }
              catch (e) { p.resolve(resultJson); }
            };
            window.webview_plus.__reject = function(id, message) {
              var p = pending[id];
              if (!p) return;
              delete pending[id];
              p.reject(new Error(message));
            };
          })();
        ''');
      }
    } catch (_) {}
  });

  return HtmlElementView(viewType: viewType);
}