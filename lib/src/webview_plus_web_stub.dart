import 'package:flutter/widgets.dart';
import 'webview_plus_controller.dart';

/// Stub utilisé sur Android/iOS/macOS/Windows/Linux : cette fonction
/// n'est jamais appelée en pratique (le widget bascule sur les
/// PlatformView natifs), elle existe uniquement pour que l'import
/// conditionnel compile sur toutes les plateformes.
Widget buildWebview({
  required String? initialUrl,
  required String? initialAsset,
  required WebviewMessageCallback? onMessageReceived,
  required NavigationRequestCallback? onNavigationRequest,
  required void Function(WebviewPlatformController controller)
      onControllerCreated,
}) {
  throw UnsupportedError(
      'buildWebview (implémentation Web) appelé sur une plateforme non-Web.');
}
