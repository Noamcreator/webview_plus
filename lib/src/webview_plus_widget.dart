import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:webview_plus/src/webview_plus_environment.dart';
import 'package:webview_plus/src/webview_plus_desktop_scrollbar_theme.dart';
import 'webview_plus_context_menu.dart';
import 'webview_plus_controller.dart';
import 'webview_plus_initial_data.dart';
import 'webview_plus_settings.dart';
import 'webview_plus_web.dart' if (dart.library.io) 'webview_plus_web_stub.dart' as web_impl;

const String _kViewType = 'plugins.noam.me/webview_plus';

const int _kPrimaryMouseButton = 1;
const int _kSecondaryMouseButton = 2;
const int _kTertiaryMouseButton = 4;

/// Widget affichant une Webview 100% native dans l'arbre Flutter.
class WebviewWidget extends StatefulWidget {
  const WebviewWidget({
    super.key,
    this.gestureRecognizers,
    this.layoutDirection,
    this.webViewEnvironment,
    this.initialUrl,
    this.initialAsset,
    this.initialFile,
    this.initialData,
    this.initialCss,
    this.initialSettings = const WebviewSettings(),
    this.onWebViewCreated,
    this.onNavigationRequest,
    this.onMessageReceived,
    this.onLoadStart,
    this.onLoadStop,
    this.onDOMContentLoaded,
    this.onReceivedError,
    this.onWindowFocus,
    this.onWindowBlur,
    this.onFontsIsLoaded,
    this.onLoadResource,
    this.filterQuality = FilterQuality.none,
    this.contextMenuItems = const <ContextMenuItem>[],
  }) : assert(
          (initialUrl != null ? 1 : 0) +
                  (initialAsset != null ? 1 : 0) +
                  (initialFile != null ? 1 : 0) +
                  (initialData != null ? 1 : 0) <=
              1,
          'Un seul type de source initiale peut être fourni parmi '
          'initialUrl, initialAsset, initialFile et initialData.',
        );

  final Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers;
  final TextDirection? layoutDirection;
  final WebViewEnvironment? webViewEnvironment;
  final String? initialUrl;
  final String? initialAsset;
  final String? initialFile;

  /// Contenu initial (HTML/données) chargé directement à la création de la
  /// Webview, sans passer par une URL/un asset/un fichier. Voir
  /// [WebviewInitialData]. Mutuellement exclusif avec [initialUrl],
  /// [initialAsset] et [initialFile].
  final WebviewInitialData? initialData;

  /// CSS brut injecté à chaque chargement de page (initial ou suite à une
  /// navigation), sur les 5 plateformes (Android, iOS, macOS, Windows,
  /// Linux). Pour une injection ponctuelle après coup, voir plutôt
  /// `WebviewPlusController.injectCssData`.
  final String? initialCss;
  final WebviewSettings initialSettings;
  final WebviewCreatedCallback? onWebViewCreated;
  final NavigationRequestCallback? onNavigationRequest;
  final WebviewMessageCallback? onMessageReceived;
  final WebviewLoadCallback? onLoadStart;
  final WebviewLoadCallback? onLoadStop;
  final WebviewLoadCallback? onDOMContentLoaded;
  final WebviewErrorCallback? onReceivedError;
  final WebviewLoadResourceCallback? onLoadResource;

  final WebviewControllerCallback? onWindowFocus;
  final WebviewControllerCallback? onWindowBlur;

  /// Appelé lorsque `document.fonts.ready` se résout pour la page chargée
  /// (voir [WebviewFontsLoadedCallback]).
  final WebviewFontsLoadedCallback? onFontsIsLoaded;

  /// Qualité de filtrage appliquée à la texture Windows (composition Webview2).
  final FilterQuality filterQuality;

  /// Éléments personnalisés ajoutés au menu contextuel natif (voir
  /// [ContextMenuItem]). Peut être mis à jour après création via
  /// `controller.setContextMenuItems(...)`.
  ///
  /// **Android et iOS uniquement.** Sur desktop (Windows/macOS/Linux), il
  /// n'existe pas de barre de sélection de texte tactile équivalente : le
  /// clic droit y ouvre le menu contextuel classique du navigateur, sans
  /// point d'extension adapté à ce type d'entrée. Ce champ est donc
  /// silencieusement ignoré sur ces plateformes.
  final List<ContextMenuItem> contextMenuItems;

