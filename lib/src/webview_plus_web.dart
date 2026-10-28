import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'webview_plus_controller.dart';
import 'webview_plus_initial_data.dart';
import 'webview_plus_settings.dart';
import 'webview_plus_user_script.dart';

int _viewIdCounter = 0;

/// URL absolue d'un asset Flutter (clé déclarée dans le `pubspec.yaml`,
/// ex. `assets/webapp/DocumentView.html`).
///
/// Flutter Web sert les assets sous `<base href>/assets/<clé>` : la clé
/// `assets/index.html` est donc servie à `assets/assets/index.html`. On
/// délègue ce calcul à `ui_web.assetManager` (même logique que
/// `rootBundle`, y compris avec un `assetBase` personnalisé), puis on
/// ancre le résultat sur `document.baseURI` plutôt que sur la route
/// courante du navigateur (sinon une route non-racine comme `/demo` casse
/// le chemin).
String _resolveAssetUrl(String assetKey) {
  final String key = assetKey.startsWith('/') ? assetKey.substring(1) : assetKey;
  final String url = ui_web.assetManager.getAssetUrl(key);
  return Uri.parse(web.document.baseURI).resolve(url).toString();
}

/// Résout un `initialFile` / `loadFile` sur le Web. Il n'y a pas de système
/// de fichiers : on accepte une URL (http/https/data/blob), ou un chemin
/// relatif servi par le même serveur (ex. un fichier du dossier `web/`).
/// Pour une webapp embarquée, préférer `initialAsset` (asset Flutter).
String _resolveFileUrl(String filePath) {
  final String lower = filePath.toLowerCase();
  if (lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('data:') ||
      lower.startsWith('blob:') ||
      lower.startsWith('about:')) {
    return filePath;
  }
  if (lower.startsWith('file://') || RegExp(r'^[a-z]:[\\/]').hasMatch(lower)) {
    web.console.warn(
        '[webview_plus] "$filePath" est un chemin du système de fichiers : '
        "inaccessible depuis un navigateur. Utilisez un asset Flutter "
        "(initialAsset) ou une URL http(s)."
            .toJS);
    return filePath;
  }
  return Uri.parse(web.document.baseURI).resolve(filePath).toString();
}

// -- JavaScript injecté dans l'iframe ---------------------------------------
//
// Injecté AU DÉMARRAGE du document (voir `_tryInject`), pas seulement au
// `load` : une page comme DocumentView.js appelle
// `window.webview_plus.callHandler(...)` dès son initialisation.
const String _bridgeJs = r'''
(function () {
  if (window.__wpInjected) return;
  window.__wpInjected = true;
  var VIEW = __VIEW__;
  function post(o) {
    o.__wpView = VIEW;
    o.url = String(window.location.href);
    window.parent.postMessage(o, '*');
  }
  window.WebviewPlusChannel = {
    postMessage: function (msg) { post({ __webviewPlusMsg: true, message: String(msg) }); }
  };
  var pending = {};
  var nextId = 1;
  window.webview_plus = window.webview_plus || {};
  window.webview_plus.callHandler = function (name) {
    var args = Array.prototype.slice.call(arguments, 1);
    var id = 'wpc_' + (nextId++);
    return new Promise(function (resolve, reject) {
      pending[id] = { resolve: resolve, reject: reject };
      post({ __webviewPlusCall: true, id: id, handlerName: String(name),
             argsJson: JSON.stringify(args) });
    });
  };
  window.webview_plus.__resolve = function (id, json) {
    var p = pending[id]; if (!p) return; delete pending[id];
    try { p.resolve(JSON.parse(json)); } catch (e) { p.resolve(json); }
  };
  window.webview_plus.__reject = function (id, message) {
    var p = pending[id]; if (!p) return; delete pending[id];
    p.reject(new Error(message));
  };
  window.addEventListener('beforeunload', function () { post({ __webviewPlusUnload: true }); });
  // Le document vient d'être validé et commence à se charger.
  post({ __webviewPlusContent: true });
  // Premier rendu : deux requestAnimationFrame après le démarrage.
  try {
    requestAnimationFrame(function () {
      requestAnimationFrame(function () { post({ __webviewPlusCommitVisible: true }); });
    });
  } catch (e) { post({ __webviewPlusCommitVisible: true }); }
  document.addEventListener('DOMContentLoaded', function () { post({ __webviewPlusDom: true }); });
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(function () {
      var fams = [];
      try {
        document.fonts.forEach(function (f) {
          if (f.status === 'loaded' && fams.indexOf(f.family) < 0) fams.push(f.family);
        });
      } catch (e) {}
      post({ __webviewPlusFonts: true, familiesJson: JSON.stringify(fams) });
    });
  }
})();
''';

