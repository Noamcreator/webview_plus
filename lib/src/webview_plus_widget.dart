import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:webview_plus/src/webview_plus_environment.dart';
import 'webview_plus_context_menu.dart';
import 'webview_plus_controller.dart';
import 'webview_plus_settings.dart';
import 'webview_plus_web.dart'
    if (dart.library.io) 'webview_plus_web_stub.dart' as web_impl;

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
    this.filterQuality = FilterQuality.none,
    this.contextMenuItems = const <ContextMenuItem>[],
  }) : assert(
          (initialUrl != null ? 1 : 0) +
                  (initialAsset != null ? 1 : 0) +
                  (initialFile != null ? 1 : 0) <=
              1,
          'Un seul type de source initiale peut être fourni parmi '
          'initialUrl, initialAsset et initialFile.',
        );

  final Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers;
  final TextDirection? layoutDirection;
  final WebViewEnvironment? webViewEnvironment;
  final String? initialUrl;
  final String? initialAsset;
  final String? initialFile;
  final WebviewSettings initialSettings;
  final WebviewCreatedCallback? onWebViewCreated;
  final NavigationRequestCallback? onNavigationRequest;
  final WebviewMessageCallback? onMessageReceived;
  final WebviewLoadCallback? onLoadStart;
  final WebviewLoadCallback? onLoadStop;
  final WebviewLoadCallback? onDOMContentLoaded;
  final WebviewErrorCallback? onReceivedError;

  final WebviewControllerCallback? onWindowFocus;
  final WebviewControllerCallback? onWindowBlur;

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
  int? _androidSdkInt;
  bool _androidHcppSupported = false;
  bool _isAndroidReady = false;

  int? _windowsViewId;
  int? _windowsTextureId;
  bool _windowsReady = false;
  MouseCursor _windowsCursor = SystemMouseCursors.basic;

  int? _linuxViewId;
  bool _linuxCreated = false;
  Rect _linuxLastRect = Rect.zero;
  bool _linuxLastVisible = false;

  final GlobalKey _windowsWidgetKey = GlobalKey();
  final Map<int, int> _downButtons = <int, int>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      _initWindowsWebview();
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      _initLinuxWebview();
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _loadAndroidSdkInt();
    }
  }

  Future<void> _loadAndroidSdkInt() async {
    try {
      final sdk = await _getAndroidSdkInt();
      final hcppSupported = await HybridAndroidViewController.checkIfSupported();
      
      if (!mounted) return;

      setState(() {
        _androidSdkInt = sdk;
        _androidHcppSupported = hcppSupported;
        _isAndroidReady = true; // On signale que la configuration est prête !
      });
    } catch (e) {
      debugPrint("Erreur lors de la configuration Android : $e");
      if (mounted) {
        setState(() {
          _isAndroidReady = true; // Fallback pour ne pas bloquer l'interface en cas d'erreur
        });
      }
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
        'initialSettings': widget.initialSettings.toMap(),
        'userDataFolder': widget.webViewEnvironment?.settings?.userDataFolder,
      });

      final Map<dynamic, dynamic> response =
          Map<dynamic, dynamic>.from(result as Map);
      final textureId = response['textureId'] as int?;

      final controller = WebviewPlusController.init(
        id,
        onNavigationRequest: widget.onNavigationRequest,
        onMessageReceived: widget.onMessageReceived,
        onLoadStart: widget.onLoadStart,
        onLoadStop: widget.onLoadStop,
        onReceivedError: widget.onReceivedError,
        onWindowFocus: widget.onWindowFocus,
        onWindowBlur: widget.onWindowBlur,
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
        'initialSettings': widget.initialSettings.toMap(),
      });

      if (!mounted) return;

      final controller = WebviewPlusController.init(
        id,
        onNavigationRequest: widget.onNavigationRequest,
        onMessageReceived: widget.onMessageReceived,
        onLoadStart: widget.onLoadStart,
        onLoadStop: widget.onLoadStop,
        onReceivedError: widget.onReceivedError,
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
      case 'resizeLeftRight':
        return SystemMouseCursors.resizeLeftRight;
      case 'resizeUpDown':
        return SystemMouseCursors.resizeUpDown;
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
    if (kIsWeb) {
      return web_impl.buildWebview(
        initialUrl: widget.initialUrl,
        initialAsset: widget.initialAsset,
        onMessageReceived: widget.onMessageReceived,
        onNavigationRequest: widget.onNavigationRequest,
        onControllerCreated: _handleControllerCreated,
      );
    }

    // Les éléments personnalisés du menu contextuel (`ContextMenuItem`) ne
    // concernent que la barre de sélection de texte native mobile
    // (Android/iOS) : il n'existe pas d'équivalent sur desktop (le clic
    // droit y ouvre un menu contextuel de navigateur classique, pas une
    // barre de sélection), donc on ne l'envoie pas ailleurs.
    final bool supportsContextMenuItems = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    final Map<String, dynamic> creationParams = <String, dynamic>{
      'initialUrl': widget.initialUrl,
      'initialAsset': widget.initialAsset,
      'initialFile': widget.initialFile,
      'initialSettings': widget.initialSettings.toMap(),
      if (supportsContextMenuItems)
        'contextMenuItems':
            widget.contextMenuItems.map((e) => e.toMap()).toList(),
    };

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        if (!_isAndroidReady) {
          return const SizedBox.expand();
        }

        if (widget.initialSettings.useHybridComposition) {
          return PlatformViewLink(
            viewType: _kViewType,
            surfaceFactory: (context, controller) {
              return AndroidViewSurface(
                controller: controller as AndroidViewController,
                gestureRecognizers: widget.gestureRecognizers ?? const <Factory<OneSequenceGestureRecognizer>>{},
                hitTestBehavior: PlatformViewHitTestBehavior.opaque,
              );
            },
            onCreatePlatformView: (params) {
              if(_androidHcppSupported) {
                return PlatformViewsService.initHybridAndroidView(
                  id: params.id,
                  viewType: _kViewType,
                  layoutDirection: widget.layoutDirection ?? TextDirection.ltr,
                  creationParams: creationParams,
                  creationParamsCodec: const StandardMessageCodec(),
                  onFocus: () => params.onFocusChanged(true),
                )..addOnPlatformViewCreatedListener((id) {
                    params.onPlatformViewCreated(id);
                    _onPlatformViewCreated(id);
                  })
                  ..create();
              }
              else {
                return PlatformViewsService.initSurfaceAndroidView(
                  id: params.id,
                  viewType: _kViewType,
                  layoutDirection: widget.layoutDirection ?? TextDirection.ltr,
                  creationParams: creationParams,
                  creationParamsCodec: const StandardMessageCodec(),
                  onFocus: () => params.onFocusChanged(true),
                )..addOnPlatformViewCreatedListener((id) {
                    params.onPlatformViewCreated(id);
                    _onPlatformViewCreated(id);
                  })
                  ..create();
              }
            },
          );
        } 
        else {
          return AndroidView(
            viewType: _kViewType,
            layoutDirection: widget.layoutDirection,
            gestureRecognizers: widget.gestureRecognizers,
            creationParams: creationParams,
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _onPlatformViewCreated
          );
        }

      case TargetPlatform.iOS:
        // iOS utilise systématiquement la composition native complète
        // (équivalent de la hybrid composition Android) : il n'existe pas
        // de mode "virtual display" ni de flag `useHybridComposition` côté
        // UIKit, donc `initialSettings.useHybridComposition` est ignoré ici.
        return UiKitView(
          viewType: _kViewType,
          onPlatformViewCreated: _onPlatformViewCreated,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          layoutDirection: widget.layoutDirection,
          gestureRecognizers: widget.gestureRecognizers,
        );

      case TargetPlatform.macOS:
        // Idem sur macOS : `AppKitView` (et non `UiKitView`, réservé à
        // iOS/Mac Catalyst) compose nativement la NSView dans l'arbre
        // Flutter, sans notion de hybrid composition.
        return AppKitView(
          viewType: _kViewType,
          onPlatformViewCreated: _onPlatformViewCreated,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          layoutDirection: widget.layoutDirection,
          gestureRecognizers: widget.gestureRecognizers,
        );

      case TargetPlatform.windows:
        return LayoutBuilder(
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

      case TargetPlatform.linux:
        return _LinuxGeometryObserver(
        onGeometryChanged: _handleLinuxGeometryChanged,
        onDetached: () => _pushLinuxFrame(Rect.zero, visible: false),
        child: const SizedBox.expand(),
      );

      default:
        return const Center(
          child: Text('Plateforme non supportée par webview_plus'),
        );
    }
  }

  void _onPlatformViewCreated(int id) {
    final bool supportsContextMenuItems = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final controller = WebviewPlusController.init(
      id,
      onNavigationRequest: widget.onNavigationRequest,
      onMessageReceived: widget.onMessageReceived,
      onLoadStart: widget.onLoadStart,
      onLoadStop: widget.onLoadStop,
      onReceivedError: widget.onReceivedError,
      contextMenuItems: supportsContextMenuItems ? widget.contextMenuItems : const [],
    );
    _handleControllerCreated(controller);
  }

  void _handleControllerCreated(WebviewPlatformController controller) {
    if (controller is WebviewPlusController) {
      widget.onWebViewCreated?.call(controller);
    }
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