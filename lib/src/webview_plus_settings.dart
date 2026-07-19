import 'package:flutter/painting.dart' show Color;

import 'webview_plus_context_menu.dart';
import 'webview_plus_user_script.dart';
import 'webview_plus_desktop_scrollbar_theme.dart';

enum AndroidPlatformViewType {
  /// Texture Layer Hybrid Composition (recommandé, API 23+).
  surfaceComposition,

  /// Hybrid Composition classique (génère parfois du jank d'animation, mais robuste).
  hybridComposition,

  /// Virtual Display (TextureView). Défilement potentiellement moins fluide,
  /// mais très compatible avec le vieux matériel.
  virtualDisplay,
}

/// Pilote la colorisation des barres de défilement natives.
///
/// **Windows uniquement** (WebView2/Chromium, via injection CSS
/// `::-webkit-scrollbar`). Sans effet sur les autres plateformes, où ce
/// niveau de personnalisation n'existe pas nativement (Android/iOS/macOS
/// masquent ou dessinent leurs propres indicateurs de défilement, voir
/// [WebviewSettings.hideNativeScrollbars] pour les masquer entièrement).
enum DesktopScrollbarThemeMode {
  /// Suit automatiquement le thème Flutter courant (`Theme.of(context)`) :
  /// couleurs dérivées de `ColorScheme.surface`/`onSurface`/`primary`, mises
  /// à jour dynamiquement si le thème change (ex. bascule clair/sombre).
  auto,

  /// Palette claire fixe, indépendante du thème Flutter.
  light,

  /// Palette sombre fixe, indépendante du thème Flutter.
  dark,

  /// Couleurs entièrement fournies par [WebviewSettings.windowsScrollbarTrackColor],
  /// [WebviewSettings.windowsScrollbarThumbColor] et
  /// [WebviewSettings.windowsScrollbarThumbHoverColor].
  custom,

  /// Masque entièrement les barres de défilement (le contenu reste
  /// défilable au clavier/molette/tactile).
  hidden,
}

/// Contrôle l'effet visuel appliqué lorsqu'on défile au-delà du contenu.
///
/// **Android** (`View.overScrollMode`) et, en best-effort via CSS
/// `overscroll-behavior`, **Windows/Linux**. Sans effet sur iOS/macOS, où
/// c'est [WebviewSettings.bounces] qui pilote ce comportement.
enum OverScrollMode {
  /// Toujours afficher l'effet de rebond/glow, même si le contenu ne
  /// dépasse pas la taille de la Webview.
  always,

  /// Uniquement si le contenu est défilable (comportement par défaut).
  ifContentScrolls,

  /// Jamais (défilement "sec", sans effet de bord).
  never,
}

// Forcer la version Ordinateur (Desktop) ou Mobile (Mobile) de la Webview et recommandée s'adapte aux préférences de l'appareil.
enum WebviewContentMode {
  recommended,
  mobile,
  desktop,
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
    this.windowsScrollbarTheme = const DesktopScrollbarTheme(),
    this.cacheEnabled = true,
    this.incognito = false,
    this.applicationNameForUserAgent,
    this.textZoom = 100,
    this.minimumFontSize,
    this.allowsInlineMediaPlayback = true,
    this.allowsPictureInPicture = true,
    this.javaScriptCanOpenWindowsAutomatically = false,
    this.geolocationEnabled = false,
    this.thirdPartyCookiesEnabled = true,
    this.forceDarkMode = false,
    this.overScrollMode = OverScrollMode.ifContentScrolls,
    this.webviewContentMode = WebviewContentMode.recommended,
    this.bounces = true,
    this.initialScale,
    this.hideNativeScrollbars = false,
    this.safeBrowsingEnabled = true,
    this.allowMixedContent = false,
    this.allowFileAccessFromFileURLs = false,
    this.allowUniversalAccessFromFileURLs = false,
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

  // -- Thème des barres de défilement (Windows) --------------------------

  /// Configuration personnalisée des barres de défilement pour Windows.
  final DesktopScrollbarTheme windowsScrollbarTheme;

  // -- Réglages génériques additionnels -----------------------------------

  /// Active le cache HTTP standard (respect des en-têtes `Cache-Control`/
  /// `ETag`). **Android/Windows/Linux.** Vrai par défaut. Sur iOS/macOS,
  /// piloté indirectement via [incognito] (WKWebView ne propose pas de
  /// réglage de cache indépendant du `websiteDataStore`).
  final bool cacheEnabled;

