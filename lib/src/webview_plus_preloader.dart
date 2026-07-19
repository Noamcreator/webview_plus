import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Déclenche, côté Android uniquement (no-op silencieux ailleurs), un
/// préchauffage du moteur WebView et/ou un préchargement réseau d'une URL,
/// **avant** qu'un [WebviewWidget] ne soit réellement affiché à l'écran.
///
/// Le préchauffage (voir [warmUp]) sort le coût d'initialisation du moteur
/// Chromium (dominant à la toute première Webview créée dans le process,
/// pas les suivantes) du chemin critique de la première ouverture visible
/// par l'utilisateur.
///
/// Le préchargement d'URL (voir [preloadUrl]) charge la page en arrière-plan
/// dans une Webview invisible et jetable pour remplir le cache HTTP partagé
/// par toutes les instances de l'app : la prochaine vraie Webview chargeant
/// la même URL en profite (sous réserve des en-têtes de cache envoyés par
/// le serveur — cet appel n'offre aucune garantie sur du contenu non
/// cacheable).
///
/// Exemple d'usage typique : dans une liste d'articles, précharger l'URL de
/// l'article probablement consulté ensuite dès que la liste est affichée.
class WebviewPlusPreloader {
  WebviewPlusPreloader._();

  static const MethodChannel _channel = MethodChannel('plugins.noam.me/webview_plus_info');

  static bool get _isSupportedPlatform => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Pré-construit [count] instance(s) de `WebView` Android en arrière-plan
  /// (entre 1 et 5, au-delà l'intérêt marginal ne justifie pas le coût
  /// mémoire). À appeler tôt dans la vie de l'app — par exemple juste après
  /// le premier frame affiché (`WidgetsBinding.instance.addPostFrameCallback`
  /// depuis votre écran d'accueil), pas avant `runApp` puisque le canal de
  /// méthode nécessite le binding Flutter déjà initialisé.
  static Future<void> warmUp({int count = 1}) async {
    if (!_isSupportedPlatform) return;
    try {
      await _channel.invokeMethod('warmUp', {'count': count});
    } catch (_) {
      // Best-effort : une erreur ici ne doit jamais empêcher le
      // fonctionnement normal de l'app.
    }
  }

  /// Précharge [url] en arrière-plan. Peut être appelé plusieurs fois pour
  /// des URLs différentes (chacune est prise en charge indépendamment) ;
  /// un appel répété avec la même URL pendant qu'un préchargement est déjà
  /// en cours pour celle-ci est ignoré côté natif.
  static Future<void> preloadUrl(String url) async {
    if (!_isSupportedPlatform) return;
    try {
      await _channel.invokeMethod('preloadUrl', {'url': url});
    } catch (_) {}
  }
}