  @override
  State<WebviewWidget> createState() => _WebviewWidgetState();
}

class _WebviewWidgetState extends State<WebviewWidget> with WidgetsBindingObserver {
  static const MethodChannel _globalWindowsChannel = MethodChannel('plugins.noam.me/webview_plus_windows');
  static const MethodChannel _globalLinuxChannel = MethodChannel('plugins.noam.me/webview_plus_linux');

  // -- Détection du SDK Android (pour choisir le mode de composition) ----
  //
  // `PlatformViewsService.initSurfaceAndroidView` (Texture Layer Hybrid
  // Composition) offre un scroll natif fluide dans la Webview *et* des
  // transitions/animations Flutter fluides autour, contrairement à
  // `initExpensiveAndroidView` (Hybrid Composition classique, jank pendant
  // les animations) et à `AndroidView` seul (Virtual Display, scroll qui
  // rame). Il nécessite cependant l'API 23+. Le résultat est mis en cache
  // au niveau du process : un seul appel de canal pour toute l'app, quel
  // que soit le nombre d'instances de WebviewWidget créées.
  static const MethodChannel _globalInfoChannel = MethodChannel('plugins.noam.me/webview_plus_info');
  static int? _cachedAndroidSdkInt;

  static Future<int> _getAndroidSdkInt() async {
    final cached = _cachedAndroidSdkInt;
    if (cached != null) return cached;
    int sdk;
    try {
      sdk = await _globalInfoChannel.invokeMethod<int>('getSdkInt') ?? 23;
    } catch (_) {
      // En cas d'échec (ancienne version du plugin natif, etc.), on reste
      // conservateur et on suppose un appareil récent : c'est le cas de
      // >99% du parc Android actif.
      sdk = 23;
    }
    _cachedAndroidSdkInt = sdk;
    return sdk;
  }

  // `null` tant que non résolu : on part de l'hypothèse optimiste (SDK
  // 23+) pour ne pas retarder l'affichage de la Webview le temps du
  // premier aller-retour de canal ; si l'appareil s'avère plus ancien, on
  // bascule vers le mode adapté dès que `setState` déclenche un rebuild.
  int? _androidSdkInt = _cachedAndroidSdkInt;

  int? _windowsViewId;
  int? _windowsTextureId;
  bool _windowsReady = false;
  MouseCursor _windowsCursor = SystemMouseCursors.basic;

  int? _linuxViewId;
  bool _linuxInitScheduled = false;
  bool _linuxCreated = false;
  Rect _linuxLastRect = Rect.zero;
  bool _linuxLastVisible = false;

  final GlobalKey _windowsWidgetKey = GlobalKey();
  final Map<int, int> _downButtons = <int, int>{};

  // `true` dès que la création Windows a été lancée une première fois (voir
  // `didChangeDependencies`, qui a besoin du `Theme` ambiant pour résoudre
  // les couleurs de scrollbar en mode `auto` et ne peut donc pas se faire 
  // dans `initState`, où `context` n'a pas encore ses dépendances).
  bool _windowsInitScheduled = false;

  // Cache de la vue Web (HtmlElementView + iframe), construite une seule
  // fois par instance de State. Indispensable : `build()` peut être
  // ré-exécuté à tout moment par Flutter (rebuild du parent, setState,
  // hot reload...), or `web_impl.buildWebview` enregistre un NOUVEAU
  // `viewType` et une NOUVELLE iframe à chaque appel. Sans ce cache,
  // chaque rebuild recrée une vue plateforme, ce qui recrée le
  // contrôleur, redéclenche `onWebViewCreated`, et peut ainsi provoquer
  // une recréation en boucle infinie si l'appelant réagit à ce callback
  // par un `setState`.
  Widget? _webViewWidget;

