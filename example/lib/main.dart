import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_plus/webview_plus.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Démo of webview_plus',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6750A4),
        useMaterial3: true,
      ),
      debugShowCheckedModeBanner: false,
      home: const WebviewDemoPage(),
    );
  }
}

class WebviewDemoPage extends StatefulWidget {
  const WebviewDemoPage({super.key});

  @override
  State<WebviewDemoPage> createState() => _WebviewDemoPageState();
}

class _WebviewDemoPageState extends State<WebviewDemoPage> {
  WebviewPlusController? _controller;

  // -- Barre d'adresse -----------------------------------------------------
  final TextEditingController _urlFieldController =
      TextEditingController(text: 'https://flutter.dev');
  final TextEditingController _jsFieldController =
      TextEditingController(text: "document.body.style.backgroundColor = 'red'");
  final TextEditingController _filePathController = TextEditingController();

  // -- État / logs affichés en bas d'écran ---------------------------------
  String _status = 'Inactif';
  bool _isLoading = false;
  final List<String> _log = <String>[];

  // -- Réglages (recréent la Webview quand ils changent, car appliqués
  //    uniquement à la création native) -----------------------------------
  bool _disableContextMenu = false;
  bool _disableLongPressLinks = false;
  bool _isInspectable = true;
  bool _transparentBackground = false;
  Color _initialBackgroundColor = Colors.cyan;
  Color _selectionTextColor = Colors.pink;
  Color _selectionHandleColor = Colors.orange;
  Set<DefaultContextMenuItem> _disabledDefaultItems = <DefaultContextMenuItem>{};
  bool _disableLinkHoverPreview = true;
  bool _disablePrinting = false;
  int _webviewGeneration = 0;

  void _pushLog(String line) {
    setState(() {
      _log.insert(0, line);
      if (_log.length > 30) _log.removeLast();
    });
  }

  WebviewSettings get _currentSettings => WebviewSettings(
        disableContextMenu: _disableContextMenu,
        disableLongPressContextMenuOnLinks: _disableLongPressLinks,
        isInspectable: _isInspectable,
        transparentBackground: _transparentBackground,
        initialBackgroundColor: _initialBackgroundColor,
        selectionTextColor: _selectionTextColor,
        selectionHandleColor: _selectionHandleColor,
        disabledDefaultContextMenuItems: _disabledDefaultItems,
        disableLinkHoverPreview: _disableLinkHoverPreview,
        disablePrinting: _disablePrinting,
      );

