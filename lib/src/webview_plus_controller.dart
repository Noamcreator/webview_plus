import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show VoidCallback, debugPrint;
import 'package:flutter/services.dart';

import 'webview_plus_context_menu.dart';

/// Interface commune implémentée par le contrôleur natif
/// ([WebviewBaseController]) et par le contrôleur Web
/// (`WebviewPlusWebController`), afin que le widget public
/// puisse exposer la même API quelle que soit la plateforme.
abstract class WebviewPlusController {
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

  /// Retourne le HTML actuellement rendu par la page
  /// (`document.documentElement.outerHTML`).
  Future<String?> getHtml();

  /// Exécute [code] dans le contexte de la page et retourne le résultat
  /// décodé en type Dart natif (`String`, `num`, `bool`, `List`, `Map`, ou
  /// `null`), et non plus systématiquement une `String`.
  ///
  /// Exemple : `await controller.evaluateJavascript('1 + 1')` renvoie
  /// désormais l'`int` `2` et non la chaîne `"2"`.
  Future<dynamic> evaluateJavascript(String code);

  /// Injecte du code JavaScript brut directement dans la page en cours.
  Future<void> injectJsData(String jsData);

  /// Injecte un fichier `<script>` distant dans la page en cours.
  Future<void> injectJavascriptFileFromUrl(String urlFile);

  /// Injecte un fichier `<script>` provenant des assets Flutter.
  Future<void> injectJavascriptFileFromAsset(String assetFilePath);

  /// Injecte du code CSS brut directement dans la page en cours.
  Future<void> injectCssData(String cssData);

  /// Injecte une feuille de style distante dans la page en cours.
  Future<void> injectCSSFileFromUrl(String urlFile);

  /// Injecte une feuille de style provenant des assets Flutter.
  Future<void> injectCSSFileFromAsset(String assetFilePath);

  /// Donne le focus clavier à la Webview (ex. depuis un handler JS
  /// `requestWebViewFocus` appelé quand l'utilisateur clique dans la page).
  ///
  /// Android : `WebView.requestFocus()` ; macOS : la Webview devient
  /// first responder ; Linux/Windows : le focus Flutter est donné au widget
  /// Webview (c'est lui qui retransmet le clavier à la vue native) ; Web :
  /// `iframe.focus()`. Ne lève jamais d'exception.
  Future<void> requestFocus();

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
typedef NavigationRequestCallback = FutureOr<bool> Function(WebviewPlusController controller, Uri uri);

/// Callback appelé lorsque du JavaScript envoie un message via
/// `WebviewPlusChannel.postMessage(...)`.
typedef WebviewMessageCallback = void Function(WebviewPlusController controller, String message);

/// Callback appelé au début / à la fin du chargement d'une page.
typedef WebviewLoadCallback = void Function(WebviewPlusController controller, Uri uri);

/// Callback appelé avec un controller
typedef WebviewControllerCallback = void Function(WebviewPlusController controller);

/// Callback appelé lorsque le curseur système à afficher au-dessus de la
/// Webview change (Windows uniquement, mode composition). [cursorKind] est
/// un identifiant générique ("basic", "click", "text", "wait", "precise",
/// "resizeLeftRight", "resizeUpDown", "allScroll", "forbidden") à mapper
/// vers un `SystemMouseCursor` côté widget.
typedef WebviewCursorCallback = void Function(
  WebviewPlusController controller,
  String cursorKind,
);

/// Callback appelé lorsqu'une erreur de chargement survient.
typedef WebviewErrorCallback = void Function(
  WebviewPlusController controller,
  String url,
  int errorCode,
  String description,
);

/// Callback appelé lorsque le chargement du document principal échoue
/// (hors annulation volontaire). [url] est l'adresse qui a échoué, [code]
/// le code d'erreur natif de la plateforme (ou le statut HTTP >= 400 sur
/// Android/macOS) et [message] sa description lisible.
typedef WebviewLoadErrorCallback = void Function(
  WebviewPlusController controller,
  Uri url,
  int code,
  String message,
);

/// Progression du chargement, de 0 à 100 (voir
/// [WebviewWidget.onProgressChanged]).
typedef WebviewProgressCallback = void Function(
  WebviewPlusController controller,
  int progress,
);

/// Callback appelé lorsque le JavaScript de la page invoque
/// `window.webview_plus.callHandler(handlerName, ...args)`.
typedef JavaScriptHandlerCallback = FutureOr<dynamic> Function(
  List<dynamic> args,
);

/// Callback appelé lorsque la vue (native ou Web) est prête et que le
/// contrôleur associé est disponible.
///
/// Le type de paramètre est l'interface [WebviewPlusController] et non
/// la classe concrète [WebviewBaseController] : sur Web, le contrôleur
/// fourni est en réalité un `WebviewPlusWebController` (voir
/// `webview_plus_web.dart`), qui n'étend pas [WebviewBaseController]. Avec
/// un typedef restreint à ce dernier, ce callback ne serait jamais déclenché
/// sur Web.
typedef WebviewCreatedCallback = void Function(
    WebviewPlusController controller);

/// Callback appelé lorsque toutes les polices de la page ont fini de
/// charger (`document.fonts.ready`, voir la spécification CSS Font
/// Loading). [loadedFontFamilies] liste les familles de police effectivement
/// chargées à ce moment (peut être vide si la page n'utilise que des
/// polices système).
typedef WebviewFontsLoadedCallback = void Function(
  WebviewPlusController controller,
  List<String> loadedFontFamilies,
);

/// Callback appelé pour chaque ressource locale chargée par la page dont
/// l'extension figure dans [WebviewSettings.interceptedResourceExtensions]
/// (images par défaut). [data] contient les octets de la ressource ; la
/// valeur de retour est soit `null` (ressource servie telle quelle), soit
/// les octets de remplacement **encodés en Base64**.
///
/// Fonctionne de façon identique sur Android (`file://`), macOS et Linux
/// (schéma `app-assets://`, voir `normalizeMediaUri`). Windows : même
/// contrat côté Dart (le natif Windows doit l'implémenter). Web : une
/// iframe ne permet pas d'intercepter les ressources, le callback n'est
/// jamais appelé.
typedef WebviewLoadResourceCallback = Future<String?> Function(
  WebviewPlusController controller,
  String url,
  Uint8List data,
);

/// Contrôleur permettant de piloter une instance de Webview native
/// (Android, iOS, macOS, Windows, Linux) depuis Dart.
///
/// Chaque instance de vue native possède son propre [MethodChannel],
/// nommé `webview_plus_<viewId>`, où `viewId` est l'identifiant
/// entier attribué par Flutter à la plateforme view (AndroidView /
/// UiKitView) au moment de sa création.
class WebviewBaseController implements WebviewPlusController {
  WebviewBaseController._(this._channel);