const String _cssJs = r'''
(function () {
  var css = __CSS__;
  function add() {
    var st = document.createElement('style');
    st.id = '__wp_initial_css';
    st.appendChild(document.createTextNode(css));
    (document.head || document.documentElement).appendChild(st);
  }
  if (document.head || document.documentElement) add();
  else document.addEventListener('DOMContentLoaded', add);
})();
''';

String _cssColor(int argb) {
  final int a = (argb >> 24) & 0xFF;
  final int r = (argb >> 16) & 0xFF;
  final int g = (argb >> 8) & 0xFF;
  final int b = argb & 0xFF;
  return 'rgba($r,$g,$b,${(a / 255).toStringAsFixed(3)})';
}

/// Contrôleur Web : pilote directement un `HTMLIFrameElement`.
///
/// Même API Dart que le contrôleur natif. Limites propres au navigateur :
/// - `evaluateJavascript`, l'injection, `callHandler`... exigent une page
///   **same-origin** (assets Flutter, `srcdoc`, même serveur). Une page
///   d'un autre domaine s'affiche mais reste opaque (isolation
///   cross-origin) ;
/// - un site qui interdit l'iframe (`X-Frame-Options`, CSP
///   `frame-ancestors`) ne peut pas être affiché ;
/// - `onNavigationRequest` est informatif : une navigation ne peut pas être
///   bloquée a priori.
class WebviewPlusWebController implements WebviewPlusController {
  WebviewPlusWebController(
    this._iframe, {
    required void Function(Uri target) onNavigationStart,
  }) : _onNavigationStart = onNavigationStart;

  final web.HTMLIFrameElement _iframe;
  final void Function(Uri target) _onNavigationStart;

  final Map<String, JavaScriptHandlerCallback> _javaScriptHandlers =
      <String, JavaScriptHandlerCallback>{};

  /// `true` dès qu'un chargement a été demandé (par Dart ou par
  /// `initialUrl`...), pour ne pas écraser un `loadUrl` appelé dans
  /// `onWebViewCreated` par le contenu initial.
  bool loadRequested = false;

  // Historique approximatif (l'API Web ne l'expose pas pour une iframe).
  int _historyDepth = 0;
  int _forwardDepth = 0;
  int _pendingTraversal = 0; // -1 back, +1 forward, 0 navigation normale
  bool _pendingReload = false;
  bool _firstLoadDone = false;

  /// Appelé par la vue à chaque événement `load` de l'iframe.
  void noteLoaded() {
    if (!_firstLoadDone) {
      _firstLoadDone = true;
    } else if (_pendingReload) {
      // rechargement : l'historique ne change pas
    } else if (_pendingTraversal < 0) {
      _historyDepth = (_historyDepth - 1).clamp(0, 1 << 30);
      _forwardDepth++;
    } else if (_pendingTraversal > 0) {
      _forwardDepth = (_forwardDepth - 1).clamp(0, 1 << 30);
      _historyDepth++;
    } else {
      _historyDepth++;
      _forwardDepth = 0;
    }
    _pendingTraversal = 0;
    _pendingReload = false;
  }

  JSObject? get _win {
    final web.Window? win = _iframe.contentWindow;
    return win == null ? null : win as JSObject;
  }

  JSAny? _eval(String code) {
    final JSObject? win = _win;
    if (win == null) return null;
    return win.callMethod<JSAny?>('eval'.toJS, code.toJS);
  }

  void _switchToSrcMode(String url) {
    loadRequested = true;
    _onNavigationStart(Uri.parse(url));
    _iframe.removeAttribute('srcdoc');
    _iframe.src = url;
  }

  void _switchToSrcDocMode(String html, {String? baseUrl}) {
    loadRequested = true;
    _onNavigationStart(Uri.parse('about:srcdoc'));
    final String content = (baseUrl != null && baseUrl.isNotEmpty)
        ? '<base href="${const HtmlEscape(HtmlEscapeMode.attribute).convert(baseUrl)}">$html'
        : html;
    _iframe.removeAttribute('src');
    _iframe.setAttribute('srcdoc', content);
  }

  @override
  Future<void> loadUrl(String url) async => _switchToSrcMode(url);