  @override
  void initState() {
    super.initState();
    assert(() {
      return true;
    }());
    WidgetsBinding.instance.addObserver(this);
    // Important : on ne lance PAS _initLinuxWebview() ici. Comme pour
    // Windows, cette méthode appelle _resolveWindowsScrollbarTheme(), qui
    // peut faire Theme.of(context) en mode `auto`. Tant que initState() n'a
    // pas terminé, l'élément n'a pas encore ses InheritedWidget dépendances
    // enregistrées, ce qui plante avec
    // "dependOnInheritedWidgetOfExactType<_InheritedTheme>() ... called
    // before initState() completed". On délègue donc entièrement le
    // déclenchement à didChangeDependencies(), qui s'exécute après.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _loadAndroidSdkInt();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (kIsWeb) return;

    if (defaultTargetPlatform == TargetPlatform.windows) {
      if (!_windowsInitScheduled) {
        _windowsInitScheduled = true;
        _initWindowsWebview();
      } else if (_windowsReady) {
        _pushWindowsScrollbarTheme();
      }
    } 
    else if (defaultTargetPlatform == TargetPlatform.linux) {
      if (!_linuxInitScheduled) {
        _linuxInitScheduled = true;
        _initLinuxWebview();
      }
    }
  }

  /// Calcule la configuration de thème des barres de défilement à envoyer
  /// au plugin natif Windows, à partir de [WebviewSettings.windowsScrollbarThemeMode].
  /// En mode `auto`, dérive les couleurs du `Theme` Flutter ambiant.
  Map<String, dynamic>? _resolveDesktopScrollbarTheme() {
    final settings = widget.initialSettings;
    final scrollbarTheme = settings.windowsScrollbarTheme; // Utilisation de l'objet encapsulé

    if (settings.hideNativeScrollbars) {
      return const <String, dynamic>{'mode': 'hidden'};
    }

    switch (scrollbarTheme.themeMode) {
      case DesktopScrollbarThemeMode.hidden:
        return const <String, dynamic>{'mode': 'hidden'};

      case DesktopScrollbarThemeMode.custom:
        return <String, dynamic>{
          'mode': 'custom',
          'trackColor': scrollbarTheme.trackColor?.toARGB32(),
          'thumbColor': scrollbarTheme.thumbColor?.toARGB32(),
          'thumbHoverColor': scrollbarTheme.thumbHoverColor?.toARGB32(),
          'width': scrollbarTheme.width,
        };

      case DesktopScrollbarThemeMode.light:
        return _desktopScrollbarColorsFor(Brightness.light, scrollbarTheme);

      case DesktopScrollbarThemeMode.dark:
        return _desktopScrollbarColorsFor(Brightness.dark, scrollbarTheme);

      case DesktopScrollbarThemeMode.auto:
        final theme = Theme.of(context);
        return _desktopScrollbarColorsFor(
          theme.brightness,
          scrollbarTheme,
          colorScheme: theme.colorScheme,
        );
    }
  }

  /// Dérive une palette de scrollbar pour une [brightness] donnée, en
  /// s'appuyant sur le [colorScheme] Flutter fourni (mode `auto`) ou sur des
  /// couleurs par défaut sobres (modes `light`/`dark` fixes).
  Map<String, dynamic> _desktopScrollbarColorsFor(
    Brightness brightness,
    DesktopScrollbarTheme scrollbarTheme, {
    ColorScheme? colorScheme,
  }) {
    final bool isDark = brightness == Brightness.dark;
    
    final Color track = colorScheme?.surface ??
        (isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF0F0F0));
        
    final Color thumb = colorScheme != null
        ? colorScheme.onSurface.withValues(alpha: 0.4)
        : (isDark ? const Color(0x66FFFFFF) : const Color(0x66000000));
        
    final Color thumbHover = colorScheme?.primary ??
        (isDark ? const Color(0xFF9E9E9E) : const Color(0xFF757575));
        
