import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_plus/webview_plus.dart';

void main() {
  runApp(const MyApp());
}

/// Contrôle le thème clair/sombre depuis n'importe où dans l'arbre de
/// widgets (voir le bouton de bascule dans l'`AppBar`).
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static const _seedColor = Color(0xFF6750A4);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'Webview Plus — Démo',
          themeMode: mode,
          theme: ThemeData(
            colorSchemeSeed: _seedColor,
            useMaterial3: true,
            brightness: Brightness.light,
            visualDensity: VisualDensity.standard,
          ),
          darkTheme: ThemeData(
            colorSchemeSeed: _seedColor,
            useMaterial3: true,
            brightness: Brightness.dark,
          ),
          debugShowCheckedModeBanner: false,
          home: const WebviewDemoPage(),
        );
      },
    );
  }
}

class WebviewDemoPage extends StatefulWidget {
  const WebviewDemoPage({super.key});

  @override
  State<WebviewDemoPage> createState() => _WebviewDemoPageState();
}

class _WebviewDemoPageState extends State<WebviewDemoPage>
    with SingleTickerProviderStateMixin {
  WebviewPlusController? _controller;
  late final TabController _tabController =
      TabController(length: 4, vsync: this);

  // -- Barre d'adresse & inputs ---------------------------------------------
  final TextEditingController _urlFieldController =
      TextEditingController(text: 'https://flutter.dev');
  final TextEditingController _jsFieldController =
      TextEditingController(text: "document.body.style.backgroundColor = 'red'");
  final TextEditingController _filePathController = TextEditingController();
  final TextEditingController _uaSuffixController =
      TextEditingController(text: 'MyFlutterApp/1.0');
  final TextEditingController _userAgentController = TextEditingController();
  final TextEditingController _initialCssController = TextEditingController(
    text: 'body { font-family: system-ui; }\n::selection { background: orange; }',
  );
  final TextEditingController _rawJsController =
      TextEditingController(text: "alert('Injecté via injectJsData !')");
  final TextEditingController _rawCssController = TextEditingController(
    text: 'body { outline: 4px dashed hotpink; }',
  );

  // -- État / logs affichés en bas d'écran ---------------------------------
  String _status = 'Inactif';
  bool _isLoading = false;
  final List<String> _log = <String>[];

  // -- Général (toutes plateformes) ----------------------------------------
  bool _javaScriptEnabled = true;
  bool _domStorageEnabled = true;
  bool _supportZoom = true;
  bool _mediaPlaybackRequiresUserGesture = true;
  bool _transparentBackground = false;
  Color? _initialBackgroundColor = Colors.cyan;
  bool _isInspectable = true;
  bool _cacheEnabled = true;
  bool _incognito = false;
  bool _javaScriptCanOpenWindowsAutomatically = false;
  bool _hideNativeScrollbars = false;
  bool _disableKeyboardResize = false;

  // -- Menu contextuel & sélection ------------------------------------------
  bool _disableContextMenu = false;
  bool _disableLongPressLinks = false;
  Color? _selectionTextColor = Colors.pink;
  Color? _selectionHandleColor = Colors.orange;
  final Set<DefaultContextMenuItem> _disabledDefaultItems = <DefaultContextMenuItem>{};
  bool _disableLinkHoverPreview = true;
  bool _disablePrinting = false;

  // -- Android ---------------------------------------------------------------
  bool _allowFileAccess = true;
  bool _allowContentAccess = true;
  bool _builtInZoomControls = true;
  bool _displayZoomControls = false;
  int _textZoom = 100;
  bool _geolocationEnabled = true;
  bool _thirdPartyCookiesEnabled = true;
  bool _forceDarkMode = false;
  OverScrollMode _overScrollMode = OverScrollMode.ifContentScrolls;
  int _initialScale = 0; // 0 = valeur par défaut / non défini
  bool _safeBrowsingEnabled = true;
  bool _allowMixedContent = false;
  AndroidPlatformViewType _androidPlatformViewType =
      AndroidPlatformViewType.surfaceComposition;
  WebviewContentMode _webviewContentMode = WebviewContentMode.recommended;

  // -- iOS / macOS ------------------------------------------------------------
  int _minimumFontSize = 8;
  bool _allowsInlineMediaPlayback = true;
  bool _allowsPictureInPicture = true;
  bool _bounces = true;
  bool _allowsBackForwardNavigationGestures = false;
  bool _allowsLinkPreview = false;
  bool _allowFileAccessFromFileURLs = false;
  bool _allowUniversalAccessFromFileURLs = false;

  // -- Scrollbars (Windows / macOS / Linux) -----------------------------------
  DesktopScrollbarThemeMode _scrollbarThemeMode = DesktopScrollbarThemeMode.auto;
  Color _scrollbarTrackColor = Colors.grey.shade300;
  Color _scrollbarThumbColor = Colors.grey.shade600;
  double _scrollbarWidth = 10.0;

  // -- Cache & Debug (globaux, indépendants de la Webview affichée) ----------
  bool _webContentsDebuggingEnabled = true;
  bool _cacheActionInProgress = false;

  int _webviewGeneration = 0;

  void _pushLog(String line) {
    if (!mounted) return; // Sécurité si le widget est détruit entre-temps

    final now = DateTime.now();
    final timestamp = '${now.hour.toString().padLeft(2, '0')}:'
                      '${now.minute.toString().padLeft(2, '0')}:'
                      '${now.second.toString().padLeft(2, '0')}';

    setState(() {
      _log.insert(0, '$timestamp · $line');
      if (_log.length > 40) _log.removeLast();
    });
  }

  // Construit l'objet WebviewSettings avec l'intégralité des paramètres
  // exposés par le package.
  WebviewSettings get _currentSettings => WebviewSettings(
        // Général
        javaScriptEnabled: _javaScriptEnabled,
        domStorageEnabled: _domStorageEnabled,
        supportZoom: _supportZoom,
        mediaPlaybackRequiresUserGesture: _mediaPlaybackRequiresUserGesture,
        transparentBackground: _transparentBackground,
        initialBackgroundColor: _initialBackgroundColor,
        userAgent: _userAgentController.text.trim().isEmpty
            ? null
            : _userAgentController.text.trim(),
        isInspectable: _isInspectable,
        cacheEnabled: _cacheEnabled,
        incognito: _incognito,
        applicationNameForUserAgent: _uaSuffixController.text.trim().isEmpty
            ? null
            : _uaSuffixController.text.trim(),
        javaScriptCanOpenWindowsAutomatically:
            _javaScriptCanOpenWindowsAutomatically,
        hideNativeScrollbars: _hideNativeScrollbars,
        disableKeyboardResize: _disableKeyboardResize,

        // Menu contextuel & sélection
        disableContextMenu: _disableContextMenu,
        disableLongPressContextMenuOnLinks: _disableLongPressLinks,
        selectionTextColor: _selectionTextColor,
        selectionHandleColor: _selectionHandleColor,
        disabledDefaultContextMenuItems: _disabledDefaultItems,
        disableLinkHoverPreview: _disableLinkHoverPreview,
        disablePrinting: _disablePrinting,

        // Android
        allowFileAccess: _allowFileAccess,
        allowContentAccess: _allowContentAccess,
        builtInZoomControls: _builtInZoomControls,
        displayZoomControls: _displayZoomControls,
        textZoom: _textZoom,
        geolocationEnabled: _geolocationEnabled,
        thirdPartyCookiesEnabled: _thirdPartyCookiesEnabled,
        forceDarkMode: _forceDarkMode,
        overScrollMode: _overScrollMode,
        initialScale: _initialScale > 0 ? _initialScale : null,
        safeBrowsingEnabled: _safeBrowsingEnabled,
        allowMixedContent: _allowMixedContent,
        androidPlatformViewType: _androidPlatformViewType,
        webviewContentMode: _webviewContentMode,

        // iOS / macOS
        minimumFontSize: _minimumFontSize,
        allowsInlineMediaPlayback: _allowsInlineMediaPlayback,
        allowsPictureInPicture: _allowsPictureInPicture,
        bounces: _bounces,
        allowsBackForwardNavigationGestures:
            _allowsBackForwardNavigationGestures,
        allowsLinkPreview: _allowsLinkPreview,
        allowFileAccessFromFileURLs: _allowFileAccessFromFileURLs,
        allowUniversalAccessFromFileURLs: _allowUniversalAccessFromFileURLs,

        // Scrollbars (Windows / macOS / Linux)
        windowsScrollbarTheme: _windowsScrollbarTheme,
      );

  DesktopScrollbarTheme get _windowsScrollbarTheme => DesktopScrollbarTheme(
        themeMode: _scrollbarThemeMode,
        trackColor: _scrollbarTrackColor,
        thumbColor: _scrollbarThumbColor,
        width: _scrollbarWidth,
      );

  List<ContextMenuItem> get _contextMenuItems => <ContextMenuItem>[
        ContextMenuItem(
          id: 'search',
          name: 'Rechercher',
          action: (selectedText) {
            _pushLog('Menu perso [Rechercher] texte="$selectedText"');
          },
        ),
        ContextMenuItem(
          id: 'translate',
          name: 'Traduire',
          action: (selectedText) {
            _pushLog('Menu perso [Traduire] texte="$selectedText"');
          },
        ),
      ];

  void _registerHandlers(WebviewPlusController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'fromJs',
      callback: (args) async {
        _pushLog('JS → Dart [fromJs] args=$args');
        return <String, dynamic>{
          'ok': true,
          'reçu': args,
          'horodatage': DateTime.now().toIso8601String(),
          'message': 'Bonjour depuis le Dart !',
        };
      },
    );
  }

  // -- Actions : navigation / chargement --------------------------------------

  Future<void> _go() async {
    final url = _urlFieldController.text.trim();
    if (url.isEmpty) return;
    await _controller?.loadUrl(
      url.startsWith('http') ? url : 'https://$url',
    );
  }

  Future<void> _runJs() async {
    final code = _jsFieldController.text.trim();
    if (code.isEmpty) return;
    final result = await _controller?.evaluateJavascript(code);
    _pushLog('evaluateJavascript("$code") → $result');
  }

  Future<void> _getHtml() async {
    final html = await _controller?.getHtml();
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('HTML de la page'),
        content: SizedBox(
          width: 420,
          height: 320,
          child: SingleChildScrollView(
            child: SelectableText(
              html == null
                  ? '(vide)'
                  : (html.length > 3000 ? '${html.substring(0, 3000)}…' : html),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadHtmlFile() async {
    await _controller?.loadFlutterAsset('assets/index.html');
  }

  Future<void> _loadRawData() async {
    await _controller?.loadData(
      '''
      <html>
        <body style="font-family: sans-serif; padding: 24px;">
          <h1>Chargé via loadData()</h1>
          <p>Ceci est du HTML brut injecté directement, sans passer par une URL.</p>
        </body>
      </html>
      ''',
      mimeType: 'text/html',
      encoding: 'utf8',
    );
  }

  Future<void> _loadFile() async {
    final path = _filePathController.text.trim();
    if (path.isEmpty) return;
    await _controller?.loadFile(path);
  }

  // -- Actions : injection distante (fichier via URL) -------------------------

  Future<void> _injectRemoteJs() async {
    await _controller?.injectJavascriptFileFromUrl(
      'https://code.jquery.com/jquery-3.7.1.min.js',
    );
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final result = await _controller?.evaluateJavascript('typeof window.jQuery');
    _pushLog('Injection JS distante → typeof jQuery = $result');
  }

  Future<void> _injectRemoteCss() async {
    await _controller?.injectCSSFileFromUrl(
      'data:text/css;base64,Ym9keSB7IGZpbHRlcjogaW52ZXJ0KDEpOyB9',
    );
    _pushLog('CSS distant injecté (inversion des couleurs de la page).');
  }

  // -- Actions : injection brute (injectJsData / injectCssData) ---------------

  Future<void> _injectRawJs() async {
    final code = _rawJsController.text.trim();
    if (code.isEmpty) return;
    await _controller?.injectJsData(code);
    _pushLog('injectJsData("$code") exécuté.');
  }

  Future<void> _injectRawCss() async {
    final css = _rawCssController.text.trim();
    if (css.isEmpty) return;
    await _controller?.injectCssData(css);
    _pushLog('injectCssData(...) appliqué (${css.length} caractères).');
  }

  // -- Cache & Debug (API globales, indépendantes de la Webview affichée) -----

  Future<void> _runCacheAction(String label, Future<void> Function() action) async {
    setState(() => _cacheActionInProgress = true);
    try {
      await action();
      _pushLog('WebviewCacheManager.$label() : ok.');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label : effectué.'), duration: const Duration(seconds: 2)),
      );
    } catch (e) {
      _pushLog('WebviewCacheManager.$label() : erreur — $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label : erreur — $e'), duration: const Duration(seconds: 3)),
      );
    } finally {
      if (mounted) setState(() => _cacheActionInProgress = false);
    }
  }

  Future<void> _toggleWebContentsDebugging(bool enabled) async {
    setState(() => _webContentsDebuggingEnabled = enabled);
    await WebviewBaseController.setWebContentsDebuggingEnabled(enabled);
    _pushLog('setWebContentsDebuggingEnabled($enabled)');
  }

  void _applySettingsAndRebuild() {
    setState(() {
      _webviewGeneration++; // force la recréation de la Webview native
      _status = 'Réglages appliqués, Webview recréée.';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Webview recréée avec les nouveaux réglages.'), duration: Duration(seconds: 2)),
    );
  }

  // -- Sélecteur de couleur -----------------------------------------------

  static const List<Color> _palette = [
    Colors.red,
    Colors.pink,
    Colors.purple,
    Colors.deepPurple,
    Colors.indigo,
    Colors.blue,
    Colors.lightBlue,
    Colors.cyan,
    Colors.teal,
    Colors.green,
    Colors.lightGreen,
    Colors.lime,
    Colors.yellow,
    Colors.amber,
    Colors.orange,
    Colors.deepOrange,
    Colors.brown,
    Colors.grey,
    Colors.blueGrey,
    Colors.black,
    Colors.white,
  ];

  Future<Color?> _pickColor(String title, Color? current, {bool nullable = false}) async {
    return showDialog<Color?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 320,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (nullable)
                _ColorSwatch(
                  color: null,
                  selected: current == null,
                  onTap: () => Navigator.of(context).pop<Color?>(null),
                ),
              for (final c in _palette)
                _ColorSwatch(
                  color: c,
                  selected: current?.value == c.value,
                  onTap: () => Navigator.of(context).pop<Color?>(c),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _urlFieldController.dispose();
    _jsFieldController.dispose();
    _filePathController.dispose();
    _uaSuffixController.dispose();
    _userAgentController.dispose();
    _initialCssController.dispose();
    _rawJsController.dispose();
    _rawCssController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initialDataDemo = WebviewInitialData(
      '''
        <html>
          <body style="font-family: system-ui; padding: 20px;">
            <h2>Données Initiales (WebviewInitialData)</h2>
            <p>Chargées par défaut via les paramètres de création du widget.</p>
          </body>
        </html>
      ''',
      mimeType: 'text/html',
      encoding: 'utf8',
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Webview Plus — Démo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Précédent',
            onPressed: () => _controller?.goBack(),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward_rounded),
            tooltip: 'Suivant',
            onPressed: () => _controller?.goForward(),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Recharger',
            onPressed: () => _controller?.reload(),
          ),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (context, mode, _) => IconButton(
              tooltip: 'Basculer le thème',
              icon: Icon(
                mode == ThemeMode.dark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
              ),
              onPressed: () {
                themeModeNotifier.value =
                    mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
              },
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // -- Barre d'adresse + statut ---------------------------------
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlFieldController,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      hintText: 'https://exemple.com',
                      prefixIcon: const Icon(Icons.public_rounded),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    onSubmitted: (_) => _go(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _go,
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: const Text('Go'),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _StatusChip(isLoading: _isLoading, status: _status),
              ],
            ),
          ),
          const SizedBox(height: 6),

          if (_isLoading) const LinearProgressIndicator(minHeight: 2),

          // -- Webview ------------------------------------------------------
          Expanded(
            flex: 3,
            child: ClipRRect(
              child: WebviewWidget(
                key: ValueKey(_webviewGeneration),
                initialData: initialDataDemo,
                initialCss: _initialCssController.text,
                initialSettings: _currentSettings,
                contextMenuItems: _contextMenuItems,
                onWebViewCreated: (controller) {
                  _controller = controller;
                  _registerHandlers(controller);
                  setState(() => _status = 'Webview créée.');
                },
                onLoadStart: (controller, url) {
                  setState(() {
                    _isLoading = true;
                    _status = 'Chargement…';
                  });
                },
                onLoadStop: (controller, url) {
                  final time = DateTime.now().millisecondsSinceEpoch;
                  if (kDebugMode) {
                    debugPrint('WEBVIEW LOADING onLoadStop $time $url');
                  }
                  setState(() {
                    _isLoading = false;
                    _status = 'Chargé';
                    _urlFieldController.text = url.toString();
                  });
                },
                onDOMContentLoaded: (controller, url) {
                  final time = DateTime.now().millisecondsSinceEpoch;
                  if (kDebugMode) {
                    debugPrint('WEBVIEW LOADING onDOMContentLoaded $time $url');
                  }
                  setState(() => _status = 'DOM chargé');
                },
                onReceivedError: (controller, url, code, description) {
                  setState(() {
                    _isLoading = false;
                    _status = 'Erreur ($code)';
                  });
                  _pushLog('Erreur ($code) sur $url : $description');
                },
                onWindowFocus: (controller) => setState(() => _status = 'Focus'),
                onWindowBlur: (controller) => setState(() => _status = 'Perte de focus'),
                onNavigationRequest: (controller, url) async {
                  final bloque = url.toString().contains('bloque.com');
                  if (bloque) _pushLog('Navigation bloquée : $url');
                  return !bloque;
                },
                onMessageReceived: (controller, message) {
                  _pushLog('postMessage : $message');
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
                  );
                },
              ),
            ),
          ),

          const Divider(height: 1),

          // -- Panneau de test ---------------------------------------------
          Expanded(
            flex: 2,
            child: Column(
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: TabBar(
                    controller: _tabController,
                    tabs: const [
                      Tab(icon: Icon(Icons.bolt_rounded), text: 'Actions'),
                      Tab(icon: Icon(Icons.tune_rounded), text: 'Réglages'),
                      Tab(icon: Icon(Icons.cleaning_services_rounded), text: 'Cache & Debug'),
                      Tab(icon: Icon(Icons.article_rounded), text: 'Journal'),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildActionsTab(),
                      _buildSettingsTab(),
                      _buildCacheDebugTab(),
                      _buildLogTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // Onglet : Actions
  // ==========================================================================

  Widget _buildActionsTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _CardSection(
          icon: Icons.description_outlined,
          title: 'Chargement de contenu',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _actionButton(Icons.folder_open_rounded, 'Asset (index.html)', _loadHtmlFile),
                _actionButton(Icons.data_object_rounded, 'HTML brut (loadData)', _loadRawData),
                _actionButton(Icons.code_rounded, 'Voir le HTML (getHtml)', _getHtml),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _filePathController,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: 'Chemin absolu (loadFile)',
                      hintText: '/storage/emulated/0/Download/page.html',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(onPressed: _loadFile, child: const Text('Charger')),
              ],
            ),
          ],
        ),
        _CardSection(
          icon: Icons.terminal_rounded,
          title: 'Exécuter du JavaScript',
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _jsFieldController,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: 'Code JS (evaluateJavascript)',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _runJs, child: const Text('Exécuter')),
              ],
            ),
          ],
        ),
        _CardSection(
          icon: Icons.publish_rounded,
          title: 'Injection distante (fichier via URL)',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _actionButton(Icons.javascript_rounded, 'JS distant (jQuery)', _injectRemoteJs),
                _actionButton(Icons.style_rounded, 'CSS distant (inversion)', _injectRemoteCss),
              ],
            ),
          ],
        ),
        _CardSection(
          icon: Icons.flash_on_rounded,
          title: 'Injection brute (injectJsData / injectCssData)',
          subtitle: 'Exécutée immédiatement sur la page en cours, sur les 5 plateformes.',
          children: [
            TextField(
              controller: _rawJsController,
              maxLines: 2,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'JS brut (injectJsData)',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(onPressed: _injectRawJs, child: const Text('Injecter le JS')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _rawCssController,
              maxLines: 2,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'CSS brut (injectCssData)',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(onPressed: _injectRawCss, child: const Text('Injecter le CSS')),
            ),
          ],
        ),
        _CardSection(
          icon: Icons.style_outlined,
          title: 'CSS initial (WebviewWidget.initialCss)',
          subtitle: 'Réappliqué automatiquement à chaque chargement de page. Nécessite de recréer la Webview.',
          children: [
            TextField(
              controller: _initialCssController,
              maxLines: 3,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'CSS initial',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: _applySettingsAndRebuild,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Recréer la Webview'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================================================
  // Onglet : Réglages
  // ==========================================================================

  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, color: Theme.of(context).colorScheme.onPrimaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Ces réglages ne s\'appliquent qu\'à la création de la Webview : '
                    'cliquez sur "Appliquer" pour la recréer.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _applySettingsAndRebuild,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Appliquer'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        _SettingsGroup(
          icon: Icons.public_rounded,
          title: 'Général (toutes plateformes)',
          initiallyExpanded: true,
          children: [
            SwitchListTile(
              title: const Text('JavaScript activé'),
              value: _javaScriptEnabled,
              onChanged: (v) => setState(() => _javaScriptEnabled = v),
            ),
            SwitchListTile(
              title: const Text('Stockage DOM (localStorage / IndexedDB)'),
              value: _domStorageEnabled,
              onChanged: (v) => setState(() => _domStorageEnabled = v),
            ),
            SwitchListTile(
              title: const Text('Zoom (pincement) autorisé'),
              value: _supportZoom,
              onChanged: (v) => setState(() => _supportZoom = v),
            ),
            SwitchListTile(
              title: const Text('Lecture média nécessite un geste utilisateur'),
              value: _mediaPlaybackRequiresUserGesture,
              onChanged: (v) => setState(() => _mediaPlaybackRequiresUserGesture = v),
            ),
            SwitchListTile(
              title: const Text('Cache activé'),
              value: _cacheEnabled,
              onChanged: (v) => setState(() => _cacheEnabled = v),
            ),
            SwitchListTile(
              title: const Text('Navigation privée (incognito)'),
              value: _incognito,
              onChanged: (v) => setState(() => _incognito = v),
            ),
            SwitchListTile(
              title: const Text('window.open() autorisé sans geste utilisateur'),
              value: _javaScriptCanOpenWindowsAutomatically,
              onChanged: (v) => setState(() => _javaScriptCanOpenWindowsAutomatically = v),
            ),
            SwitchListTile(
              title: const Text('Masquer les barres de défilement natives'),
              value: _hideNativeScrollbars,
              onChanged: (v) => setState(() => _hideNativeScrollbars = v),
            ),
            SwitchListTile(
              title: const Text('Ne pas redimensionner au clavier (Android/iOS)'),
              value: _disableKeyboardResize,
              onChanged: (v) => setState(() => _disableKeyboardResize = v),
            ),
            SwitchListTile(
              title: const Text('Fond transparent'),
              value: _transparentBackground,
              onChanged: (v) => setState(() => _transparentBackground = v),
            ),
            SwitchListTile(
              title: const Text('Inspection à distance (isInspectable)'),
              subtitle: const Text('Par instance : voir aussi setWebContentsDebuggingEnabled (global)'),
              value: _isInspectable,
              onChanged: (v) => setState(() => _isInspectable = v),
            ),
            _colorTile(
              'Couleur d\'arrière-plan initiale',
              _initialBackgroundColor,
              nullable: true,
              onChanged: (c) => setState(() => _initialBackgroundColor = c),
            ),
            _textTile(
              'User-Agent complet (remplace celui par défaut)',
              _userAgentController,
              hint: 'Laisser vide pour garder le défaut système',
            ),
            _textTile(
              'Suffixe ajouté au User-Agent',
              _uaSuffixController,
            ),
          ],
        ),

        _SettingsGroup(
          icon: Icons.ads_click_rounded,
          title: 'Menu contextuel & sélection',
          children: [
            SwitchListTile(
              title: const Text('Désactiver le menu contextuel'),
              value: _disableContextMenu,
              onChanged: (v) => setState(() => _disableContextMenu = v),
            ),
            SwitchListTile(
              title: const Text('Désactiver le menu sur les liens (appui long)'),
              value: _disableLongPressLinks,
              onChanged: (v) => setState(() => _disableLongPressLinks = v),
            ),
            SwitchListTile(
              title: const Text('Masquer l\'URL survolée (desktop)'),
              value: _disableLinkHoverPreview,
              onChanged: (v) => setState(() => _disableLinkHoverPreview = v),
            ),
            SwitchListTile(
              title: const Text('Désactiver l\'impression (Ctrl/Cmd+P)'),
              value: _disablePrinting,
              onChanged: (v) => setState(() => _disablePrinting = v),
            ),
            _colorTile(
              'Couleur du texte sélectionné',
              _selectionTextColor,
              nullable: true,
              onChanged: (c) => setState(() => _selectionTextColor = c),
            ),
            _colorTile(
              'Couleur des poignées de sélection (Android)',
              _selectionHandleColor,
              nullable: true,
              onChanged: (c) => setState(() => _selectionHandleColor = c),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Éléments par défaut à désactiver (Android/iOS)'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: DefaultContextMenuItem.values.map((item) {
                  final selected = _disabledDefaultItems.contains(item);
                  return FilterChip(
                    label: Text(_defaultContextMenuItemLabel(item)),
                    selected: selected,
                    onSelected: (v) => setState(() {
                      if (v) {
                        _disabledDefaultItems.add(item);
                      } else {
                        _disabledDefaultItems.remove(item);
                      }
                    }),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),

        _SettingsGroup(
          icon: Icons.android_rounded,
          title: 'Android',
          children: [
            SwitchListTile(
              title: const Text('Accès aux fichiers (file://)'),
              value: _allowFileAccess,
              onChanged: (v) => setState(() => _allowFileAccess = v),
            ),
            SwitchListTile(
              title: const Text('Accès aux Content Providers (content://)'),
              value: _allowContentAccess,
              onChanged: (v) => setState(() => _allowContentAccess = v),
            ),
            SwitchListTile(
              title: const Text('Contrôles de zoom intégrés'),
              value: _builtInZoomControls,
              onChanged: (v) => setState(() => _builtInZoomControls = v),
            ),
            SwitchListTile(
              title: const Text('Afficher les boutons de zoom'),
              value: _displayZoomControls,
              onChanged: (v) => setState(() => _displayZoomControls = v),
            ),
            SwitchListTile(
              title: const Text('Géolocalisation matérielle'),
              value: _geolocationEnabled,
              onChanged: (v) => setState(() => _geolocationEnabled = v),
            ),
            SwitchListTile(
              title: const Text('Cookies tiers autorisés'),
              value: _thirdPartyCookiesEnabled,
              onChanged: (v) => setState(() => _thirdPartyCookiesEnabled = v),
            ),
            SwitchListTile(
              title: const Text('Forcer le mode sombre'),
              value: _forceDarkMode,
              onChanged: (v) => setState(() => _forceDarkMode = v),
            ),
            SwitchListTile(
              title: const Text('Google Safe Browsing'),
              value: _safeBrowsingEnabled,
              onChanged: (v) => setState(() => _safeBrowsingEnabled = v),
            ),
            SwitchListTile(
              title: const Text('Autoriser le contenu mixte (HTTP dans HTTPS)'),
              value: _allowMixedContent,
              onChanged: (v) => setState(() => _allowMixedContent = v),
            ),
            _sliderTile(
              'Zoom du texte',
              '$_textZoom %',
              value: _textZoom.toDouble(),
              min: 50,
              max: 200,
              divisions: 15,
              onChanged: (v) => setState(() => _textZoom = v.toInt()),
            ),
            _sliderTile(
              'Échelle initiale (0 = par défaut)',
              _initialScale == 0 ? 'Par défaut' : '$_initialScale %',
              value: _initialScale.toDouble(),
              min: 0,
              max: 200,
              divisions: 20,
              onChanged: (v) => setState(() => _initialScale = v.toInt()),
            ),
            _dropdownTile<OverScrollMode>(
              'Effet d\'overscroll',
              value: _overScrollMode,
              items: OverScrollMode.values,
              labelBuilder: (m) => m.name,
              onChanged: (v) => setState(() => _overScrollMode = v),
            ),
            _dropdownTile<AndroidPlatformViewType>(
              'Mode de rendu (PlatformView)',
              value: _androidPlatformViewType,
              items: AndroidPlatformViewType.values,
              labelBuilder: (m) => m.name,
              onChanged: (v) => setState(() => _androidPlatformViewType = v),
            ),
            _dropdownTile<WebviewContentMode>(
              'Mode de contenu (Desktop/Mobile)',
              value: _webviewContentMode,
              items: WebviewContentMode.values,
              labelBuilder: (m) => m.name,
              onChanged: (v) => setState(() => _webviewContentMode = v),
            ),
          ],
        ),

        _SettingsGroup(
          icon: Icons.phone_iphone_rounded,
          title: 'iOS & macOS',
          children: [
            SwitchListTile(
              title: const Text('Lecture média inline (sans plein écran auto.)'),
              value: _allowsInlineMediaPlayback,
              onChanged: (v) => setState(() => _allowsInlineMediaPlayback = v),
            ),
            SwitchListTile(
              title: const Text('Picture-in-Picture autorisé'),
              value: _allowsPictureInPicture,
              onChanged: (v) => setState(() => _allowsPictureInPicture = v),
            ),
            SwitchListTile(
              title: const Text('Rebond de défilement (bounces, iOS)'),
              value: _bounces,
              onChanged: (v) => setState(() => _bounces = v),
            ),
            SwitchListTile(
              title: const Text('Navigation par balayage (swipe, iOS)'),
              value: _allowsBackForwardNavigationGestures,
              onChanged: (v) => setState(() => _allowsBackForwardNavigationGestures = v),
            ),
            SwitchListTile(
              title: const Text('Aperçu de lien (Peek & Pop, iOS)'),
              value: _allowsLinkPreview,
              onChanged: (v) => setState(() => _allowsLinkPreview = v),
            ),
            SwitchListTile(
              title: const Text('Accès file:// → file:// (allowFileAccessFromFileURLs)'),
              subtitle: const Text('À activer si un fichier local ne charge pas ses ressources relatives'),
              value: _allowFileAccessFromFileURLs,
              onChanged: (v) => setState(() => _allowFileAccessFromFileURLs = v),
            ),
            SwitchListTile(
              title: const Text('Accès file:// → toute origine (allowUniversalAccessFromFileURLs)'),
              subtitle: const Text('Plus permissif : à réserver à du contenu local de confiance'),
              value: _allowUniversalAccessFromFileURLs,
              onChanged: (v) => setState(() => _allowUniversalAccessFromFileURLs = v),
            ),
            _sliderTile(
              'Taille minimale de police',
              '$_minimumFontSize px',
              value: _minimumFontSize.toDouble(),
              min: 1,
              max: 30,
              divisions: 29,
              onChanged: (v) => setState(() => _minimumFontSize = v.toInt()),
            ),
          ],
        ),

        _SettingsGroup(
          icon: Icons.view_column_rounded,
          title: 'Barres de défilement (Windows / macOS / Linux)',
          children: [
            _dropdownTile<DesktopScrollbarThemeMode>(
              'Mode',
              value: _scrollbarThemeMode,
              items: DesktopScrollbarThemeMode.values,
              labelBuilder: (m) => m.name,
              onChanged: (v) => setState(() => _scrollbarThemeMode = v),
            ),
            _colorTile(
              'Couleur du fond (track)',
              _scrollbarTrackColor,
              onChanged: (c) => setState(() => _scrollbarTrackColor = c ?? _scrollbarTrackColor),
            ),
            _colorTile(
              'Couleur de la poignée (thumb)',
              _scrollbarThumbColor,
              onChanged: (c) => setState(() => _scrollbarThumbColor = c ?? _scrollbarThumbColor),
            ),
            _sliderTile(
              'Largeur',
              '${_scrollbarWidth.toInt()} px',
              value: _scrollbarWidth,
              min: 4,
              max: 30,
              onChanged: (v) => setState(() => _scrollbarWidth = v),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  // ==========================================================================
  // Onglet : Cache & Debug
  // ==========================================================================

  Widget _buildCacheDebugTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _CardSection(
          icon: Icons.cleaning_services_rounded,
          title: 'WebviewCacheManager',
          subtitle: 'Agit sur toutes les Webviews de l\'app, indépendamment de celle affichée ci-dessus.',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _cacheActionInProgress
                      ? null
                      : () => _runCacheAction('clearCache', WebviewCacheManager.clearCache),
                  icon: const Icon(Icons.storage_rounded, size: 18),
                  label: const Text('Vider le cache HTTP'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _cacheActionInProgress
                      ? null
                      : () => _runCacheAction('clearCookies', WebviewCacheManager.clearCookies),
                  icon: const Icon(Icons.cookie_rounded, size: 18),
                  label: const Text('Vider les cookies'),
                ),
                FilledButton.icon(
                  onPressed: _cacheActionInProgress
                      ? null
                      : () => _runCacheAction('clearAllData', WebviewCacheManager.clearAllData),
                  icon: const Icon(Icons.delete_forever_rounded, size: 18),
                  label: const Text('Tout effacer'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.errorContainer,
                    foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
            if (_cacheActionInProgress) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(minHeight: 3),
            ],
          ],
        ),
        _CardSection(
          icon: Icons.bug_report_rounded,
          title: 'Inspection distante globale',
          subtitle: 'WebviewPlusController.setWebContentsDebuggingEnabled() — toutes les Webviews, existantes et futures.',
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('DevTools / Web Inspector activés'),
              value: _webContentsDebuggingEnabled,
              onChanged: _toggleWebContentsDebugging,
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================================================
  // Onglet : Journal
  // ==========================================================================

  Widget _buildLogTab() {
    if (_log.isEmpty) {
      return const Center(child: Text('Aucun événement pour le moment.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: _log.length,
      separatorBuilder: (_, __) => const Divider(height: 8),
      itemBuilder: (context, index) => Text(
        _log[index],
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }

  // ==========================================================================
  // Petits constructeurs de widgets réutilisés
  // ==========================================================================

  Widget _actionButton(IconData icon, String label, VoidCallback onPressed) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }

  Widget _colorTile(String title, Color? color, {bool nullable = false, required ValueChanged<Color?> onChanged}) {
    return ListTile(
      title: Text(title),
      trailing: GestureDetector(
        onTap: () async {
          final chosen = await _pickColor(title, color, nullable: nullable);
          if (chosen != color) onChanged(chosen);
        },
        child: color == null
            ? const CircleAvatar(child: Icon(Icons.block_rounded, size: 16))
            : CircleAvatar(backgroundColor: color),
      ),
    );
  }

  Widget _textTile(String label, TextEditingController controller, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          labelText: label,
          hintText: hint,
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _sliderTile(
    String title,
    String valueLabel, {
    required double value,
    required double min,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
  }) {
    return ListTile(
      title: Text(title),
      subtitle: Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: valueLabel,
        onChanged: onChanged,
      ),
      trailing: SizedBox(width: 56, child: Text(valueLabel, textAlign: TextAlign.right)),
    );
  }

  Widget _dropdownTile<T>(
    String title, {
    required T value,
    required List<T> items,
    required String Function(T) labelBuilder,
    required ValueChanged<T> onChanged,
  }) {
    return ListTile(
      title: Text(title),
      trailing: DropdownButton<T>(
        value: value,
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
        items: items
            .map((item) => DropdownMenuItem<T>(value: item, child: Text(labelBuilder(item))))
            .toList(),
      ),
    );
  }

  String _defaultContextMenuItemLabel(DefaultContextMenuItem item) {
    switch (item) {
      case DefaultContextMenuItem.copy:
        return 'Copier';
      case DefaultContextMenuItem.cut:
        return 'Couper';
      case DefaultContextMenuItem.paste:
        return 'Coller';
      case DefaultContextMenuItem.selectAll:
        return 'Tout sélectionner';
    }
  }
}

// ============================================================================
// Widgets utilitaires
// ============================================================================

/// Puce arrondie affichant le statut courant, avec un petit spinner pendant
/// le chargement.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.isLoading, required this.status});

  final bool isLoading;
  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isLoading)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onSecondaryContainer),
            )
          else
            Icon(Icons.check_circle_rounded, size: 14, color: scheme.onSecondaryContainer),
          const SizedBox(width: 6),
          Text(
            status,
            style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
          ),
        ],
      ),
    );
  }
}

/// Carte avec icône + titre (+ sous-titre optionnel) utilisée dans l'onglet
/// "Actions" et "Cache & Debug".
class _CardSection extends StatelessWidget {
  const _CardSection({
    required this.icon,
    required this.title,
    required this.children,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title, style: Theme.of(context).textTheme.titleSmall),
                ),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Groupe de réglages repliable utilisé dans l'onglet "Réglages", pour éviter
/// un mur de switches et laisser l'utilisateur se concentrer sur une
/// catégorie/plateforme à la fois.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({
    required this.icon,
    required this.title,
    required this.children,
    this.initiallyExpanded = false,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: children,
        ),
      ),
    );
  }
}

/// Pastille de couleur cliquable utilisée dans le sélecteur [_pickColor].
class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.color, required this.selected, required this.onTap});

  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color ?? Colors.transparent,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Theme.of(context).colorScheme.primary : Colors.black26,
            width: selected ? 3 : 1,
          ),
        ),
        child: color == null
            ? const Icon(Icons.block_rounded, size: 18)
            : (selected ? const Icon(Icons.check_rounded, color: Colors.white, size: 18) : null),
      ),
    );
  }
}