  @override
  Future<void> loadFlutterAsset(String assetPath) async =>
      _switchToSrcMode(_resolveAssetUrl(assetPath));

  @override
  Future<void> loadFile(String filePath) async =>
      _switchToSrcMode(_resolveFileUrl(filePath));

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async =>
      _switchToSrcDocMode(html, baseUrl: baseUrl);

  @override
  Future<void> loadData(
    String data, {
    String mimeType = 'text/html',
    String encoding = 'utf8',
    String? baseUrl,
  }) async {
    if (mimeType.toLowerCase().startsWith('text/html')) {
      _switchToSrcDocMode(data, baseUrl: baseUrl);
    } else {
      _switchToSrcMode('data:$mimeType;charset=utf-8,${Uri.encodeComponent(data)}');
    }
  }

  @override
  Future<dynamic> evaluateJavascript(String code) async {
    try {
      return _eval(code)?.dartify();
    } catch (_) {
      return null; // page cross-origin ou pas encore chargée
    }
  }

  @override
  Future<String?> getHtml() async {
    final dynamic html = await evaluateJavascript('document.documentElement.outerHTML');
    return html?.toString();
  }

  static String _js(String s) => jsonEncode(s);

  @override
  Future<void> injectJsData(String jsData) async {
    await evaluateJavascript(
        "(function(){var s=document.createElement('script');s.textContent=${_js(jsData)};(document.head||document.documentElement).appendChild(s);})();");
  }

  @override
  Future<void> injectJavascriptFileFromUrl(String urlFile) async {
    await evaluateJavascript(
        "(function(){var s=document.createElement('script');s.src=${_js(urlFile)};(document.head||document.documentElement).appendChild(s);})();");
  }

  @override
  Future<void> injectJavascriptFileFromAsset(String assetFilePath) =>
      injectJavascriptFileFromUrl(_resolveAssetUrl(assetFilePath));

  @override
  Future<void> injectCssData(String cssData) async {
    await evaluateJavascript(
        "(function(){var s=document.createElement('style');s.textContent=${_js(cssData)};(document.head||document.documentElement).appendChild(s);})();");
  }

  @override
  Future<void> injectCSSFileFromUrl(String urlFile) async {
    await evaluateJavascript(
        "(function(){var l=document.createElement('link');l.rel='stylesheet';l.href=${_js(urlFile)};(document.head||document.documentElement).appendChild(l);})();");
  }

  @override
  Future<void> injectCSSFileFromAsset(String assetFilePath) =>
      injectCSSFileFromUrl(_resolveAssetUrl(assetFilePath));

  @override
  Future<void> requestFocus() async {
    try {
      _iframe.focus();
      (_win)?.callMethod<JSAny?>('focus'.toJS);
    } catch (_) {}
  }

  @override
  Future<void> reload() async {
    _pendingReload = true;
    _onNavigationStart(Uri.parse(_iframe.hasAttribute('srcdoc') ? 'about:srcdoc' : _iframe.src));
    try {
      _eval('window.location.reload()');
    } catch (_) {
      // cross-origin : on ré-assigne la source
      if (_iframe.hasAttribute('srcdoc')) {
        final String? doc = _iframe.getAttribute('srcdoc');
        _iframe.setAttribute('srcdoc', doc ?? '');
      } else {
        _iframe.src = _iframe.src;
      }
    }
  }

  @override
  Future<void> goBack() async {
    if (_historyDepth <= 0) return;
    _pendingTraversal = -1;
    _onNavigationStart(Uri.parse('about:blank'));
    try {
      _eval('window.history.back()');
    } catch (_) {
      _pendingTraversal = 0;
    }
  }

  @override
  Future<void> goForward() async {
    if (_forwardDepth <= 0) return;
    _pendingTraversal = 1;
    _onNavigationStart(Uri.parse('about:blank'));
    try {
      _eval('window.history.forward()');
    } catch (_) {
      _pendingTraversal = 0;
    }
  }

  @override
  Future<bool> canGoBack() async => _historyDepth > 0;

  @override
  Future<bool> canGoForward() async => _forwardDepth > 0;

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
  bool hasJavaScriptHandler(String handlerName) =>
      _javaScriptHandlers.containsKey(handlerName);

