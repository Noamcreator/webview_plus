import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

import 'webview_plus_context_menu.dart';

/// Interface commune implémentée par le contrôleur natif
/// ([WebviewPlusController]) et par le contrôleur Web
/// (`WebviewPlusWebController`), afin que le widget public
/// puisse exposer la même API quelle que soit la plateforme.
abstract class WebviewPlatformController {
  Future<void> loadUrl(String url);
  Future<void> loadFlutterAsset(String assetPath);

  /// Charge un fichier situé n'importe où sur le disque (chemin absolu).
  Future<void> loadFile(String filePath);

  Future<void> loadHtmlString(String html, {String? baseUrl});

  /// Équivalent de [loadHtmlString] mais permettant de préciser le
  /// `mimeType` et l'`encoding` (utile pour charger autre chose que du
  /// HTML, par ex. du SVG ou du texte brut).
  Future<void> loadData(
    String data, {
    String mimeType = 'text/html',
    String encoding = 'utf8',
    String? baseUrl,
  });

  /// Exécute [code] dans le contexte de la page et retourne le résultat
  /// décodé en type Dart natif (`String`, `num`, `bool`, `List`, `Map`, ou
  /// `null`), et non plus systématiquement une `String`.
  ///
  /// Exemple : `await controller.evaluateJavaScript('1 + 1')` renvoie
  /// désormais l'`int` `2` et non la chaîne `"2"`.
  Future<dynamic> evaluateJavaScript(String code);

  /// Retourne le HTML actuellement rendu par la page
  /// (`document.documentElement.outerHTML`).
  Future<String?> getHtml();

  /// Injecte un fichier `<script>` distant dans la page en cours.
  Future<void> injectJavascriptFileFromUrl(String urlFile);

  /// Injecte un fichier `<script>` provenant des assets Flutter.
  Future<void> injectJavascriptFileFromAsset(String assetFilePath);

  /// Injecte une feuille de style distante dans la page en cours.
  Future<void> injectCSSFileFromUrl(String urlFile);

  /// Injecte une feuille de style provenant des assets Flutter.
  Future<void> injectCSSFileFromAsset(String assetFilePath);

  Future<void> reload();
  Future<void> goBack();
  Future<void> goForward();
  Future<bool> canGoBack();
  Future<bool> canGoForward();

  /// Enregistre un handler appelable depuis le JavaScript de la page via
  /// `window.webview_plus.callHandler('nomDuHandler', arg1, arg2, ...)`.
  ///
  /// Le callback peut être asynchrone (`Future`) ; sa valeur de retour
  /// est renvoyée côté JS comme résolution de la `Promise`.
  void addJavaScriptHandler({
    required String handlerName,
    required JavaScriptHandlerCallback callback,
  });

  /// Désenregistre un handler précédemment ajouté.
  void removeJavaScriptHandler(String handlerName);

  /// Indique si un handler porte ce nom.
  bool hasJavaScriptHandler(String handlerName);
}

/// Callback appelé à chaque tentative de navigation.
/// Retourner `true` autorise la navigation, `false` la bloque.
typedef NavigationRequestCallback = FutureOr<bool> Function(WebviewPlatformController controller, Uri uri);

/// Callback appelé lorsque du JavaScript envoie un message via
/// `WebviewPlusChannel.postMessage(...)`.
typedef WebviewMessageCallback = void Function(WebviewPlatformController controller, String message);

/// Callback appelé au début / à la fin du chargement d'une page.
typedef WebviewLoadCallback = void Function(WebviewPlatformController controller, Uri uri);

/// Callback appelé avec un controller
typedef WebviewControllerCallback = void Function(WebviewPlatformController controller);

/// Callback appelé lorsque le curseur système à afficher au-dessus de la
/// Webview change (Windows uniquement, mode composition). [cursorKind] est
/// un identifiant générique ("basic", "click", "text", "wait", "precise",
/// "resizeLeftRight", "resizeUpDown", "allScroll", "forbidden") à mapper
/// vers un `SystemMouseCursor` côté widget.
typedef WebviewCursorCallback = void Function(
  WebviewPlatformController controller,
  String cursorKind,
);

/// Callback appelé lorsqu'une erreur de chargement survient.
typedef WebviewErrorCallback = void Function(
  WebviewPlatformController controller,
  String url,
  int errorCode,
  String description,
);

/// Callback appelé lorsque le JavaScript de la page invoque
/// `window.webview_plus.callHandler(handlerName, ...args)`.
typedef JavaScriptHandlerCallback = FutureOr<dynamic> Function(
  List<dynamic> args,
);

/// Callback appelé lorsque la vue native est prête et que le
/// [WebviewPlusController] associé est disponible.
typedef WebviewCreatedCallback = void Function(
    WebviewPlusController controller);