  /// Navigation "privée" : aucune donnée (cookies, cache, `localStorage`,
  /// historique) n'est persistée au-delà de la durée de vie de la Webview.
  /// **Toutes plateformes**, avec un niveau de garantie qui varie :
  /// - Android : `WebStorage`/cache mémoire uniquement (`LOAD_NO_CACHE`).
  /// - iOS/macOS : `WKWebsiteDataStore.nonPersistent()`.
  /// - Windows : profil WebView2 "InPrivate" dédié.
  /// - Linux : `WebKitWebContext` éphémère (`webkit_web_context_new_ephemeral`).
  final bool incognito;

  /// Ajouté au user-agent par défaut de la plateforme (généralement sous la
  /// forme `<UA par défaut> <valeur>`), sans écraser le user-agent complet
  /// (voir [userAgent] pour ça). **Toutes plateformes.**
  final String? applicationNameForUserAgent;

  /// Zoom du texte, en pourcentage (`100` = taille normale). **Android
  /// (`WebSettings.textZoom`), Windows et Linux** (zoom CSS équivalent).
  /// Sans effet sur iOS/macOS (WKWebView ne propose pas de réglage
  /// équivalent indépendant du zoom de page).
  final int textZoom;

  /// Taille de police minimale, en pixels CSS. **Android**
  /// (`WebSettings.minimumFontSize`) **et iOS/macOS** (16.0+, via
  /// `WKWebpagePreferences`/préférences de police). `null` = pas de minimum
  /// imposé.
  final int? minimumFontSize;

  /// Autorise la lecture vidéo "inline" (dans la page) plutôt qu'en plein
  /// écran forcé. **iOS uniquement** (`allowsInlineMediaPlayback`). Vrai
  /// par défaut. Ignoré ailleurs : Android/Windows/Linux lisent déjà les
  /// médias inline par défaut, sans réglage équivalent nécessaire.
  final bool allowsInlineMediaPlayback;

  /// Autorise le mode "picture in picture" pour les vidéos. **iOS/macOS
  /// uniquement.** Vrai par défaut.
  final bool allowsPictureInPicture;

  /// Autorise les pages à ouvrir de nouvelles fenêtres/popups via
  /// `window.open()` sans geste utilisateur préalable. **Toutes
  /// plateformes.** Faux par défaut (comportement le plus sûr).
  final bool javaScriptCanOpenWindowsAutomatically;

  /// Autorise l'API de géolocalisation web (`navigator.geolocation`).
  /// **Toutes plateformes.** Faux par défaut ; l'octroi effectif dépend
  /// aussi des permissions système/OS (à demander séparément côté Flutter).
  final bool geolocationEnabled;

  /// Autorise les cookies tiers (iframes cross-origin, trackers...).
  /// **Android uniquement** (`CookieManager.setAcceptThirdPartyCookies`).
  /// Vrai par défaut (comportement historique d'Android WebView). Sur les
  /// autres plateformes, ce réglage est piloté par le moteur lui-même et
  /// n'est pas exposé de la même façon.
  final bool thirdPartyCookiesEnabled;

  /// Force un rendu de page sombre même sur des sites qui n'implémentent
  /// pas `prefers-color-scheme`. **Android** (`WebSettingsCompat`, API 29+)
  /// **et Windows** (`PreferredColorScheme` WebView2). Faux par défaut :
  /// peut dégrader la lisibilité de certains sites mal supportés.
  final bool forceDarkMode;

  /// Effet visuel en fin de défilement (glow Android / `overscroll-behavior`
  /// CSS best-effort sur Windows/Linux). Voir [OverScrollMode].
  final OverScrollMode overScrollMode;

  // Forcer la version Ordinateur (Desktop) ou Mobile (Mobile) de la Webview et recommandée s'adapte aux préférences de l'appareil.
  final WebviewContentMode webviewContentMode;

  /// Active l'effet de rebond ("bounce") en fin de défilement. **iOS/macOS
  /// uniquement** (`UIScrollView.bounces`/`NSScrollView` équivalent). Vrai
  /// par défaut.
  final bool bounces;

  /// Échelle de zoom initiale, en pourcentage (`100` = taille normale).
  /// **Android uniquement** (`WebView.setInitialScale`). `null` = laisse la
  /// page définir son propre zoom (via sa meta viewport, le cas échéant).
  final int? initialScale;

  /// Masque entièrement les indicateurs de défilement natifs (le contenu
  /// reste défilable) :
  /// - Android : `verticalScrollBarEnabled`/`horizontalScrollBarEnabled`.
  /// - iOS : `showsVerticalScrollIndicator`/`showsHorizontalScrollIndicator`.
  /// - Windows : équivalent à [DesktopScrollbarThemeMode.hidden] (a priorité
  ///   sur [windowsScrollbarThemeMode] si `true`).
  /// - Linux : masquage CSS équivalent.
  /// - macOS : non applicable (le `WKWebView` macOS ne propose pas
  ///   d'indicateurs de défilement pilotables sans API privée) ; ignoré.
  final bool hideNativeScrollbars;

