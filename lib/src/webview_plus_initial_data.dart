import 'package:flutter/foundation.dart';

/// Contenu initial (HTML, SVG, texte brut...) chargé directement dans la
/// Webview dès sa création, sans passer par une URL/un asset/un fichier.
///
/// Passé via `WebviewWidget(initialData: ...)`, mutuellement exclusif avec
/// [initialUrl]/[initialAsset]/[initialFile] (voir l'assertion du widget).
/// Équivalent "au démarrage" de `WebviewPlusController.loadData(...)`
/// (voir `webview_plus_controller.dart`), qui reste utilisable après coup
/// pour recharger un nouveau contenu.
///
/// Exemple :
/// ```dart
/// WebviewWidget(
///   initialData: WebviewInitialData(
///     '<html><body><h1>Bonjour</h1></body></html>',
///     baseUrl: 'https://mon-domaine.example',
///   ),
/// )
/// ```
@immutable
class WebviewInitialData {
  const WebviewInitialData(
    this.data, {
    this.mimeType = 'text/html',
    this.encoding = 'utf8',
    this.baseUrl,
    this.androidHistoryUrl,
  });

  /// Le contenu à charger (HTML par défaut, voir [mimeType]).
  final String data;

  /// Type MIME du contenu. `text/html` par défaut ; utile pour charger
  /// autre chose que du HTML (`image/svg+xml`, `text/plain`...).
  final String mimeType;

  /// Encodage du contenu. `utf8` par défaut.
  final String encoding;

  /// URL de base utilisée pour résoudre les chemins relatifs (images,
  /// scripts, styles...) et comme origine pour les appels réseau, cookies,
  /// `localStorage`, etc. effectués depuis [data]. `about:blank` si non
  /// fourni.
  ///
  /// ⚠️ **Windows** : WebView2 ne propose pas d'équivalent natif à
  /// `loadDataWithBaseURL`/`loadHTMLString(baseURL:)`. Le contenu y est
  /// chargé via `NavigateToString`, sans origine réseau réelle : [baseUrl]
  /// y est ignoré (chemins relatifs et appels réseau à privilégier via une
  /// vraie URL sur cette plateforme).
  final String? baseUrl;

  /// **Android uniquement.** URL utilisée pour l'historique de navigation
  /// (bouton "précédent"), distincte de [baseUrl]. Ignoré sur les autres
  /// plateformes.
  final String? androidHistoryUrl;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'data': data,
        'mimeType': mimeType,
        'encoding': encoding,
        'baseUrl': baseUrl,
        'androidHistoryUrl': androidHistoryUrl,
      };
}