  // Entrées personnalisées ajoutées au menu contextuel natif (sélection de
  // texte / appui long / clic droit selon la plateforme). Le texte
  // actuellement sélectionné est transmis à l'action.
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
    // Handler appelable depuis le JS de la page via :
    //   window.webview_plus.callHandler('fromJs', 'salut', 42)
    controller.addJavaScriptHandler(
      handlerName: 'fromJs',
      callback: (args) async {
        _pushLog('JS -> Dart [fromJs] args=$args');
        return <String, dynamic>{
          'ok': true,
          'reçu': args,
          'horodatage': DateTime.now().toIso8601String(),
          'message': 'Bonjour depuis le Dart !',
        };
      },
    );
  }

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
    _pushLog('evaluateJavascript("$code") -> $result');
  }

  Future<void> _getHtml() async {
    final html = await _controller?.getHtml();
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('HTML de la page'),
        content: SizedBox(
          width: 400,
          height: 300,
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
    await _controller?.loadFlutterAsset(
      'assets/index.html',
    );
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

  Future<void> _injectDemoJs() async {
    // Injecte un script distant (jQuery, à titre d'exemple) puis vérifie
    // sa présence.
    await _controller?.injectJavascriptFileFromUrl(
      'https://code.jquery.com/jquery-3.7.1.min.js',
    );
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final result =
        await _controller?.evaluateJavascript("typeof window.jQuery");
    _pushLog('Injection JS distante -> typeof jQuery = $result');
  }

  Future<void> _injectDemoCss() async {
    await _controller?.injectCSSFileFromUrl(
      'data:text/css;base64,Ym9keSB7IGZpbHRlcjogaW52ZXJ0KDEpOyB9', // body { filter: invert(1); }
    );
    _pushLog('CSS injecté (inversion des couleurs de la page).');
  }

  void _applySettingsAndRebuild() {
    setState(() {
      _webviewGeneration++; // force la recréation de la Webview native
      _status = 'Réglages appliqués, Webview recréée.';
    });
  }

  Future<Color?> _pickSelectionColor() async {
    const colors = [
      Colors.orange,
      Colors.pink,
      Colors.teal,
      Colors.blue,
      Colors.red,
    ];
    return await showDialog<Color>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Couleur de sélection'),
        children: colors
            .map(
              (c) => SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(c),
                child: Row(
                  children: [
                    Container(width: 20, height: 20, color: c),
                    const SizedBox(width: 12),
                    Text('#${c.value.toRadixString(16)}'),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  @override
  void dispose() {
    _urlFieldController.dispose();
    _jsFieldController.dispose();
    _filePathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Webview Plus — Démo Complète'),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Précédent',
            onPressed: () => _controller?.goBack(),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward),
            tooltip: 'Suivant',
            onPressed: () => _controller?.goForward(),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Recharger',
            onPressed: () => _controller?.reload(),
          ),
        ],
      ),
      body: Column(
        children: [
          // -- Barre d'adresse -----------------------------------------
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlFieldController,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: 'https://exemple.com',
                      prefixIcon: Icon(Icons.public),
                    ),
                    onSubmitted: (_) => _go(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _go,
                  child: const Text('Aller'),
                ),
              ],
            ),
          ),

          if (_isLoading) const LinearProgressIndicator(minHeight: 2),

          // -- Webview ----------------------------------------------------
          Expanded(
            flex: 3,
            child: WebviewWidget(
              key: ValueKey(_webviewGeneration),
              initialUrl: _urlFieldController.text,
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
                  _status = 'Chargement : $url';
                });
              },
              onLoadStop: (controller, url) {
                final time = DateTime.now().millisecondsSinceEpoch;
                if (kDebugMode) {
                  print('WEBVIEW LOADING onLoadStop $time $url');
                }
                setState(() {
                  _isLoading = false;
                  _status = 'Chargé : $url';
                  _urlFieldController.text = url.toString();
                });
              },
              onDOMContentLoaded: (controller, url) {
                final time = DateTime.now().millisecondsSinceEpoch;
                if (kDebugMode) {
                  print('WEBVIEW LOADING onDOMContentLoaded $time $url');
                }
                setState(() {
                  _status = 'DOM Content Loaded : $url';
                });
              },
              onReceivedError: (controller, url, code, description) {
                setState(() {
                  _isLoading = false;
                  _status = 'Erreur ($code) sur $url : $description';
                });
              },
              onWindowFocus: (controller) {
                setState(() {
                  _status = 'Window Focus';
                });
              },
              onWindowBlur: (controller) {
                setState(() {
                  _status = 'Window Blur';
                });
              },
              onNavigationRequest: (controller, url) async {
                final bool bloque = url.toString().contains('bloque.com');
                if (bloque) {
                  _pushLog('Navigation bloquée : $url');
                }
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

          const Divider(height: 1),

          // -- Panneau de test ---------------------------------------------
          Expanded(
            flex: 2,
            child: DefaultTabController(
              length: 3,
              child: Column(
                children: [
                  const TabBar(
                    tabs: [
                      Tab(text: 'Actions'),
                      Tab(text: 'Réglages'),
                      Tab(text: 'Journal'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildActionsTab(),
                        _buildSettingsTab(),
                        _buildLogTab(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          Text(_status, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(width: double.infinity, height: 0),
          _actionButton('Charger fichier assets (index.html)', _loadHtmlFile),
          _actionButton('Charger data brute (loadData)', _loadRawData),
          _actionButton('Récupérer le HTML (getHtml)', _getHtml),
          _actionButton('Injecter JS distant', _injectDemoJs),
          _actionButton('Injecter CSS distant', _injectDemoCss),
          SizedBox(
            width: double.infinity,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _jsFieldController,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: 'Code JS à exécuter',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _runJs,
                  child: const Text('Exécuter'),
                ),
              ],
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: Row(
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
                ElevatedButton(
                  onPressed: _loadFile,
                  child: const Text('Charger fichier'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ces réglages ne s\'appliquent qu\'à la création de la '
            'Webview : cliquez sur "Appliquer" pour la recréer.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          SwitchListTile(
            title: const Text('Désactiver le menu contextuel'),
            value: _disableContextMenu,
            onChanged: (v) => setState(() => _disableContextMenu = v),
          ),
          SwitchListTile(
            title: const Text('Désactiver le menu contextuel sur les liens'),
            value: _disableLongPressLinks,
            onChanged: (v) => setState(() => _disableLongPressLinks = v),
          ),
          SwitchListTile(
            title: const Text('Inspection à distance (isInspectable)'),
            value: _isInspectable,
            onChanged: (v) => setState(() => _isInspectable = v),
          ),
          SwitchListTile(
            title: const Text('Fond transparent'),
            value: _transparentBackground,
            onChanged: (v) => setState(() => _transparentBackground = v),
          ),
          ListTile(
            title: const Text('Couleur d\'arrière-plan par défaut'),
            trailing: CircleAvatar(backgroundColor: _initialBackgroundColor),
            onTap: () async {
              final chosen = await _pickSelectionColor();
              if (chosen != null) {
                setState(() => _initialBackgroundColor = chosen);
              }
            },
          ),
          ListTile(
            title: const Text('Couleur des textes de selection'),
            trailing: CircleAvatar(backgroundColor: _selectionTextColor),
            onTap: () async {
              final chosen = await _pickSelectionColor();
              if (chosen != null) {
                setState(() => _selectionTextColor = chosen);
              }
            },
          ),
          ListTile(
            title: const Text('Couleur des handle de selection'),
            trailing: CircleAvatar(backgroundColor: _selectionHandleColor),
            onTap: () async {
              final chosen = await _pickSelectionColor();
              if (chosen != null) {
                setState(() => _selectionHandleColor = chosen);
              }
            },
          ),
          const Divider(),
          Text(
            'Éléments par défaut du menu contextuel à désactiver '
            '(Android/iOS uniquement)',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Wrap(
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
          const SizedBox(height: 8),
          Text(
            'Le menu contextuel inclut aussi 2 entrées personnalisées de '
            'démo ("Rechercher" / "Traduire", Android/iOS uniquement), '
            'visibles dans l\'onglet Journal une fois sélectionnées.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('Masquer l\'URL survolée (Windows)'),
            subtitle: const Text('Barre de statut en bas de la fenêtre'),
            value: _disableLinkHoverPreview,
            onChanged: (v) => setState(() => _disableLinkHoverPreview = v),
          ),
          SwitchListTile(
            title: const Text('Désactiver l\'impression (Ctrl+P)'),
            value: _disablePrinting,
            onChanged: (v) => setState(() => _disablePrinting = v),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _applySettingsAndRebuild,
            icon: const Icon(Icons.refresh),
            label: const Text('Appliquer (recrée la Webview)'),
          ),
        ],
      ),
    );
  }

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

  Widget _actionButton(String label, VoidCallback onPressed) {
    return ElevatedButton(onPressed: onPressed, child: Text(label));
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