    return <String, dynamic>{
      'mode': isDark ? 'dark' : 'light',
      'trackColor': track.toARGB32(),
      'thumbColor': thumb.toARGB32(),
      'thumbHoverColor': thumbHover.toARGB32(),
      'width': scrollbarTheme.width, // Récupéré depuis le nouveau thème
    };
  }

  /// Republie la configuration courante des barres de défilement au plugin
  /// natif Windows (mise à jour à chaud, ex. changement de thème). No-op
  /// tant que la vue Windows n'a pas encore été créée.
  void _pushWindowsScrollbarTheme() {
    final id = _windowsViewId;
    if (id == null) return;
    _globalWindowsChannel.invokeMethod('setScrollbarTheme', {
      'viewId': id,
      'scrollbarTheme': _resolveDesktopScrollbarTheme(),
    });
  }

  @override
  void didUpdateWidget(covariant WebviewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows &&
        oldWidget.initialSettings != widget.initialSettings) {
      _pushWindowsScrollbarTheme();
    }
  }

  Future<void> _loadAndroidSdkInt() async {
    if (_cachedAndroidSdkInt != null) {
      if (_androidSdkInt != _cachedAndroidSdkInt) {
        setState(() {
          _androidSdkInt = _cachedAndroidSdkInt;
        });
      }
      return;
    }

    final sdk = await _getAndroidSdkInt();
    if (!mounted) return;

    _cachedAndroidSdkInt = sdk;

    final bool oldCanUseSurface = (_androidSdkInt ?? 23) >= 23;
    final bool newCanUseSurface = sdk >= 23;

    if (oldCanUseSurface != newCanUseSurface) {
      setState(() {
        _androidSdkInt = sdk;
      });
    } else {
      _androidSdkInt = sdk;
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Filet de sécurité pour Linux : un changement de métriques sans
    // relayout (ex. changement de résolution/échelle) ne déclenche pas
    // forcément un nouveau `paint()` du sous-arbre ; on republie donc le
    // dernier rectangle connu par précaution (no-op si rien n'a changé côté
    // natif).
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      _pushLinuxFrame(_linuxLastRect, visible: _linuxLastVisible);
    }
  }

  Future<void> _initWindowsWebview() async {
    final id = DateTime.now().microsecondsSinceEpoch;
    setState(() {
      _windowsViewId = id;
      _windowsReady = false;
      _windowsTextureId = null;
    });

    try {
      final dynamic result = await _globalWindowsChannel.invokeMethod('create', {
        'viewId': id,
        'initialUrl': widget.initialUrl,
        'initialAsset': widget.initialAsset,
        'initialFile': widget.initialFile,
        'initialData': widget.initialData?.toMap(),
        'initialCss': widget.initialCss,
        'initialSettings': widget.initialSettings.toMap(),
        'userDataFolder': widget.webViewEnvironment?.settings?.userDataFolder,
        'scrollbarTheme': _resolveDesktopScrollbarTheme(),
      });

      final Map<dynamic, dynamic> response =
          Map<dynamic, dynamic>.from(result as Map);
      final textureId = response['textureId'] as int?;

      final controller = WebviewBaseController.init(
        id,
        onNavigationRequest: widget.onNavigationRequest,
        onMessageReceived: widget.onMessageReceived,
        onLoadStart: widget.onLoadStart,
        onLoadStop: widget.onLoadStop,
        onDOMContentLoaded: widget.onDOMContentLoaded,
        onReceivedError: widget.onReceivedError,
        onWindowFocus: widget.onWindowFocus,
        onWindowBlur: widget.onWindowBlur,
        onFontsIsLoaded: widget.onFontsIsLoaded,
        onLoadResource: widget.onLoadResource,
        onCursorChanged: (_, cursorKind) {
          if (!mounted) return;
          setState(() => _windowsCursor = _cursorFromKind(cursorKind));
        },
      );

      if (!mounted) return;
      setState(() {
        _windowsTextureId = textureId;
        _windowsReady = textureId != null;
      });
      _handleControllerCreated(controller);
    } catch (e) {
      debugPrint('Erreur lors de la création de la Webview Windows: $e');
    }
  }

  /// Contrairement à Android/iOS (Flutter `PlatformView`) et à Windows
  /// (texture Webview2), Linux ne dispose d'aucune primitive Flutter de
  /// "vue de plateforme" : le plugin natif (voir `linux/webview/*.cc`)
  /// positionne directement un `GtkWidget` WebKitGTK au-dessus de la
  /// fenêtre Flutter, à la position et taille communiquées via `setFrame`
  /// sur le canal global `plugins.noam.me/webview_plus_linux` — d'où le
  /// widget géométrique dédié `_LinuxGeometryObserver` plus bas, qui
  /// recalcule ce rectangle à chaque `paint`.
  Future<void> _initLinuxWebview() async {
    final id = DateTime.now().microsecondsSinceEpoch;
    _linuxViewId = id;
    _linuxCreated = false;
    _linuxLastRect = Rect.zero;
    _linuxLastVisible = false;

    try {
      await _globalLinuxChannel.invokeMethod('create', {
        'viewId': id,
        'initialUrl': widget.initialUrl,
        'initialAsset': widget.initialAsset,
        'initialFile': widget.initialFile,
        'initialData': widget.initialData?.toMap(),
        'initialCss': widget.initialCss,
        'initialSettings': widget.initialSettings.toMap(),
        // WebKitGTK respecte les mêmes pseudo-éléments `::-webkit-scrollbar*`
        // que Windows/macOS : on réutilise donc la même résolution de thème.
        'scrollbarTheme': _resolveDesktopScrollbarTheme(),
      });

      if (!mounted) return;

      final controller = WebviewBaseController.init(
        id,
        onNavigationRequest: widget.onNavigationRequest,
        onMessageReceived: widget.onMessageReceived,
        onLoadStart: widget.onLoadStart,
        onLoadStop: widget.onLoadStop,
        onDOMContentLoaded: widget.onDOMContentLoaded,
        onReceivedError: widget.onReceivedError,
        onFontsIsLoaded: widget.onFontsIsLoaded,
        onLoadResource: widget.onLoadResource
      );

      setState(() => _linuxCreated = true);
      _handleControllerCreated(controller);
      // Le widget peut déjà avoir été peint (et donc avoir une géométrie
      // connue) avant que la création native ne se termine.
      _pushLinuxFrame(_linuxLastRect, visible: _linuxLastVisible);
    } catch (e) {
      debugPrint('Erreur lors de la création de la Webview Linux: $e');
    }
  }

  void _pushLinuxFrame(Rect rect, {required bool visible}) {
    _linuxLastRect = rect;
    _linuxLastVisible = visible;
    final id = _linuxViewId;
    if (id == null || !_linuxCreated) return;
    _globalLinuxChannel.invokeMethod('setFrame', {
      'viewId': id,
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
      'visible': visible,
    });
  }

  void _handleLinuxGeometryChanged(Rect rect) {
    final bool visible = rect.left.isFinite &&
        rect.top.isFinite &&
        rect.width.isFinite &&
        rect.height.isFinite &&
        rect.width > 0 &&
        rect.height > 0;
    if (_linuxLastVisible != visible || rect != _linuxLastRect) {
      _pushLinuxFrame(visible ? rect : Rect.zero, visible: visible);
    }
  }

  /// Traduit l'identifiant générique reçu du plugin natif Windows (voir
  /// `CursorKindFromHandle` côté C++) en `SystemMouseCursor` Flutter. En
  /// mode composition, WebView2 n'a pas de HWND visible sur lequel poser
  /// lui-même le curseur système : c'est donc la fenêtre Flutter (via ce
  /// `MouseRegion`) qui doit le faire.
  MouseCursor _cursorFromKind(String kind) {
    switch (kind) {
      case 'click':
        return SystemMouseCursors.click;
      case 'text':
        return SystemMouseCursors.text;
      case 'wait':
        return SystemMouseCursors.wait;
      case 'precise':
        return SystemMouseCursors.precise;
      
      // Redimensionnement Horizontal (Bords Gauche et Droit sous Windows)
      case 'resizeLeftRight':
      case 'resizeLeft':
      case 'resizeRight':
        return SystemMouseCursors.resizeLeftRight;

      // Redimensionnement Vertical (Bords Haut et Bas sous Windows)
      case 'resizeUpDown':
      case 'resizeUp':
      case 'resizeDown':
        return SystemMouseCursors.resizeUpDown;

      // Redimensionnements Diagonaux (Coins de fenêtres)
      case 'resizeUpLeftDownRight':
        return SystemMouseCursors.resizeUpLeftDownRight;
      case 'resizeUpRightDownLeft':
        return SystemMouseCursors.resizeUpRightDownLeft;

      case 'allScroll':
        return SystemMouseCursors.allScroll;
      case 'forbidden':
        return SystemMouseCursors.forbidden;
      case 'basic':
      default:
        return SystemMouseCursors.basic;
    }
  }

  int _buttonFromPointerButtons(int buttons) {
    if ((buttons & kPrimaryMouseButton) != 0) return _kPrimaryMouseButton;
    if ((buttons & kSecondaryMouseButton) != 0) return _kSecondaryMouseButton;
    if ((buttons & kMiddleMouseButton) != 0) return _kTertiaryMouseButton;
    return 0;
  }

  void _reportWindowsSurfaceSize() {
    final viewId = _windowsViewId;
    if (viewId == null || !_windowsReady) return;

    final RenderBox? renderBox =
        _windowsWidgetKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final scaleFactor = View.of(context).devicePixelRatio;
    _globalWindowsChannel.invokeMethod('setSize', {
      'viewId': viewId,
      'width': renderBox.size.width,
      'height': renderBox.size.height,
      'scaleFactor': scaleFactor,
    });
  }

  Widget _buildWindowsWebview() {
    if (!_windowsReady || _windowsTextureId == null) {
      return const SizedBox.expand();
    }

    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _reportWindowsSurfaceSize();
        });
        return true;
      },
      child: SizeChangedLayoutNotifier(
        child: MouseRegion(
          cursor: _windowsCursor,
          child: Listener(
            onPointerHover: (event) {
              _globalWindowsChannel.invokeMethod('setCursorPos', {
                'viewId': _windowsViewId,
                'x': event.localPosition.dx,
                'y': event.localPosition.dy,
              });
            },
            onPointerDown: (event) {
              _globalWindowsChannel.invokeMethod('setCursorPos', {
                'viewId': _windowsViewId,
                'x': event.localPosition.dx,
                'y': event.localPosition.dy,
              });
              final button = _buttonFromPointerButtons(event.buttons);
              if (button != 0) {
                _downButtons[event.pointer] = button;
                _globalWindowsChannel.invokeMethod('setPointerButton', {
                  'viewId': _windowsViewId,
                  'button': button,
                  'isDown': true,
                });
              }
            },
            onPointerUp: (event) {
              final button = _downButtons.remove(event.pointer);
              if (button != null) {
                _globalWindowsChannel.invokeMethod('setPointerButton', {
                  'viewId': _windowsViewId,
                  'button': button,
                  'isDown': false,
                });
              }
            },
            onPointerCancel: (event) {
              final button = _downButtons.remove(event.pointer);
              if (button != null) {
                _globalWindowsChannel.invokeMethod('setPointerButton', {
                  'viewId': _windowsViewId,
                  'button': button,
                  'isDown': false,
                });
              }
            },
            onPointerMove: (event) {
              _globalWindowsChannel.invokeMethod('setCursorPos', {
                'viewId': _windowsViewId,
                'x': event.localPosition.dx,
                'y': event.localPosition.dy,
              });
            },
            onPointerSignal: (signal) {
              if (signal is PointerScrollEvent) {
                _globalWindowsChannel.invokeMethod('setScrollDelta', {
                  'viewId': _windowsViewId,
                  'dx': -signal.scrollDelta.dx,
                  'dy': -signal.scrollDelta.dy,
                });
              }
            },
            onPointerPanZoomUpdate: (signal) {
              if (signal.panDelta.dx.abs() > signal.panDelta.dy.abs()) {
                _globalWindowsChannel.invokeMethod('setScrollDelta', {
                  'viewId': _windowsViewId,
                  'dx': -signal.panDelta.dx,
                  'dy': 0.0,
                });
              } else {
                _globalWindowsChannel.invokeMethod('setScrollDelta', {
                  'viewId': _windowsViewId,
                  'dx': 0.0,
                  'dy': signal.panDelta.dy,
                });
              }
            },
            child: Texture(
              textureId: _windowsTextureId!,
              filterQuality: widget.filterQuality,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // On extrait la couleur d'arrière-plan par défaut pour l'appliquer à toutes les plateformes
    final Color backgroundColor = widget.initialSettings.initialBackgroundColor ?? Colors.transparent;

    if (kIsWeb) {
      // Construit la vue une seule fois : voir le commentaire sur
      // `_webViewWidget` plus haut. Les callbacks (onMessageReceived,
      // onNavigationRequest...) restent lus dynamiquement à travers les
      // closures ci-dessous à chaque appel, donc leurs mises à jour
      // éventuelles (nouveau `widget` après un `didUpdateWidget`) sont
      // bien prises en compte sans reconstruire l'iframe.
      _webViewWidget ??= web_impl.buildWebview(
        initialUrl: widget.initialUrl,
        initialAsset: widget.initialAsset,
        initialData: widget.initialData,
        onMessageReceived: (controller, message) =>
            widget.onMessageReceived?.call(controller, message),
        onNavigationRequest: (controller, uri) =>
            widget.onNavigationRequest?.call(controller, uri) ?? true,
        onControllerCreated: _handleControllerCreated,
      );
      return Container(
        color: backgroundColor,
        child: _webViewWidget,
      );
    }

    final bool supportsContextMenuItems = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    final Map<String, dynamic> creationParams = <String, dynamic>{
      'initialUrl': widget.initialUrl,
      'initialAsset': widget.initialAsset,
      'initialFile': widget.initialFile,
      'initialData': widget.initialData?.toMap(),
      'initialCss': widget.initialCss,
      'initialSettings': widget.initialSettings.toMap(),
      'scrollbarTheme': _resolveDesktopScrollbarTheme(),
      if (supportsContextMenuItems) 'contextMenuItems': widget.contextMenuItems.map((e) => e.toMap()).toList(),
    };

    Widget platformWidget;

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final int effectiveSdkInt = _androidSdkInt ?? 23;
        final bool canUseSurfaceComposition = effectiveSdkInt >= 23;

        AndroidPlatformViewType chosenType = widget.initialSettings.androidPlatformViewType;

        if (chosenType == AndroidPlatformViewType.surfaceComposition && !canUseSurfaceComposition) {
          chosenType = AndroidPlatformViewType.hybridComposition;
        }

        switch (chosenType) {
          case AndroidPlatformViewType.surfaceComposition:
            platformWidget = PlatformViewLink(
              viewType: _kViewType,
              surfaceFactory: (context, controller) {
                return AndroidViewSurface(
                  controller: controller as AndroidViewController,
                  gestureRecognizers: widget.gestureRecognizers ?? const <Factory<OneSequenceGestureRecognizer>>{},
                  hitTestBehavior: PlatformViewHitTestBehavior.opaque,
                );
              },
              onCreatePlatformView: (params) {
                return PlatformViewsService.initSurfaceAndroidView(
                  id: params.id,
                  viewType: _kViewType,
                  layoutDirection: widget.layoutDirection ?? TextDirection.ltr,
                  creationParams: creationParams,
                  creationParamsCodec: const StandardMessageCodec(),
                  onFocus: () => params.onFocusChanged(true),
                )
                  ..addOnPlatformViewCreatedListener((id) {
                    params.onPlatformViewCreated(id);
                    _onPlatformViewCreated(id);
                  })
                  ..create();
              },
            );
            break;

          case AndroidPlatformViewType.hybridComposition:
            platformWidget = PlatformViewLink(
              viewType: _kViewType,
              surfaceFactory: (context, controller) {
                return AndroidViewSurface(
                  controller: controller as AndroidViewController,
                  gestureRecognizers: widget.gestureRecognizers ?? const <Factory<OneSequenceGestureRecognizer>>{},
                  hitTestBehavior: PlatformViewHitTestBehavior.opaque,
                );
              },
              onCreatePlatformView: (params) {
                return PlatformViewsService.initExpensiveAndroidView(
                  id: params.id,
                  viewType: _kViewType,
                  layoutDirection: widget.layoutDirection ?? TextDirection.ltr,
                  creationParams: creationParams,
                  creationParamsCodec: const StandardMessageCodec(),
                  onFocus: () => params.onFocusChanged(true),
                )
                  ..addOnPlatformViewCreatedListener((id) {
                    params.onPlatformViewCreated(id);
                    _onPlatformViewCreated(id);
                  })
                  ..create();
              },
            );
            break;

          case AndroidPlatformViewType.virtualDisplay:
            platformWidget = AndroidView(
              viewType: _kViewType,
              layoutDirection: widget.layoutDirection ?? TextDirection.ltr,
              gestureRecognizers: widget.gestureRecognizers,
              creationParams: creationParams,
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: _onPlatformViewCreated,
            );
            break;
        }
        break;

      case TargetPlatform.iOS:
        platformWidget = UiKitView(
          viewType: _kViewType,
          onPlatformViewCreated: _onPlatformViewCreated,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        );
        break;

      case TargetPlatform.macOS:
        platformWidget = AppKitView(
          viewType: _kViewType,
          onPlatformViewCreated: _onPlatformViewCreated,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        );
        break;

      case TargetPlatform.windows:
        platformWidget = LayoutBuilder(
          key: _windowsWidgetKey,
          builder: (context, constraints) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _reportWindowsSurfaceSize();
            });
            return SizedBox(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              child: _buildWindowsWebview(),
            );
          },
        );
        break;

      case TargetPlatform.linux:
        platformWidget = _LinuxGeometryObserver(
          onGeometryChanged: _handleLinuxGeometryChanged,
          onDetached: () => _pushLinuxFrame(Rect.zero, visible: false),
          child: const SizedBox.expand(),
        );
        break;

      default:
        platformWidget = const Center(
          child: Text('Plateforme non supportée par webview_plus'),
        );
    }

    // On encapsule la vue finale de la plateforme choisie dans un Container coloré
    return Container(
      color: backgroundColor,
      child: platformWidget,
    );
  }

  void _onPlatformViewCreated(int id) {
    final bool supportsContextMenuItems = !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
    final controller = WebviewBaseController.init(
      id,
      onNavigationRequest: widget.onNavigationRequest,
      onMessageReceived: widget.onMessageReceived,
      onLoadStart: widget.onLoadStart,
      onLoadStop: widget.onLoadStop,
      onDOMContentLoaded: widget.onDOMContentLoaded,
      onReceivedError: widget.onReceivedError,
      onFontsIsLoaded: widget.onFontsIsLoaded,
      onLoadResource: widget.onLoadResource,
      contextMenuItems: supportsContextMenuItems ? widget.contextMenuItems : const [],
    );
    _handleControllerCreated(controller);
  }

  void _handleControllerCreated(WebviewPlusController controller) {
    // `controller` est un `WebviewPlusController` natif sur
    // Android/iOS/macOS/Windows/Linux, ou un `WebviewPlusWebController` sur
    // Web (voir `webview_plus_web.dart`). Les deux implémentent
    // [WebviewPlusController], type désormais accepté par
    // [WebviewCreatedCallback] : pas de filtrage par type ici, sous peine de
    // ne jamais notifier l'hôte côté Web.
    widget.onWebViewCreated?.call(controller);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_windowsViewId != null) {
      _globalWindowsChannel.invokeMethod('dispose', {'viewId': _windowsViewId});
    }
    if (_linuxViewId != null) {
      _globalLinuxChannel.invokeMethod('dispose', {'viewId': _linuxViewId});
    }
    super.dispose();
  }
}

