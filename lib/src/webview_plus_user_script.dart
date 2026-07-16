/// Moment d'injection d'un [UserScript] par rapport au chargement de la page.
enum UserScriptInjectionTime {
  /// Injecté avant que le premier script de la page n'ait la main
  /// (équivalent `WKUserScriptInjectionTime.atDocumentStart` sur
  /// iOS/macOS, `WebViewCompat.addDocumentStartJavaScript` sur Android).
  /// C'est le seul moment fiable pour poser une variable globale (thème,
  /// config, feature flags, ...) *avant* que le JS de la page ne
  /// s'exécute.
  atDocumentStart,

  /// Injecté juste après `DOMContentLoaded`, une fois le DOM disponible
  /// mais pas nécessairement les ressources (images, polices, ...).
  atDocumentEnd,
}

/// Script JavaScript injecté automatiquement par la Webview dans chaque
/// page chargée, sans action requise côté page elle-même.
///
/// Passé via `WebviewSettings(initialUserScripts: [...])`. Exemple
/// classique : exposer un paramètre de thème avant que la page ne se mette
/// à le lire :
///
/// ```dart
/// final initThemeScript = UserScript(
///   source: "window.appTheme = '$themeParam';",
///   injectionTime: UserScriptInjectionTime.atDocumentStart,
/// );
///
/// WebviewWidget(
///   initialSettings: WebviewSettings(
///     initialUserScripts: [initThemeScript],
///   ),
///   ...
/// )
/// ```
///
/// **Toutes plateformes natives** (Android, iOS, macOS). Ignoré sur Web.
class UserScript {
  const UserScript({
    required this.source,
    this.injectionTime = UserScriptInjectionTime.atDocumentStart,
    this.forMainFrameOnly = true,
  });

  /// Code JavaScript à exécuter.
  final String source;

  /// Moment d'injection (voir [UserScriptInjectionTime]).
  final UserScriptInjectionTime injectionTime;

  /// Si `false`, le script est aussi injecté dans les iframes de la page
  /// (pas seulement le document principal). `true` par défaut.
  ///
  /// **Android** : appliqué uniquement pour les scripts en
  /// [UserScriptInjectionTime.atDocumentStart] (limite de
  /// `WebViewCompat.addDocumentStartJavaScript`, qui ne cible que le frame
  /// principal quel que soit ce réglage) ; sans effet sur les scripts en
  /// `atDocumentEnd`, injectés uniquement dans le frame principal.
  final bool forMainFrameOnly;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'source': source,
        'injectionTime': injectionTime.name,
        'forMainFrameOnly': forMainFrameOnly,
      };
}