/// Contrôleur permettant de piloter une instance de Webview native
/// (Android, iOS, macOS, Windows, Linux) depuis Dart.
///
/// Chaque instance de vue native possède son propre [MethodChannel],
/// nommé `webview_plus_<viewId>`, où `viewId` est l'identifiant
/// entier attribué par Flutter à la plateforme view (AndroidView /
/// UiKitView) au moment de sa création.
class WebviewPlusController implements WebviewPlatformController {
  WebviewPlusController._(this._channel);

  static late WebviewPlusController _controller;

  final MethodChannel _channel;

  NavigationRequestCallback? _onNavigationRequest;
  WebviewMessageCallback? _onMessageReceived;
  WebviewLoadCallback? _onLoadStart;
  WebviewLoadCallback? _onLoadStop;
  WebviewLoadCallback? _onDOMContentLoaded;
  WebviewErrorCallback? _onReceivedError;
  WebviewControllerCallback? _onWindowFocus;
  WebviewControllerCallback? _onWindowBlur;
  WebviewCursorCallback? _onCursorChanged;

  final Map<String, JavaScriptHandlerCallback> _javaScriptHandlers =
      <String, JavaScriptHandlerCallback>{};

  final Map<String, ContextMenuAction> _contextMenuActions =
      <String, ContextMenuAction>{};

  /// Utilisé en interne par le widget pour instancier le contrôleur
  /// dès que la vue native est créée.
  static WebviewPlusController init(
    int viewId, {
    NavigationRequestCallback? onNavigationRequest,
    WebviewMessageCallback? onMessageReceived,
    WebviewLoadCallback? onLoadStart,
    WebviewLoadCallback? onLoadStop,
    WebviewLoadCallback? onDOMContentLoaded,
    WebviewErrorCallback? onReceivedError,
    WebviewControllerCallback? onWindowFocus,
    WebviewControllerCallback? onWindowBlur,
    WebviewCursorCallback? onCursorChanged,
    List<ContextMenuItem> contextMenuItems = const <ContextMenuItem>[],
  }) {
    final channel = MethodChannel('webview_plus_$viewId');
    _controller = WebviewPlusController._(channel)
      .._onNavigationRequest = onNavigationRequest
      .._onMessageReceived = onMessageReceived
      .._onLoadStart = onLoadStart
      .._onLoadStop = onLoadStop
      .._onDOMContentLoaded = onDOMContentLoaded
      .._onReceivedError = onReceivedError
      .._onWindowFocus = onWindowFocus
      .._onWindowBlur = onWindowBlur
      .._onCursorChanged = onCursorChanged;
    _controller._registerContextMenuActionsLocally(contextMenuItems);
    channel.setMethodCallHandler(_controller._onMethodCall);
    return _controller;
  }

  void _registerContextMenuActionsLocally(List<ContextMenuItem> items) {
    _contextMenuActions
      ..clear()
      ..addEntries(items.map((e) => MapEntry(e.id, e.action)));
  }

