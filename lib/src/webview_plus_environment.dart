import 'dart:async';

/// Paramètres de configuration simplifiés pour l'environnement de la WebView.
class WebViewEnvironmentSettings {
  /// Le chemin absolu du répertoire où seront stockées les données utilisateur (cache, cookies, etc.).
  final String? userDataFolder;

  WebViewEnvironmentSettings({this.userDataFolder});

  Map<String, dynamic> toMap() {
    return {
      'userDataFolder': userDataFolder,
    };
  }
}

/// Instance simplifiée représentant l'environnement d'exécution de la WebView (notamment pour Windows).
class WebViewEnvironment {
  /// L'identifiant interne généré automatiquement pour faire le pont avec le code natif.
  final String id;

  /// Les paramètres de configuration appliqués à cet environnement.
  final WebViewEnvironmentSettings? settings;

  WebViewEnvironment._({required this.id, this.settings});

  /// Crée un nouvel environnement WebView avec les paramètres spécifiés.
  static Future<WebViewEnvironment> create({
    WebViewEnvironmentSettings? settings,
  }) async {
    // Génère un ID unique pour cet environnement (ex: timestamp ou uuid simple)
    final String uniqueId = DateTime.now().microsecondsSinceEpoch.toString();
    
    return WebViewEnvironment._(
      id: uniqueId,
      settings: settings,
    );
  }
}