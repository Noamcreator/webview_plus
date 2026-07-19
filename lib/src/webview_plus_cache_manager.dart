import 'package:flutter/services.dart';

/// Gère les données persistées par les Webviews de l'application (cache
/// HTTP, cookies, `localStorage`/`IndexedDB`...), indépendamment de toute
/// instance de [WebviewWidget] déjà affichée à l'écran.
///
/// **Toutes plateformes**, avec les nuances suivantes :
/// - Android : `android.webkit.WebStorage` / `CookieManager` (globaux au
///   process, comme sur un vrai navigateur).
/// - iOS/macOS : `WKWebsiteDataStore.default()` (partagé par toutes les
///   `WKWebView` non-`incognito` de l'app).
/// - Windows : profil WebView2 par défaut, dérivé de la première Webview
///   créée durant la session — voir la note sur [clearCache] ci-dessous.
/// - Linux : `WebKitWebContext` par défaut (`webkit_web_context_get_default`).
///
/// N'affecte jamais les Webviews en mode [WebviewSettings.incognito], dont
/// les données ne sont de toute façon jamais persistées.
class WebviewCacheManager {
  WebviewCacheManager._();

  static const MethodChannel _channel = MethodChannel('plugins.noam.me/webview_plus_info');

  /// Vide uniquement le cache HTTP (ressources réseau : images, scripts,
  /// feuilles de style, réponses `fetch`/XHR mises en cache...). Les
  /// cookies et le `localStorage`/`IndexedDB` ne sont pas affectés.
  ///
  /// > **Windows** : nécessite qu'au moins une [WebviewWidget] ait déjà été
  /// > créée depuis le lancement de l'app (le profil WebView2 par défaut
  /// > n'existe qu'à partir de là). Appelez-la après la création de votre
  /// > première Webview plutôt qu'au tout lancement de l'app.
  static Future<void> clearCache() => _invoke('clearCache');

  /// Supprime tous les cookies stockés par les Webviews de l'application.
  static Future<void> clearCookies() => _invoke('clearCookies');

  /// Supprime l'intégralité des données web persistées : cache HTTP,
  /// cookies, `localStorage`, `sessionStorage`, `IndexedDB`, service
  /// workers, etc. Équivalent à réinitialiser complètement le profil de
  /// navigation.
  static Future<void> clearAllData() => _invoke('clearAllData');

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Plateforme ne supportant pas encore cet appel : no-op silencieux,
      // comme pour [WebviewPlusPreloader].
    }
  }
}