  /// Répond à un `window.webview_plus.callHandler(...)` de la page : le
  /// résultat (ou l'erreur) est renvoyé en ré-évaluant du JS dans l'iframe.
  Future<void> respondToJsCall(
      String callId, String handlerName, List<dynamic> args) async {
    final JavaScriptHandlerCallback? handler = _javaScriptHandlers[handlerName];
    if (handler == null) {
      await evaluateJavascript(
          'window.webview_plus && window.webview_plus.__reject && '
          'window.webview_plus.__reject(${_js(callId)}, ${_js('Aucun handler JavaScript nommé "$handlerName" enregistré côté Dart (addJavaScriptHandler).')});');
      return;
    }
    try {
      final dynamic result = await handler(args);
      await evaluateJavascript(
          'window.webview_plus && window.webview_plus.__resolve && '
          'window.webview_plus.__resolve(${_js(callId)}, ${_js(jsonEncode(result))});');
    } catch (e) {
      await evaluateJavascript(
          'window.webview_plus && window.webview_plus.__reject && '
          'window.webview_plus.__reject(${_js(callId)}, ${_js(e.toString())});');
    }
  }
}

/// Construit le widget Web (HtmlElementView + iframe) utilisé par
/// `WebviewWidget` lorsque `kIsWeb` est vrai.
Widget buildWebview({
  required String? initialUrl,
  required String? initialAsset,
  String? initialFile,
  WebviewInitialData? initialData,
  String? initialCss,
  WebviewSettings initialSettings = const WebviewSettings(),
  required WebviewMessageCallback? onMessageReceived,
  required NavigationRequestCallback? onNavigationRequest,
  WebviewLoadCallback? onLoadStart,
  WebviewLoadCallback? onLoadStop,
  WebviewLoadCallback? onDOMContentLoaded,
  WebviewErrorCallback? onReceivedError,
  WebviewFontsLoadedCallback? onFontsIsLoaded,
  WebviewLoadErrorCallback? onLoadError,
  WebviewLoadCallback? onContentLoading,
  WebviewLoadCallback? onPageCommitVisible,
  WebviewProgressCallback? onProgressChanged,
  required void Function(WebviewPlusController controller) onControllerCreated,
}) {
  return _WebviewPlusIframeView(
    initialUrl: initialUrl,
    initialAsset: initialAsset,
    initialFile: initialFile,
    initialData: initialData,
    initialCss: initialCss,
    initialSettings: initialSettings,
    onMessageReceived: onMessageReceived,
    onNavigationRequest: onNavigationRequest,
    onLoadStart: onLoadStart,
    onLoadStop: onLoadStop,
    onDOMContentLoaded: onDOMContentLoaded,
    onFontsIsLoaded: onFontsIsLoaded,
    onContentLoading: onContentLoading,
    onPageCommitVisible: onPageCommitVisible,
    onProgressChanged: onProgressChanged,
    onControllerCreated: onControllerCreated,
  );
}

class _WebviewPlusIframeView extends StatefulWidget {
  const _WebviewPlusIframeView({
    required this.initialUrl,
    required this.initialAsset,
    required this.initialFile,
    required this.initialData,
    required this.initialCss,
    required this.initialSettings,
    required this.onMessageReceived,
    required this.onNavigationRequest,
    required this.onLoadStart,
    required this.onLoadStop,
    required this.onDOMContentLoaded,
    required this.onFontsIsLoaded,
    required this.onContentLoading,
    required this.onPageCommitVisible,
    required this.onProgressChanged,
    required this.onControllerCreated,
  });

  final String? initialUrl;
  final String? initialAsset;
  final String? initialFile;
  final WebviewInitialData? initialData;
  final String? initialCss;
  final WebviewSettings initialSettings;
  final WebviewMessageCallback? onMessageReceived;
  final NavigationRequestCallback? onNavigationRequest;
  final WebviewLoadCallback? onLoadStart;
  final WebviewLoadCallback? onLoadStop;
  final WebviewLoadCallback? onDOMContentLoaded;
  final WebviewFontsLoadedCallback? onFontsIsLoaded;
  final WebviewLoadCallback? onContentLoading;
  final WebviewLoadCallback? onPageCommitVisible;
  final WebviewProgressCallback? onProgressChanged;
  final void Function(WebviewPlusController controller) onControllerCreated;

  @override
  State<_WebviewPlusIframeView> createState() => _WebviewPlusIframeViewState();
}

class _WebviewPlusIframeViewState extends State<_WebviewPlusIframeView> {
  late final String _viewType = 'webview_plus_iframe_${_viewIdCounter++}';
  late final web.HTMLIFrameElement _iframe;
  late final WebviewPlusWebController _controller;

  StreamSubscription<web.MessageEvent>? _messageSub;
  StreamSubscription<web.Event>? _loadSub;
  Timer? _pollTimer;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();