  /// Remplace la liste des éléments personnalisés du menu contextuel natif
  /// (déjà envoyée à la création via `WebviewPlus(contextMenuItems:
  /// ...)`) et met à jour la vue native en conséquence.
  Future<void> setContextMenuItems(List<ContextMenuItem> items) async {
    _registerContextMenuActionsLocally(items);
    await _channel.invokeMethod<void>('setContextMenuItems', {
      'items': items.map((e) => e.toMap()).toList(),
    });
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onNavigationRequest':
        final String url = call.arguments as String;
        if (_onNavigationRequest != null) {
          final bool allow = await _onNavigationRequest!(_controller, Uri.parse(url));
          return allow;
        }
        return true;

      case 'onMessageReceived':
        final String message = call.arguments as String;
        _onMessageReceived?.call(_controller, message);
        return null;

      case 'onLoadStart':
        final String url = call.arguments as String;
        _onLoadStart?.call(_controller, Uri.parse(url));
        return null;

      case 'onLoadStop':
        final String url = call.arguments as String;
        _onLoadStop?.call(_controller, Uri.parse(url));
        return null;

      case 'onDOMContentLoaded':
        final String url = call.arguments as String;
        _onDOMContentLoaded?.call(_controller, Uri.parse(url));
        return null;

      case 'onReceivedError':
        final map = Map<String, dynamic>.from(call.arguments as Map);
        _onReceivedError?.call(
          _controller,
          map['url'] as String? ?? '',
          map['code'] as int? ?? -1,
          map['description'] as String? ?? '',
        );
        return null;

      case 'onWindowFocus':
        _onWindowFocus?.call(_controller);
        return null;

      case 'onWindowBlur':
        _onWindowBlur?.call(_controller);
        return null;

      case 'onCursorChanged':
        final String cursorKind = call.arguments as String;
        _onCursorChanged?.call(_controller, cursorKind);
        return null;

      case 'onContextMenuAction':
        final map = Map<String, dynamic>.from(call.arguments as Map);
        final String? id = map['id'] as String?;
        final String text = map['text'] as String? ?? '';
        final action = id != null ? _contextMenuActions[id] : null;
        if (action != null) {
          await action(text);
        }
        return null;

      case 'onJavaScriptHandler':
        final map = Map<String, dynamic>.from(call.arguments as Map);
        final String handlerName = map['handlerName'] as String;
        final String argsJson = map['args'] as String? ?? '[]';
        final handler = _javaScriptHandlers[handlerName];
        if (handler == null) {
          throw PlatformException(
            code: 'NO_HANDLER',
            message: 'Aucun handler JavaScript nommé "$handlerName" '
                "n'a été enregistré côté Dart (addJavaScriptHandler).",
          );
        }
        List<dynamic> args;
        try {
          args = jsonDecode(argsJson) as List<dynamic>;
        } catch (_) {
          args = <dynamic>[];
        }
        return await handler(args);

      default:
        throw MissingPluginException('Méthode non gérée côté Dart : ${call.method}');
    }
  }

  /// Charge une URL distante ou locale (http, https, file).
  @override
  Future<void> loadUrl(String url) {
    return _channel.invokeMethod<void>('loadUrl', {'url': url});
  }

  /// Charge un fichier HTML embarqué dans les assets Flutter
  /// (déclaré dans le pubspec.yaml de l'application hôte).
  ///
  /// Exemple : `controller.loadFlutterAsset('assets/index.html');`
  @override
  Future<void> loadFlutterAsset(String assetPath) {
    return _channel
        .invokeMethod<void>('loadFlutterAsset', {'assetPath': assetPath});
  }

  /// Charge un fichier n'importe où sur le disque via un chemin absolu.
  ///
  /// Exemple : `controller.loadFile('/storage/emulated/0/Download/page.html');`
  @override
  Future<void> loadFile(String filePath) {
    return _channel.invokeMethod<void>('loadFile', {'filePath': filePath});
  }

  /// Charge une chaîne HTML brute directement.
  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) {
    return _channel.invokeMethod<void>(
        'loadHtmlString', {'html': html, 'baseUrl': baseUrl});
  }

  @override
  Future<void> loadData(
    String data, {
    String mimeType = 'text/html',
    String encoding = 'utf8',
    String? baseUrl,
  }) {
    return _channel.invokeMethod<void>('loadData', {
      'data': data,
      'mimeType': mimeType,
      'encoding': encoding,
      'baseUrl': baseUrl,
    });
  }

  /// Exécute du JavaScript dans le contexte de la page chargée.
  ///
  /// Le natif (Android/iOS/macOS/Windows/Linux) décode désormais lui-même
  /// le résultat JS en un arbre de types Dart natifs avant de le renvoyer
  /// via le [MethodChannel] ; il suffit donc ici de transmettre la valeur
  /// `dynamic` telle quelle, sans double-décodage JSON côté Dart.
  @override
  Future<dynamic> evaluateJavaScript(String code) {
    return _channel.invokeMethod<dynamic>('evaluateJavaScript', {'code': code});
  }

  @override
  Future<String?> getHtml() {
    return _channel.invokeMethod<String>('getHtml');
  }

  @override
  Future<void> injectJavascriptFileFromUrl(String urlFile) {
    return _channel
        .invokeMethod<void>('injectJavascriptFileFromUrl', {'url': urlFile});
  }

  @override
  Future<void> injectJavascriptFileFromAsset(String assetFilePath) {
    return _channel.invokeMethod<void>(
        'injectJavascriptFileFromAsset', {'assetFilePath': assetFilePath});
  }

  @override
  Future<void> injectCSSFileFromUrl(String urlFile) {
    return _channel
        .invokeMethod<void>('injectCSSFileFromUrl', {'url': urlFile});
  }

  @override
  Future<void> injectCSSFileFromAsset(String assetFilePath) {
    return _channel.invokeMethod<void>(
        'injectCSSFileFromAsset', {'assetFilePath': assetFilePath});
  }

  @override
  Future<void> reload() => _channel.invokeMethod<void>('reload');

  @override
  Future<void> goBack() => _channel.invokeMethod<void>('goBack');

  @override
  Future<void> goForward() => _channel.invokeMethod<void>('goForward');

  @override
  Future<bool> canGoBack() async {
    final result = await _channel.invokeMethod<bool>('canGoBack');
    return result ?? false;
  }

  @override
  Future<bool> canGoForward() async {
    final result = await _channel.invokeMethod<bool>('canGoForward');
    return result ?? false;
  }

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
}