/// Convertit chaque `paint()` du sous-arbre en rectangle exprimé dans les
/// coordonnées globales de la fenêtre (`getTransformTo(null)`), afin de
/// positionner le `GtkWidget` natif en conséquence (voir `_initLinuxWebview`
/// / `setFrame`). Porté depuis l'implémentation de référence
/// `linux_webview_widget.dart` (approche `webview_flutter_platform_interface`
/// pour Linux).
class _LinuxGeometryObserver extends SingleChildRenderObjectWidget {
  const _LinuxGeometryObserver({
    required this.onGeometryChanged,
    required this.onDetached,
    required Widget child,
  }) : super(child: child);

  final ValueChanged<Rect> onGeometryChanged;
  final VoidCallback onDetached;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _LinuxGeometryRenderBox(
      onGeometryChanged: onGeometryChanged,
      onDetached: onDetached,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _LinuxGeometryRenderBox renderObject,
  ) {
    renderObject
      ..onGeometryChanged = onGeometryChanged
      ..onDetached = onDetached;
  }
}

class _LinuxGeometryRenderBox extends RenderProxyBox {
  _LinuxGeometryRenderBox({
    required this._onGeometryChanged,
    required this._onDetached,
  });

  ValueChanged<Rect> _onGeometryChanged;
  VoidCallback _onDetached;

  set onGeometryChanged(ValueChanged<Rect> value) {
    _onGeometryChanged = value;
  }

  set onDetached(VoidCallback value) {
    _onDetached = value;
  }

  @override
  void detach() {
    _onDetached();
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!attached) {
      return;
    }
    final Matrix4 transform = getTransformTo(null);
    final Offset topLeft = MatrixUtils.transformPoint(transform, Offset.zero);
    final Offset bottomRight = MatrixUtils.transformPoint(
      transform,
      Offset(size.width, size.height),
    );
    final Rect rect = Rect.fromLTRB(
      math.min(topLeft.dx, bottomRight.dx),
      math.min(topLeft.dy, bottomRight.dy),
      math.max(topLeft.dx, bottomRight.dx),
      math.max(topLeft.dy, bottomRight.dy),
    );
    _onGeometryChanged(rect);
  }
}