    _iframe = web.HTMLIFrameElement()
      ..style.border = 'none'
      ..style.height = '100%'
      ..style.width = '100%'
      ..allow = 'autoplay; camera; microphone; fullscreen; clipboard-write';
    final bg = widget.initialSettings.initialBackgroundColor;
    if (bg != null) {
      _iframe.style.backgroundColor = _cssColor(bg.toARGB32());
    }

    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int id) => _iframe);

    _controller = WebviewPlusWebController(
      _iframe,
      onNavigationStart: _handleNavigationStart,
    );

    _messageSub = web.window.onMessage.listen(_handleMessage);
    _loadSub = _iframe.onLoad.listen((_) => _handleLoad());

    // Comme sur les plateformes natives : le contrôleur est fourni AVANT le
    // premier chargement, pour que `onWebViewCreated` puisse enregistrer
    // ses handlers JS (addJavaScriptHandler) avant que la page ne démarre.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      widget.onControllerCreated(_controller);
      if (!_controller.loadRequested) {
        _applyInitialContent();
      }
    });
  }

  void _applyInitialContent() {
    if (widget.initialAsset != null) {
      _controller.loadFlutterAsset(widget.initialAsset!);
    } else if (widget.initialFile != null) {
      _controller.loadFile(widget.initialFile!);
    } else if (widget.initialUrl != null) {
      _controller.loadUrl(widget.initialUrl!);
    } else if (widget.initialData != null) {
      final d = widget.initialData!;
      _controller.loadData(d.data,
          mimeType: d.mimeType, encoding: d.encoding, baseUrl: d.baseUrl);
    }
  }

  // -- Cycle de chargement ---------------------------------------------------

  void _handleNavigationStart(Uri target) {
    widget.onLoadStart?.call(_controller, target);
    // Une iframe n'expose pas de progression réelle : 10 % au départ,
    // 100 % au `load` (même séquence que les autres plateformes aux
    // extrémités).
    widget.onProgressChanged?.call(_controller, 10);
    _startInjectionPoll();
  }

  Uri _currentUri() {
    try {
      final String? href = _iframe.contentWindow?.location.href;
      if (href != null && href.isNotEmpty) return Uri.parse(href);
    } catch (_) {/* cross-origin */}
    return Uri.parse(_iframe.hasAttribute('srcdoc') ? 'about:srcdoc' : _iframe.src);
  }

  Future<void> _handleLoad() async {
    if (_disposed || !_controller.loadRequested) return;
    final Uri current = _currentUri();
    if (current.toString() == 'about:blank') return; // load du document vide initial
    _pollTimer?.cancel();
    _tryInject(); // filet de sécurité si le démarrage de document a été manqué
    _controller.noteLoaded();
    final Uri uri = current;
    if (widget.onNavigationRequest != null) {
      try {
        await widget.onNavigationRequest!(_controller, uri);
      } catch (_) {}
    }
    widget.onProgressChanged?.call(_controller, 100);
    widget.onLoadStop?.call(_controller, uri);
  }

  // -- Injection au démarrage du document -----------------------------------
  //
  // Une iframe ne signale pas la création d'un nouveau document : on sonde
  // toutes les 4 ms après une navigation jusqu'à voir un document neuf
  // (sans le drapeau `__wpInjected`) et on y injecte le pont avant que ses
  // scripts ne s'exécutent. Pour une page cross-origin, l'accès échoue et la
  // sonde s'arrête (aucun pont possible, comme n'importe quelle iframe).

  void _startInjectionPoll() {
    _pollTimer?.cancel();
    int ticks = 0;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 4), (Timer t) {
      if (_disposed || ++ticks > 2500 || _tryInject()) {
        t.cancel();
      }
    });
  }

  /// `true` si la sonde doit s'arrêter (injecté, ou page inaccessible).
  bool _tryInject() {
    try {
      final web.Window? win = _iframe.contentWindow;
      if (win == null) return false;
      final String href = win.location.href; // lève en cross-origin
      if (href == 'about:blank') {
        return false; // document initial vide : navigation pas encore validée
      }
      final JSObject w = win as JSObject;
      final JSAny? flag = w['__wpInjected'];
      if (flag != null && flag.dartify() == true) {
        return false; // ancien document : on attend le nouveau
      }
      w.callMethod<JSAny?>('eval'.toJS, _buildInjectionScript().toJS);
      return true;
    } catch (_) {
      return true; // cross-origin : rien à injecter
    }
  }

  String _buildInjectionScript() {
    final settings = widget.initialSettings;
    final StringBuffer js = StringBuffer(
        _bridgeJs.replaceAll('__VIEW__', jsonEncode(_viewType)));

    final StringBuffer css = StringBuffer();
    if (widget.initialCss != null) css.writeln(widget.initialCss);
    final sel = settings.selectionHandleColor;
    final selText = settings.selectionTextColor;
    if (sel != null || selText != null) {
      css.write('::selection{');
      if (sel != null) css.write('background:${_cssColor(sel.toARGB32())};');
      if (selText != null) css.write('color:${_cssColor(selText.toARGB32())};');
      css.writeln('}');
    }
    if (settings.hideNativeScrollbars) {
      css.writeln('::-webkit-scrollbar{display:none;}html{scrollbar-width:none;}');
    }
    if (css.isNotEmpty) {
      js.write(_cssJs.replaceAll('__CSS__', jsonEncode(css.toString())));
    }
    if (settings.disableContextMenu) {
      js.write("document.addEventListener('contextmenu',function(e){e.preventDefault();},true);");
    }

    for (final UserScript script in settings.initialUserScripts) {
      final String src = jsonEncode(script.source);
      if (script.injectionTime == UserScriptInjectionTime.atDocumentStart) {
        js.write('try{(0,eval)($src);}catch(e){console.error(e);}');
      } else {
        js.write('(function(){var run=function(){try{(0,eval)($src);}catch(e){console.error(e);}};'
            "if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',run);else run();})();");
      }
    }
    return js.toString();
  }

  // -- Messages iframe -> Dart ---------------------------------------------

  String? _str(JSObject o, String key) {
    final JSAny? v = o[key];
    return (v != null && v.isA<JSString>()) ? (v as JSString).toDart : null;
  }

  void _handleMessage(web.MessageEvent event) {
    if (_disposed) return;
    final JSAny? data = event.data;
    if (data == null) return;

    // Messages texte « legacy » (page qui appelle elle-même
    // window.parent.postMessage('...')) : impossibles à rattacher à une
    // iframe précise, transmis tels quels.
    if (data.isA<JSString>()) {
      widget.onMessageReceived?.call(_controller, (data as JSString).toDart);
      return;
    }
    if (!data.isA<JSObject>()) return;
    final JSObject obj = data as JSObject;

    final String? view = _str(obj, '__wpView');
    if (view == null) {
      final String? legacy = _str(obj, 'message');
      if (legacy != null) widget.onMessageReceived?.call(_controller, legacy);
      return;
    }
    if (view != _viewType) return; // message d'une autre Webview

    Uri url() => Uri.tryParse(_str(obj, 'url') ?? '') ?? _currentUri();

    try {
      if (obj.has('__webviewPlusCall')) {
        final String? id = _str(obj, 'id');
        final String? name = _str(obj, 'handlerName');
        if (id == null || name == null) return;
        List<dynamic> args = const <dynamic>[];
        final String? argsJson = _str(obj, 'argsJson');
        if (argsJson != null && argsJson.isNotEmpty) {
          final dynamic decoded = jsonDecode(argsJson);
          if (decoded is List) args = decoded;
        }
        unawaited(_controller.respondToJsCall(id, name, args));
      } else if (obj.has('__webviewPlusMsg')) {
        final String? message = _str(obj, 'message');
        if (message != null) widget.onMessageReceived?.call(_controller, message);
      } else if (obj.has('__webviewPlusContent')) {
        widget.onContentLoading?.call(_controller, url());
      } else if (obj.has('__webviewPlusCommitVisible')) {
        widget.onPageCommitVisible?.call(_controller, url());
      } else if (obj.has('__webviewPlusDom')) {
        widget.onDOMContentLoaded?.call(_controller, url());
      } else if (obj.has('__webviewPlusFonts')) {
        final String? json = _str(obj, 'familiesJson');
        final List<String> families = json == null
            ? <String>[]
            : (jsonDecode(json) as List).map((e) => e.toString()).toList();
        widget.onFontsIsLoaded?.call(_controller, families);
      } else if (obj.has('__webviewPlusUnload')) {
        // Navigation déclenchée DANS la page (clic sur un lien...) : on
        // relance la sonde pour injecter le pont dans le document suivant.
        widget.onLoadStart?.call(_controller, url());
        _startInjectionPoll();
      }
    } catch (_) {
      // Message mal formé : ignoré.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _messageSub?.cancel();
    _loadSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
