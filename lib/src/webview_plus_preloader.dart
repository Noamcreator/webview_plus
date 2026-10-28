import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'webview_plus_context_menu.dart';
import 'webview_plus_initial_data.dart';
import 'webview_plus_settings.dart';

/// Optimisations de démarrage des Webviews (**Android uniquement** ;
/// no-op ailleurs).
///
/// Deux niveaux, du plus simple au plus efficace :
///
/// 1. [warmUp] : construit à l'avance des `WebView` vides (charge le moteur
///    Chromium et démarre son processus de rendu). À appeler au lancement
///    de l'app, juste après le premier frame. Gain : plusieurs centaines de
///    ms sur la première Webview affichée.
/// 2. [preloadDocument] : charge la page à l'avance dans une Webview
///    **détachée** (HTML, CSS, centaines de Ko de JS déjà analysés et
///    exécutés jusqu'à `DOMContentLoaded`). Quand un `WebviewWidget` est
///    ensuite créé avec EXACTEMENT les mêmes paramètres, il adopte cette
///    Webview déjà chargée : les événements (`onLoadStart`,
///    `onDOMContentLoaded`, `onLoadStop`...) sont rejoués dès que Dart est
///    prêt, et l'ouverture devient quasi instantanée. Une Webview de
///    remplacement est automatiquement rechargée en arrière-plan pour le
///    document suivant.
class WebviewPlusPreloader {
  WebviewPlusPreloader._();

  static const MethodChannel _channel = MethodChannel('plugins.noam.me/webview_plus_info');

  static bool get _isSupportedPlatform => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Construit à l'avance [count] `WebView` vierges (voir la doc de la
  /// classe). Best-effort : une erreur ne bloque jamais l'app.
  static Future<void> warmUp({int count = 1}) async {
    if (!_isSupportedPlatform) return;
    try {
      await _channel.invokeMethod('warmUp', {'count': count});
    } catch (_) {
      // Best-effort : une erreur ici ne doit jamais empêcher le
      // fonctionnement normal de l'app.
    }
  }

  /// Précharge [url] dans une Webview headless pour remplir le cache HTTP
  /// partagé (utile pour des pages distantes).
  static Future<void> preloadUrl(String url) async {
    if (!_isSupportedPlatform) return;
    try {
      await _channel.invokeMethod('preloadUrl', {'url': url});
    } catch (_) {}
  }

  /// Charge une page à l'avance, prête à être adoptée par un
  /// `WebviewWidget` créé avec les MÊMES paramètres (source initiale,
  /// `initialCss`, `initialSettings`, `contextMenuItems`, présence de
  /// `onLoadResource`). Au moindre écart la Webview préchargée est ignorée
  /// et le widget démarre normalement : aucune régression possible.
  ///
  /// Exemple (document de lecture) :
  /// ```dart
  /// await WebviewPlusPreloader.preloadDocument(
  ///   initialFile: WebViewSettingsService().getDocumentViewFilePath(),
  ///   initialSettings: getWebViewSettings(),
  ///   initialCss: getInitialCss(context),
  ///   contextMenuItems: getContextMenu(),
  /// );
  /// ```
  /// À appeler une fois l'app affichée (accueil), puis après un changement
  /// de thème/réglage qui modifie l'un de ces paramètres.
  static Future<void> preloadDocument({
    String? initialUrl,
    String? initialAsset,
    String? initialFile,
    WebviewInitialData? initialData,
    String? initialCss,
    WebviewSettings initialSettings = const WebviewSettings(),
    List<ContextMenuItem> contextMenuItems = const <ContextMenuItem>[],
    bool hasLoadResourceCallback = false,
  }) async {
    if (!_isSupportedPlatform) return;
    try {
      await _channel.invokeMethod('preloadDocument', <String, dynamic>{
        'initialUrl': initialUrl,
        'initialAsset': initialAsset,
        'initialFile': initialFile,
        'initialData': initialData?.toMap(),
        'initialCss': initialCss,
        'initialSettings': initialSettings.toMap(),
        'hasLoadResourceCallback': hasLoadResourceCallback,
        'contextMenuItems': contextMenuItems.map((e) => e.toMap()).toList(),
        'preloadKey': preloadKeyFor(
          initialUrl: initialUrl,
          initialAsset: initialAsset,
          initialFile: initialFile,
          initialData: initialData,
          initialCss: initialCss,
          initialSettings: initialSettings,
          contextMenuItems: contextMenuItems,
          hasLoadResourceCallback: hasLoadResourceCallback,
        ),
      });
    } catch (_) {}
  }

  /// Libère les Webviews préchargées / préchauffées (ex. `onTrimMemory`).
  static Future<void> clear() async {
    if (!_isSupportedPlatform) return;
    try {
      await _channel.invokeMethod('clearPreloads');
    } catch (_) {}
  }

  /// Empreinte déterministe des paramètres de création : deux vues ne sont
  /// interchangeables que si cette valeur est identique. Utilisée par le
  /// widget ET par [preloadDocument] (même code => même résultat).
  static String preloadKeyFor({
    String? initialUrl,
    String? initialAsset,
    String? initialFile,
    WebviewInitialData? initialData,
    String? initialCss,
    required WebviewSettings initialSettings,
    required List<ContextMenuItem> contextMenuItems,
    required bool hasLoadResourceCallback,
  }) {
    final String canonical = jsonEncode(<String, dynamic>{
      'u': initialUrl,
      'a': initialAsset,
      'f': initialFile,
      'd': initialData?.toMap(),
      'c': initialCss,
      's': initialSettings.toMap(),
      'm': contextMenuItems.map((e) => e.toMap()).toList(),
      'r': hasLoadResourceCallback,
    });
    // FNV-1a 32 bits, deux passes avec des graines différentes (64 bits
    // d'empreinte au total) : suffisant pour distinguer des configurations,
    // sans dépendance externe.
    int h1 = 0x811c9dc5;
    int h2 = 0x01000193;
    for (final int unit in canonical.codeUnits) {
      h1 = ((h1 ^ unit) * 0x01000193) & 0xFFFFFFFF;
      h2 = ((h2 ^ unit) * 0x85ebca6b) & 0xFFFFFFFF;
    }
    return '${h1.toRadixString(16).padLeft(8, '0')}${h2.toRadixString(16).padLeft(8, '0')}';
  }
}