  static const MethodChannel _infoChannel = MethodChannel('plugins.noam.me/webview_plus_info');

  /// Active ou désactive l'inspection distante (Chrome DevTools / Safari
  /// Web Inspector) pour **toutes** les Webviews de l'application,
  /// existantes et futures — à la différence de
  /// [WebviewSettings.isInspectable], qui ne s'applique qu'à une seule
  /// instance au moment de sa création.
  ///
  /// À appeler tôt (par exemple au lancement de l'app, uniquement en debug)
  /// : `WebviewPlusController.setWebContentsDebuggingEnabled();`
  ///
  /// - Android : `WebView.setWebContentsDebuggingEnabled` (API native
  ///   globale, effet immédiat sur toutes les instances).
  /// - Windows : bascule `AreDevToolsEnabled` sur chaque profil WebView2
  ///   déjà créé et mémorise la valeur pour les prochains.
  /// - iOS/macOS : équivalent best-effort — bascule `isInspectable` sur
  ///   chaque `WKWebView` déjà créée (iOS 16.4+/macOS 13.3+ uniquement ;
  ///   no-op silencieux sur les versions plus anciennes du système, où
  ///   seul [WebviewSettings.isInspectable] posé à la création reste
  ///   possible).
  /// - Linux : sans effet (WebKitGTK expose l'inspecteur via
  ///   [WebviewSettings.isInspectable] uniquement).
  static Future<void> setWebContentsDebuggingEnabled([bool enabled = true]) async {
    try {
      await _infoChannel.invokeMethod<void>(
        'setWebContentsDebuggingEnabled',
        {'enabled': enabled},
      );
    } on MissingPluginException {
      // Plateforme ne supportant pas encore cet appel : no-op silencieux.
    }
  }

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
  WebviewFontsLoadedCallback? _onFontsIsLoaded;
  WebviewLoadResourceCallback? _onLoadResource;
  WebviewLoadErrorCallback? _onLoadError;
  WebviewLoadCallback? _onContentLoading;
  WebviewLoadCallback? _onPageCommitVisible;
  WebviewProgressCallback? _onProgressChanged;