  /// Active la vérification Safe Browsing (pages de phishing/malware
  /// connues). **Android uniquement** (`WebSettings.setSafeBrowsingEnabled`).
  /// Vrai par défaut.
  final bool safeBrowsingEnabled;

  /// Autorise le contenu mixte (ressources `http://` chargées depuis une
  /// page `https://`). **Android** (`MIXED_CONTENT_ALWAYS_ALLOW` vs
  /// `MIXED_CONTENT_COMPATIBILITY_MODE`) **et Linux/Windows** (réglage
  /// équivalent du moteur). Faux par défaut (comportement le plus sûr).
  final bool allowMixedContent;

  /// Autorise une page chargée depuis `file://` à accéder, via
  /// `XMLHttpRequest`/`fetch`, à d'autres ressources `file://` (par exemple
  /// un fichier HTML qui va chercher un `.json` ou une image à côté de lui
  /// sur le disque). **iOS et macOS** (`WKPreferences` clé privée
  /// `allowFileAccessFromFileURLs`, équivalent de l'attribut WebKit du même
  /// nom). Faux par défaut : WebKit bloque ces accès par sécurité, ce qui
  /// est la source la plus fréquente d'un fichier local qui "ne s'ouvre
  /// pas" (ressources relatives introuvables). Sans effet sur
  /// Android/Windows/Linux, où le chargement `file://` fonctionne déjà
  /// nativement sans cette restriction (voir plutôt [allowFileAccess] sur
  /// Android).
  final bool allowFileAccessFromFileURLs;

  /// Version plus permissive de [allowFileAccessFromFileURLs] : autorise en
  /// plus une page `file://` à faire des requêtes vers *n'importe quelle*
  /// origine (y compris `http://`/`https://`), pas seulement d'autres
  /// fichiers locaux. **iOS et macOS** (clé privée `WKWebView`
  /// `allowUniversalAccessFromFileURLs`). Faux par défaut. À n'activer que
  /// si vous chargez du contenu local de confiance (ex. un bundle HTML/JS
  /// embarqué dans l'app) qui a besoin d'appeler votre API distante — ce
  /// réglage désactive une protection de sécurité importante, ne l'activez
  /// jamais pour du contenu distant/non fiable. Implique
  /// [allowFileAccessFromFileURLs] (activé automatiquement côté natif si ce
  /// dernier est à `true`). Sans effet sur Android/Windows/Linux.
  final bool allowUniversalAccessFromFileURLs;

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
        'selectionHandleColor': selectionHandleColor?.toARGB32(),
        'androidPlatformViewType': androidPlatformViewType.name,
        'allowsBackForwardNavigationGestures': allowsBackForwardNavigationGestures,
        'allowsLinkPreview': allowsLinkPreview,
        'disabledDefaultContextMenuItems': disabledDefaultContextMenuItems.map((e) => e.name).toList(),
        'disableLinkHoverPreview': disableLinkHoverPreview,
        'disablePrinting': disablePrinting,
        'initialUserScripts': initialUserScripts.map((e) => e.toMap()).toList(),
        'disableKeyboardResize': disableKeyboardResize,
        'windowsScrollbarTheme': windowsScrollbarTheme.toMap(),
        'cacheEnabled': cacheEnabled,
        'incognito': incognito,
        'applicationNameForUserAgent': applicationNameForUserAgent,
        'textZoom': textZoom,
        'minimumFontSize': minimumFontSize,
        'allowsInlineMediaPlayback': allowsInlineMediaPlayback,
        'allowsPictureInPicture': allowsPictureInPicture,
        'javaScriptCanOpenWindowsAutomatically': javaScriptCanOpenWindowsAutomatically,
        'geolocationEnabled': geolocationEnabled,
        'thirdPartyCookiesEnabled': thirdPartyCookiesEnabled,
        'forceDarkMode': forceDarkMode,
        'overScrollMode': overScrollMode.name,
        'webviewContentMode': webviewContentMode.name,
        'bounces': bounces,
        'initialScale': initialScale,
        'hideNativeScrollbars': hideNativeScrollbars,
        'safeBrowsingEnabled': safeBrowsingEnabled,
        'allowMixedContent': allowMixedContent,
        'allowFileAccessFromFileURLs': allowFileAccessFromFileURLs,
        'allowUniversalAccessFromFileURLs': allowUniversalAccessFromFileURLs,
      };
}
