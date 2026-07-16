import 'package:flutter/painting.dart' show Color;

import 'webview_plus_context_menu.dart';
import 'webview_plus_user_script.dart';

enum AndroidPlatformViewType {
  /// Texture Layer Hybrid Composition (recommandé, API 23+).
  surfaceComposition,

  /// Hybrid Composition classique (génère parfois du jank d'animation, mais robuste).
  hybridComposition,

  /// Virtual Display (TextureView). Défilement potentiellement moins fluide,
  /// mais très compatible avec le vieux matériel.
  virtualDisplay,
}

/// Regroupe l'ensemble des réglages initiaux applicables à la Webview.
///
/// Passé via `WebviewPlus(initialSettings: ...)`, transmis sous forme
/// de `Map` à la vue native au moment de sa création. Certains réglages
/// sont propres à une plateforme ; ils sont ignorés silencieusement sur
/// les autres (voir la documentation de chaque champ).
class WebviewSettings {
  const WebviewSettings({
    this.javaScriptEnabled = true,
    this.domStorageEnabled = true,
    this.allowFileAccess = true,
    this.allowContentAccess = true,
    this.supportZoom = true,
    this.builtInZoomControls = true,
    this.displayZoomControls = false,
    this.mediaPlaybackRequiresUserGesture = true,
    this.transparentBackground = false,
    this.initialBackgroundColor,
    this.userAgent,
    this.isInspectable = false,
    this.disableContextMenu = false,
    this.disableLongPressContextMenuOnLinks = false,
    this.selectionTextColor,
    this.selectionHandleColor,
    this.androidPlatformViewType = AndroidPlatformViewType.surfaceComposition,
    this.allowsBackForwardNavigationGestures = false,
    this.allowsLinkPreview = false,
    this.disabledDefaultContextMenuItems = const <DefaultContextMenuItem>{},
    this.disableLinkHoverPreview = true,
    this.disablePrinting = false,
    this.initialUserScripts = const <UserScript>[],
    this.disableKeyboardResize = false,
  });

  /// Active/désactive l'exécution JavaScript (toutes plateformes).
  final bool javaScriptEnabled;

  /// Active/désactive localStorage/sessionStorage/IndexedDB
  /// (Android/iOS/macOS).
  final bool domStorageEnabled;

  /// Autorise l'accès aux fichiers via `file://` (Android).
  final bool allowFileAccess;

  /// Autorise l'accès aux content providers via `content://` (Android).
  final bool allowContentAccess;

  /// Autorise le pincement pour zoomer (toutes plateformes).
  final bool supportZoom;

  /// Affiche les contrôles de zoom natifs +/- (Android).
  final bool builtInZoomControls;

  /// Affiche les boutons de zoom à l'écran (Android). Sans effet si
  /// [builtInZoomControls] vaut `false`.
  final bool displayZoomControls;

  /// Empêche la lecture automatique des médias sans geste utilisateur.
  final bool mediaPlaybackRequiresUserGesture;

  /// Rend le fond de la Webview transparent (utile pour superposer du
  /// contenu Flutter derrière/au-dessus de la page).
  final bool transparentBackground;

  /// Couleur d'arrière-plan par défaut du widget pendant son chargement
  /// ou si l'arrière-plan de la Webview est transparent.
  final Color? initialBackgroundColor;

  /// User-Agent personnalisé. `null` = valeur par défaut de la plateforme.
  final String? userAgent;

  /// Active l'inspection à distance via Chrome DevTools / Safari Web
  /// Inspector. À réserver au mode debug.
  final bool isInspectable;

  /// Désactive entièrement le menu contextuel natif (sélection de texte,
  /// copier/coller, "ouvrir l'image", etc.) déclenché par un appui long.
  final bool disableContextMenu;

  /// Désactive uniquement le menu contextuel déclenché par un appui long
  /// sur un lien ou une image-lien. Sans effet si [disableContextMenu]
  /// vaut déjà `true`.
  final bool disableLongPressContextMenuOnLinks;