  final Map<String, JavaScriptHandlerCallback> _javaScriptHandlers =
      <String, JavaScriptHandlerCallback>{};

  final Map<String, ContextMenuAction> _contextMenuActions =
      <String, ContextMenuAction>{};

  /// Utilisé en interne par le widget pour instancier le contrôleur
  /// dès que la vue native est créée.
  static WebviewBaseController init(
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
    WebviewFontsLoadedCallback? onFontsIsLoaded,
    WebviewLoadResourceCallback? onLoadResource,
    WebviewLoadErrorCallback? onLoadError,
    WebviewLoadCallback? onContentLoading,
    WebviewLoadCallback? onPageCommitVisible,
    WebviewProgressCallback? onProgressChanged,
    List<ContextMenuItem> contextMenuItems = const <ContextMenuItem>[],
  }) {
    final channel = MethodChannel('webview_plus_$viewId');
    // Une instance PAR vue : les callbacks natifs de chaque Webview doivent
    // recevoir *leur* contrôleur (avant, un champ `static` partagé faisait
    // que toutes les vues vivantes recevaient le contrôleur de la dernière
    // créée, ex. `controller.evaluateJavascript` dans `onDOMContentLoaded`
    // d'une ancienne page partait vers la mauvaise Webview).
    final controller = WebviewBaseController._(channel)
      .._onNavigationRequest = onNavigationRequest
      .._onMessageReceived = onMessageReceived
      .._onLoadStart = onLoadStart
      .._onLoadStop = onLoadStop
      .._onDOMContentLoaded = onDOMContentLoaded
      .._onReceivedError = onReceivedError
      .._onWindowFocus = onWindowFocus
      .._onWindowBlur = onWindowBlur
      .._onCursorChanged = onCursorChanged
      .._onFontsIsLoaded = onFontsIsLoaded
      .._onLoadResource = onLoadResource
      .._onLoadError = onLoadError
      .._onContentLoading = onContentLoading
      .._onPageCommitVisible = onPageCommitVisible
      .._onProgressChanged = onProgressChanged;
    controller._registerContextMenuActionsLocally(contextMenuItems);
    channel.setMethodCallHandler(controller._onMethodCall);
    return controller;
  }

  /// Signale à la vue native que Dart est prêt à recevoir ses événements
  /// (`onLoadStart`, `onDOMContentLoaded`, appels `callHandler`...).
  ///
  /// Android met ces événements en file d'attente jusqu'à cet appel : sans
  /// cela, une page qui charge plus vite que la création du contrôleur
  /// (cas d'une page locale ou d'une Webview pré-chargée) perdrait des
  /// événements, ou appellerait `callHandler` avant que
  /// `addJavaScriptHandler` n'ait été exécuté. Appelé par le widget après
  /// `onWebViewCreated`. Sans effet (ignoré) sur les plateformes qui ne le
  /// gèrent pas.
  Future<void> markReady() async {
    try {
      await _channel.invokeMethod<void>('ready');
    } on MissingPluginException {
      // Plateforme sans file d'attente d'événements : rien à faire.
    } catch (_) {}
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
          final bool allow = await _onNavigationRequest!(this, Uri.parse(url));
          return allow;
        }
        return true;

      case 'onMessageReceived':
        final String message = call.arguments as String;
        _onMessageReceived?.call(this, message);
        return null;

      case 'onLoadStart':
        final String url = call.arguments as String;
        _onLoadStart?.call(this, Uri.parse(url));
        return null;

      case 'onLoadStop':
        final String url = call.arguments as String;
        _onLoadStop?.call(this, Uri.parse(url));
        return null;

      case 'onDOMContentLoaded':
        final String url = call.arguments as String;
        _onDOMContentLoaded?.call(this, Uri.parse(url));
        return null;

      case 'onReceivedError':
      case 'onLoadError':
        final map = Map<String, dynamic>.from(call.arguments as Map);
        final String errUrl = map['url'] as String? ?? '';
        final int errCode = (map['code'] as num?)?.toInt() ?? -1;
        final String errMessage = map['description'] as String? ?? '';
        // `onReceivedError` (historique) et `onLoadError` reçoivent le même
        // événement : une erreur de chargement du document principal.
        _onReceivedError?.call(this, errUrl, errCode, errMessage);
        _onLoadError?.call(this, Uri.tryParse(errUrl) ?? Uri(), errCode, errMessage);
        return null;

