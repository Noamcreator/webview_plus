import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Emplacement d'une Webview Linux en **mode intégré** (voir
/// `linux/rendering/texture_bridge_linux.h`).
///
/// Le vrai widget GTK (WebKitWebView) est placé SOUS la vue Flutter, dont le
/// fond est transparent. Ce widget :
///  1. « perce un trou » : il peint son rectangle en `BlendMode.clear`, ce
///     qui efface ce que les widgets parents (Scaffold, Container...) ont
///     peint à cet endroit, et laisse voir la Webview native en dessous ;
///  2. signale son rectangle (pixels logiques, relatif à la vue Flutter) à
///     chaque changement, pour que le natif positionne la Webview.
///
/// Les widgets Flutter placés AU-DESSUS dans l'arbre (dialogs, barres,
/// spinner de chargement, rideau de couleur) sont peints après le trou : ils
/// restent donc visibles par-dessus la Webview.
///
/// Limite : un ancêtre qui peint dans un calque séparé (Opacity,
/// ShaderMask, BackdropFilter...) autour de la Webview empêche le trou de
/// traverser jusqu'à la fenêtre ; éviter ces widgets autour de la Webview.
class LinuxEmbeddedHole extends LeafRenderObjectWidget {
  const LinuxEmbeddedHole({super.key, required this.onRectChanged});

  /// Appelé (au plus une fois par changement) avec le rectangle courant.
  final ValueChanged<Rect> onRectChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLinuxEmbeddedHole(onRectChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderLinuxEmbeddedHole renderObject,
  ) {
    renderObject.onRectChanged = onRectChanged;
  }
}

class _RenderLinuxEmbeddedHole extends RenderBox {
  _RenderLinuxEmbeddedHole(this.onRectChanged);

  ValueChanged<Rect> onRectChanged;
  Rect? _lastReported;

  static final Paint _clearPaint = Paint()
    ..blendMode = BlendMode.clear
    ..isAntiAlias = false;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  // Capte les événements souris/molette : ils sont ensuite retransmis au
  // WebKitWebView par le `Listener` du widget parent.
  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    context.canvas.drawRect(offset & size, _clearPaint);

    final Rect rect = localToGlobal(Offset.zero) & size;
    final Rect? last = _lastReported;
    if (last == null ||
        (rect.left - last.left).abs() >= 0.5 ||
        (rect.top - last.top).abs() >= 0.5 ||
        (rect.width - last.width).abs() >= 0.5 ||
        (rect.height - last.height).abs() >= 0.5) {
      _lastReported = rect;
      onRectChanged(rect);
    }
  }
}