  /// Couleur de surbrillance du texte sélectionné (et, si le système le
  /// permet, des poignées de sélection).
  ///
  /// Sur Android, ce réglage a deux effets :
  /// 1. Un `::selection { background-color: ... }` CSS, appliqué à chaque
  ///    page chargée, qui recolore fidèlement la surbrillance du texte
  ///    sélectionné.
  /// 2. Une tentative de recoloration native de la "goutte" tactile de
  ///    sélection elle-même : la Webview est créée dans un contexte dont
  ///    l'attribut de thème `android:colorControlActivated` est surchargé
  ///    dynamiquement avec cette couleur (c'est cet attribut que Chromium
  ///    utilise en interne pour teinter les poignées de sélection).
  ///
  /// ⚠️ Le point 2 est du "best effort" : Android ne permet pas de
  /// surcharger un attribut de thème avec une valeur arbitraire fournie à
  /// l'exécution (seules des ressources compilées peuvent l'être). Le
  /// plugin embarque donc une ressource couleur par défaut,
  /// `@color/webview_plus_selection_handle_color` (voir
  /// `android/src/main/res/values/colors.xml`), que la Webview utilise
  /// pour son thème de poignées ; **pour une valeur figée à la compilation,
  /// redéfinissez cette ressource dans les `res/values` de votre propre
  /// application** (mécanisme standard de surcharge de ressources d'une
  /// librairie Android). La valeur dynamique passée ici via [Color] pilote
  /// fiablement le CSS (point 1) dans tous les cas ; elle ne met à jour la
  /// teinte native des poignées (point 2) que si elle correspond à la
  /// ressource déclarée à la compilation.
  final Color? selectionTextColor;
  
  final Color? selectionHandleColor;

  /// Type de composition et rendu sur Android.
  /// Par défaut : [AndroidPlatformViewType.surfaceComposition].
  final AndroidPlatformViewType androidPlatformViewType;

  /// Autorise les gestes de balayage pour naviguer précédent/suivant (iOS).
  final bool allowsBackForwardNavigationGestures;

  /// Autorise l'aperçu de lien façon "Peek & Pop" (iOS).
  final bool allowsLinkPreview;

  /// Éléments par défaut du menu contextuel (copier / coller / tout
  /// sélectionner / couper) à désactiver individuellement.
  ///
  /// **Android et iOS uniquement** (voir [DefaultContextMenuItem]) : sans
  /// effet sur desktop, où il n'existe pas de barre de sélection de texte
  /// tactile équivalente. Sans effet non plus si [disableContextMenu] vaut
  /// déjà `true` (le menu entier est alors masqué). Les éléments
  /// personnalisés ajoutés via `WebviewPlus(contextMenuItems: ...)` ne
  /// sont jamais affectés par ce réglage.
  final Set<DefaultContextMenuItem> disabledDefaultContextMenuItems;

  /// Masque la barre de statut affichant l'URL survolée en bas de la
  /// fenêtre (desktop uniquement, principalement Windows/Webview2). Vrai
  /// par défaut. Sans effet sur mobile, où cette barre n'existe pas.
  final bool disableLinkHoverPreview;

  /// Désactive l'impression déclenchée via le raccourci Ctrl+P (et,
  /// lorsque la plateforme le permet, via `window.print()`). Faux par
  /// défaut (impression autorisée).
  final bool disablePrinting;

  /// Scripts JavaScript injectés automatiquement dans chaque page chargée
  /// (voir [UserScript]). **Android, iOS, macOS.**
  final List<UserScript> initialUserScripts;

  /// Empêche la Webview de se redimensionner (rétrécir) lorsque le
  /// clavier virtuel apparaît. **Android et iOS uniquement.**
  ///
  /// Réglage purement natif, basé sur les insets système (IME) : il
  /// n'injecte aucun script s'appuyant sur `window.innerHeight` (ce genre
  /// de hack JS ne fait que masquer visuellement le symptôme après coup et
  /// provoque un flash de redimensionnement). Faux par défaut : la
  /// Webview suit le comportement standard de la plateforme (elle se
  /// redimensionne pour laisser la place au clavier).
  final bool disableKeyboardResize;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'javaScriptEnabled': javaScriptEnabled,
        'domStorageEnabled': domStorageEnabled,
        'allowFileAccess': allowFileAccess,
        'allowContentAccess': allowContentAccess,
        'supportZoom': supportZoom,
        'builtInZoomControls': builtInZoomControls,
        'displayZoomControls': displayZoomControls,
        'mediaPlaybackRequiresUserGesture': mediaPlaybackRequiresUserGesture,
        'transparentBackground': transparentBackground,
        'initialBackgroundColor': initialBackgroundColor?.toARGB32(),
        'userAgent': userAgent,
        'isInspectable': isInspectable,
        'disableContextMenu': disableContextMenu,
        'disableLongPressContextMenuOnLinks': disableLongPressContextMenuOnLinks,
        'selectionTextColor': selectionTextColor?.toARGB32(),
        'selectionHandleColor ': selectionHandleColor ?.toARGB32(),
        'androidPlatformViewType': androidPlatformViewType.name,
        'allowsBackForwardNavigationGestures': allowsBackForwardNavigationGestures,
        'allowsLinkPreview': allowsLinkPreview,
        'disabledDefaultContextMenuItems': disabledDefaultContextMenuItems.map((e) => e.name).toList(),
        'disableLinkHoverPreview': disableLinkHoverPreview,
        'disablePrinting': disablePrinting,
        'initialUserScripts': initialUserScripts.map((e) => e.toMap()).toList(),
        'disableKeyboardResize': disableKeyboardResize,
      };
}
