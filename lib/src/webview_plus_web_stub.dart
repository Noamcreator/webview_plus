import 'package:flutter/widgets.dart';
import 'webview_plus_controller.dart';
import 'webview_plus_initial_data.dart';
import 'webview_plus_settings.dart';

/// Stub utilisé hors Web (Android/iOS/macOS/Windows/Linux) : jamais appelé
/// en pratique, il existe uniquement pour que l'import conditionnel
/// compile. La signature doit rester identique à celle de
/// `webview_plus_web.dart`.
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
  throw UnsupportedError(
      'buildWebview (implémentation Web) appelé sur une plateforme non-Web.');
}