      case 'onContentLoading':
        _onContentLoading?.call(this, Uri.tryParse(call.arguments as String? ?? '') ?? Uri());
        return null;

      case 'onPageCommitVisible':
        _onPageCommitVisible?.call(this, Uri.tryParse(call.arguments as String? ?? '') ?? Uri());
        return null;

      case 'onProgressChanged':
        final int progress = ((call.arguments as num?)?.toInt() ?? 0).clamp(0, 100);
        _onProgressChanged?.call(this, progress);
        return null;

      case 'onWindowFocus':
        _onWindowFocus?.call(this);
        return null;

      case 'onWindowBlur':
        _onWindowBlur?.call(this);
        return null;

      case 'onCursorChanged':
        final String cursorKind = call.arguments as String;
        _onCursorChanged?.call(this, cursorKind);
        return null;

      case 'onFontsIsLoaded':
        final String familiesJson = call.arguments as String? ?? '[]';
        List<String> families;
        try {
          families = (jsonDecode(familiesJson) as List<dynamic>)
              .map((e) => e.toString())
              .toList();
        } catch (_) {
          families = <String>[];
        }
        _onFontsIsLoaded?.call(this, families);
        return null;
      
      case 'onLoadResource':
        // Contrat identique sur toutes les plateformes : {url, data(base64)}
        // -> renvoie `null` (ressource inchangée) ou les octets de
        // remplacement en Base64. Voir [WebviewLoadResourceCallback].
        final map = Map<String, dynamic>.from(call.arguments as Map);
        final String resourceUrl = map['url'] as String? ?? '';
        final String base64Data = map['data'] as String? ?? '';
        final callback = _onLoadResource;
        if (callback == null || base64Data.isEmpty) return null;
        try {
          return await callback(this, resourceUrl, base64Decode(base64Data));
        } catch (e) {
          debugPrint('[webview_plus] onLoadResource a échoué pour $resourceUrl : $e');
          return null; // en cas d'erreur, la ressource d'origine est servie
        }

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
    return _channel.invokeMethod<void>('loadFlutterAsset', {'assetPath': assetPath});
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
    return _channel.invokeMethod<void>('loadHtmlString', {'html': html, 'baseUrl': baseUrl});
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
  Future<dynamic> evaluateJavascript(String code) {
    return _channel.invokeMethod<dynamic>('evaluateJavascript', {'code': code});
  }

  @override
  Future<String?> getHtml() {
    return _channel.invokeMethod<String>('getHtml');
  }

  @override
  Future<void> injectJsData(String jsData) {
    return _channel.invokeMethod<void>('injectJsData', {'jsData': jsData});
  }

  @override
  Future<void> injectJavascriptFileFromUrl(String urlFile) {
    return _channel.invokeMethod<void>('injectJavascriptFileFromUrl', {'url': urlFile});
  }

  @override
  Future<void> injectJavascriptFileFromAsset(String assetFilePath) {
    return _channel.invokeMethod<void>('injectJavascriptFileFromAsset', {'assetFilePath': assetFilePath});
  }

  @override
  Future<void> injectCssData(String cssData) {
    return _channel.invokeMethod<void>('injectCssData', {'cssData': cssData});
  }

  @override
  Future<void> injectCSSFileFromUrl(String urlFile) {
    return _channel.invokeMethod<void>('injectCSSFileFromUrl', {'url': urlFile});
  }

  @override
  Future<void> injectCSSFileFromAsset(String assetFilePath) {
    return _channel.invokeMethod<void>('injectCSSFileFromAsset', {'assetFilePath': assetFilePath});
  }

  @override
  /// Donne le focus au widget Webview côté Flutter. Renseigné par
  /// `WebviewWidget` (indispensable sur Linux/Windows, où le clavier arrive
  /// via un `Focus` Flutter puis est retransmis à la vue native).
  VoidCallback? focusRequestHandler;

  @override
  Future<void> requestFocus() async {
    try {
      focusRequestHandler?.call();
    } catch (_) {}
    try {
      await _channel.invokeMethod<void>('requestFocus');
    } on MissingPluginException {
      // Plateforme sans focus natif à donner : le focus Flutter suffit.
    } catch (_) {}
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