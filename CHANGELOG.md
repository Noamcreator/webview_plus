## 0.9.0

### Linux : nouveau mode « intégré » (remplace la texture par défaut)
- Cause du `glGetError 501` et des plantages aléatoires : `FlPixelBufferTexture` fait un `glBindTexture` sur une texture créée dans un autre contexte GL (défaut du moteur Flutter récent, non corrigeable depuis un plugin). En plus, chaque frame passait par capture X11 -> copie -> envoi complet au GPU, d'où la lenteur.
- Mode intégré : le `WebKitWebView` est un vrai widget GTK placé SOUS la vue Flutter (fond transparent) ; le widget Dart perce un trou (`BlendMode.clear`) et signale son rectangle (`setRect`). WebKit se dessine nativement (fluide, GPU), fonctionne sous Wayland, et les widgets Flutter (dialogs, barres, spinner, rideau de couleur) restent au-dessus.
- Nécessite le `my_application.cc` fourni (FlView dans un `GtkOverlay` au-dessus d'un `GtkFixed`). Sans lui : repli automatique sur le mode texture. Forçage du repli : `WEBVIEW_PLUS_LINUX_MODE=texture`.

### Nouveaux callbacks (`WebviewWidget`)
- `onLoadError(controller, Uri url, int code, String message)` : échec de chargement du document principal (aussi statut HTTP >= 400 sur Android/macOS). `onReceivedError` continue de fonctionner (même événement).
- `onContentLoading` : navigation validée, le document commence à recevoir son contenu (Android `doUpdateVisitedHistory`, macOS `didCommit`, Linux `COMMITTED`, Web).
- `onPageCommitVisible` : premier contenu prêt à être peint (Android natif ; macOS/Linux/Web : deux `requestAnimationFrame` après le démarrage du document).
- `onProgressChanged(controller, int 0..100)` : Android `WebChromeClient`, macOS `estimatedProgress`, Linux `estimated-load-progress`, Web synthétique (10 -> 100).
- `onLoadResource` fonctionne maintenant pour de bon : côté macOS le natif n'envoyait JAMAIS rien à Dart (simple commentaire dans le code). Implémenté sur Android (`shouldInterceptRequest`, `file://`), macOS et Linux (schéma `app-assets://`). Seules les extensions de `WebviewSettings.interceptedResourceExtensions` (images par défaut) sont transmises, et seulement si le callback est fourni. Windows : contrat Dart identique, natif à implémenter ; Web : impossible avec une iframe.

### Couleur de départ (fini le flash blanc / noir)
- Android n'appliquait pas `initialBackgroundColor` : la Webview restait blanche jusqu'au premier rendu. Appliqué (`setBackgroundColor`), ainsi que macOS `underPageBackgroundColor`.
- Nouveau `WebviewSettings.coverUntilFirstPaint` (vrai par défaut) : un rideau Flutter de la couleur `initialBackgroundColor` recouvre la vue native jusqu'au premier rendu, puis fond en 150 ms.

### macOS
- Nouveau `WebviewSettings.disableRightClickSelection` : le clic droit (et Ctrl+clic) ne sélectionne plus le mot sous le curseur.

### Démarrage Android
- Les événements natifs sont mis en file d'attente jusqu'à ce que Dart soit prêt (`ready`, envoyé après `onWebViewCreated`) : plus de `onLoadStart`/`onDOMContentLoaded` perdus ni d'appel `callHandler` avant `addJavaScriptHandler`.
- Le pont `window.webview_plus` est injecté au démarrage du document (`addDocumentStartJavaScript`) au lieu d'un `evaluateJavascript` tardif.
- `WebviewPlusPreloader.preloadDocument` : charge la page à l'avance dans une Webview détachée, adoptée instantanément par un `WebviewWidget` de mêmes paramètres (événements rejoués), rechargée automatiquement ensuite.
- Les Webviews du pool utilisent un `MutableContextWrapper` rebranché sur l'Activité (thème de sélection, dialogues, IME).

### Correctif important
- `WebviewBaseController` utilisait un champ `static` partagé : avec plusieurs Webviews vivantes, les callbacks d'une ancienne vue recevaient le contrôleur de la DERNIÈRE vue créée. Un contrôleur par vue désormais.

## 0.8.8

- Linux : correction d'un use-after-free du buffer de pixels (thread raster Flutter vs redimensionnement) pouvant faire planter l'app au lancement d'une page WebView.
- Linux : les erreurs X11 pendant la capture (BadMatch/BadWindow) sont piégées au lieu de tuer le processus.
- Linux : plus de pointeurs pendants après `dispose` (callbacks `callHandler`, signaux WebKit, handler de canal).
- Linux : capture à la demande (signal `draw`) au lieu de 60 fps permanents -> CPU ~0 à l'arrêt, rendu plus fluide.
- Linux : prise en charge de `allowFileAccessFromFileURLs`, `allowUniversalAccessFromFileURLs`, `mediaPlaybackRequiresUserGesture`, `domStorageEnabled`, `initialBackgroundColor`; logs console en stdout si `isInspectable`.
- Linux : `WEBKIT_DISABLE_DMABUF_RENDERER=1` et `WEBKIT_DISABLE_COMPOSITING_MODE=1` par défaut (sans écraser l'environnement existant).
- Linux : fuite d'un `FlMethodResponse` par appel corrigée ; CMake crée `PkgConfig::GTK` si absent.
- Dart : si le widget est démonté pendant `create`, la vue native est maintenant détruite.
- Web : réécriture de l'implémentation iframe. `initialFile`, `initialCss`, `initialSettings` (user scripts, couleurs de sélection, menu contextuel, fond), `onLoadStart`, `onLoadStop`, `onDOMContentLoaded` et `onFontsIsLoaded` sont désormais pris en charge.
- Web : le pont `window.webview_plus.callHandler` / `WebviewPlusChannel` est injecté au DÉMARRAGE du document (pages same-origin), plus seulement au `load`.
- Web : les URLs d'assets Flutter sont résolues via `ui_web.assetManager` (l'ancienne résolution donnait un 404 pour `assets/xxx`, servi en réalité sous `assets/assets/xxx`).
- Web : les messages sont filtrés par iframe (plusieurs Webviews ne se reçoivent plus mutuellement), l'écouteur `message` est libéré au dispose, `onWebViewCreated` est appelé avant le premier chargement.

## 0.8.7

- On linux the crash on start is fix.

## 0.8.6

* Fixed a deprecation warning by replacing `configuration.preferences.javaScriptEnabled` with `configuration.defaultWebpagePreferences.allowsContentJavaScript` for macOS 11.0 and later.

## 0.8.5

* **Added SVG Support:** Registered the `"image/svg+xml"` MIME type for `.svg` extensions. This prevents `WKWebView` from treating SVGs as raw binary streams (`application/octet-stream`), allowing them to render correctly inside HTML `<img>` elements.
* **Expanded Media & Web Formats:** Added comprehensive mapping for web apps and publications:
  * **Images:** `.webp`, `.ico`, `.bmp`, `.gif`, `.tiff`
  * **Fonts:** `.woff`, `.woff2`, `.ttf`, `.otf`
  * **Web/Data:** `.html`, `.json`, `.xml`, `.txt`, `.mjs`
  * **Audio/Video:** `.mp4`, `.webm`, `.mp3`, `.wav`, `.aac`, `.ogg`
  * **Documents:** `.pdf`, `.zip`

## 0.8.4

* **Custom URL Scheme (`app-assets://`)**: Introduced a custom URL scheme handler (`WKURLSchemeHandler`) to safely intercept local asset requests without conflicting with WebKit's security policies.
* **MIME Type Resolver**: Added a helper function (`getMimeType`) in the Swift handler to map file extensions (such as `.jpg`, `.png`, `.css`, `.js`) to their respective MIME types, ensuring the WebView correctly renders the intercepted resources.

## [Changed]
* **Native URL Scheme Registration**: Replaced the private, non-functional `_setURLSchemeHandler:forURLScheme:` method (which attempted to override `http`/`https`) with the official `setURLSchemeHandler(_:forURLScheme:)` method targeting the new `app-assets` scheme.
* **Dart HTML Resource Paths**: Updated the local image path conversion in the Flutter layer to replace the restricted `file://` protocol with the new custom `app-assets://` prefix.
* **Resource Loading Logic**: Rewrote the Swift resource handler to capture `app-assets://` URIs, dynamically convert them back to local file system paths (`file://`), read the data securely from the disk, and stream it back to the `WKWebView`.

## [Fixed]
* **`onLoadResource` Silent Failures**: Fixed a limitation where `WKWebView` silently ignored or blocked custom scheme handlers bound to standard web protocols (`http`, `https`, `file`), preventing resource interception events from triggering.

## 0.8.3

* Remove the "Picture in picture" in macOS to remove the build failed.

## 0.8.2

### Fixed
* **Linux: fixed a critical bug where opening a `WebviewWidget` could corrupt the Flutter engine's OpenGL rendering context**, breaking rendering across the *entire* app — not just the webview. Depending on timing, this ranged from a black band covering all Flutter widgets to a complete engine failure (`FlutterEngineRunTask` repeatedly returning `kInvalidArguments`, nothing rendering at all). Root cause: the plugin reparented the Flutter `FlView` into a new `GtkOverlay` *after* the engine had already bound its GL resource context to the view's original `GdkWindow`; tearing that window down and rebuilding it mid-session invalidated the context.

### Changed — action required on Linux
* **The `GtkOverlay` used to host native Webviews must now be created up front in `linux/my_application.cc`, before the engine starts rendering**, instead of being assembled at runtime by the plugin. This is what actually fixes the bug above. See the new **[Setup on Linux](README.md#setup-on-linux)** section for the exact snippet to add.
* The plugin's previous runtime fallback (reparenting the `FlView` on first Webview creation) is kept only as a safety net for projects that haven't applied this change yet, and is no longer the recommended path — it remains susceptible to the rendering bug described above.

## 0.8.1

### Fixed
* **Android: fixed a major scroll/rendering performance regression** introduced by the transparent-background fix in a previous release. When `transparentBackground: true` was set, the WebView could get stuck permanently in `LAYER_TYPE_SOFTWARE` (CPU rendering) instead of switching back to `LAYER_TYPE_HARDWARE` after the page finished loading, causing persistent jank during scrolling and animations. The hardware layer switch is now only delayed by a couple of frames after `onPageFinished` (enough to avoid the black-flash artifact on the first transparent composite), then restored as before.
* **Android: initial layer type is no longer forced to `LAYER_TYPE_SOFTWARE` at WebView creation** for opaque backgrounds, avoiding an unnecessary software-rendered frame before the first hardware composite.
* **Android: fixed unnecessary `WindowInsets` rebuild/redispatch on every touch interaction** when `disableKeyboardResize: true` is set. The listener now only rebuilds and redispatches insets when the IME inset is actually non-zero, instead of doing so unconditionally — this was causing the engine to resend viewport metrics on every tap, adding visible input latency between touch and render.

## 0.8.0

* **Announcement**: **Linux and Web platforms are now fully functional and supported!** 🚀
* **Feature**: `injectJsData` / `injectCssData` (injecting raw JS/CSS directly into the active page) are now functional across **all 7 platforms** (Android, iOS, macOS, Windows, Linux, Web). Previously, only file/asset-based injections (`injectJavascriptFileFromUrl`, `injectCSSFileFromUrl`, etc.) worked natively.
* **Feature**: Added `WebviewWidget.initialCss` to automatically reinject raw CSS on every page load (initial or following navigation) across all 7 platforms.
* **Feature**: Added `WebviewSettings.allowFileAccessFromFileURLs` and `WebviewSettings.allowUniversalAccessFromFileURLs` (iOS/macOS). Enable these if a page loaded from the local disk (`loadFile`/`loadFlutterAsset`) fails to fetch other local files via `fetch`/XHR—the most common cause of local files "not opening" on these two platforms.
* **Feature**: Added `WebviewCacheManager` (`clearCache()`, `clearCookies()`, `clearAllData()`) to clear HTTP cache, cookies, or all web data across the application's Webviews, independent of any active on-screen instance. Available across all 7 platforms.
* **Feature**: Added `WebviewPlusController.setWebContentsDebuggingEnabled()` to enable/disable remote inspection (Chrome DevTools/Safari Web Inspector) globally for all current and future Webviews in the app, unlike `WebviewSettings.isInspectable` which applies to a single instance.
* **Feature**: Extended custom scrollbar coloring (previously Windows-only, see `DesktopScrollbarThemeMode`) to **macOS and Linux**, as both expose the same `::-webkit-scrollbar*` CSS pseudo-elements as WebView2/Chromium.
* **Fix (macOS)**: `disableContextMenu` and `disableLongPressContextMenuOnLinks` previously blocked the context menu by clearing it after creation (`willOpenMenu`), which could sometimes leave an empty menu visible (specifically the word selection menu). The menu is now prevented from building ahead of time (`menu(for:)`), fixing the residual empty menu when right-clicking selected text.
* **Fix (macOS)**: Fixed a bug where `selectionTextColor` was being read from the wrong settings key (`selectionHandleColor`, which is Android-specific) and had no actual effect.
* **Improvement**: Significantly expanded `WebviewSettings` coverage on macOS to match iOS/Android parity: `mediaPlaybackRequiresUserGesture`, `initialBackgroundColor`, `disablePrinting` (JS + Cmd+P shortcut), `allowsPictureInPicture`, `cacheEnabled`, `forceDarkMode` (via `NSAppearance`, forcing `prefers-color-scheme: dark`), and `hideNativeScrollbars` (via CSS injection, now shared with Linux).
* **Feature**: Added `WebviewInitialData` to `WebviewWidget` for advanced raw data and HTML loading with `mimeType`, `encoding`, `baseUrl`, and `androidHistoryUrl` across all platforms (Windows ignores `baseUrl` due to native WebView2 limitations).
* **Feature**: Added comprehensive Windows scrollbar theming support via `DesktopScrollbarThemeMode` (auto, light, dark, custom, and hidden modes). Supports runtime updates of track/thumb colors, width, and hover states.
* **Feature**: Significantly expanded `WebviewSettings` with a suite of new cross-platform controls:
  * `cacheEnabled` (All) — Toggle session and HTTP caching.
  * `incognito` (All) — Run webview in private/incognito profile.
  * `applicationNameForUserAgent` (All) — Easily append a custom app name to the default User Agent.
  * `textZoom` (Android) — Adjust text sizing percentages.
  * `minimumFontSize` (Android/iOS/macOS) — Enforce a minimum readable font size.
  * `allowsInlineMediaPlayback` (iOS/macOS) — Native control over inline video.
  * `allowsPictureInPicture` (iOS/macOS) — Allow PiP mode on supported native media.
  * `javaScriptCanOpenWindowsAutomatically` (All) — Prevent/allow window.open calls.
  * `geolocationEnabled` (Android) — Native hardware geolocation toggle.
  * `thirdPartyCookiesEnabled` (Android) — Manage cross-site cookie settings.
  * `forceDarkMode` (Android) — Explicitly force dark mode mapping.
  * `overScrollMode` (Android) — Control native overscroll glow behavior.
  * `bounces` (iOS/macOS) — Control scroll bouncing physics.
  * `initialScale` (Android) — Set default viewport zoom scale.
  * `hideNativeScrollbars` (All) — Easily hide default scrollbars.
  * `safeBrowsingEnabled` (Android) — Toggle Google Safe Browsing checks.
  * `allowMixedContent` (Android) — Allow loading HTTP content inside HTTPS pages.
* **Change**: Changed `getHtml` to return a formatted HTML string (with proper indentation and newlines) on Windows.
* **Feature**: Added `onFontsIsLoaded` callback on Windows, Android, and macOS.
* **Dependency**: Updated to use the new `androidx.webkit:webkit:1.16.0` dependency on Android.

## 0.7.1

* Fixed Windows WebView bridge initialization: Isolated user scripts in try-catch blocks and optimized execution order to prevent custom scripts from blocking addJavaScriptHandler.

## 0.7.0

* Add `selectionTextColor` setting on Android and iOS.
* Add `selectionHandleColor` setting on Android.
* Add `disableKeyboardResize` setting on Android and iOS to prevent WebView from resizing when the virtual keyboard appears.
* Add `initialUserScripts` setting to inject JavaScript code into pages on Android, iOS, and macOS.
* Add `disabledDefaultContextMenuItems` setting to individually disable default native context menu items on Android and iOS.


## 0.6.3

* Add `onDOMContentLoaded` callback on IOS, MacOS and Linux.
* Add mouse cursor change (onCursorChanged) support on Windows (the diagonal resize cursors).
* Android and Windows bug: A white screen appears while the WebView is loading, even when transparency is enabled.
* Add `initialBackgroundColor` setting across all platforms to eliminate the white screen/flash of unpainted content during initialization and loading.
* Replace `useHybridComposition` with `AndroidPlatformViewType` enum, featuring automatic fallback to Hybrid Composition (`initExpensiveAndroidView`) on devices below Android SDK 23.

## 0.6.2

* Fixed the `onDOMContentLoaded` callback not being called on all platforms.

## 0.6.1

* Fixed a critical Android WebView crash by allowing nullable arguments (String?) on JavaScript-to-Kotlin bridges to gracefully handle empty page lifecycles.

## 0.6.0

* Bug in the evaluateJavaScript function on macOS and iOS causing a crash.
* Remove the PrivacyInfo file in macOS for remove the warning.

## 0.5.0

* Android: switch to `initSurfaceAndroidView` (Texture Layer Hybrid Composition) by default on API 23+, replacing the old choice between Virtual Display (janky scroll) and Hybrid Composition (janky Flutter animations around the webview). Native scroll and Flutter transitions/dialogs are now both smooth. Falls back automatically to the previous behavior on API < 23.
* Android: smoother native scrolling — disabled the overscroll glow effect (`overScrollMode = OVER_SCROLL_NEVER`) and enabled nested scrolling (`isNestedScrollingEnabled`).
* Android: faster first paint — enabled `useWideViewPort` and `loadWithOverviewMode` to avoid a desktop-then-mobile relayout on pages without a proper viewport meta tag.
* Android: explicit `cacheMode = LOAD_DEFAULT` to make sure standard HTTP caching is honored, enabling faster subsequent loads.
* Added `WebviewPlusPreloader`, a new API to speed up webview loading:
  * `WebviewPlusPreloader.warmUp({int count = 1})` pre-creates WebView engine instances in the background, moving the one-time Chromium engine initialization cost off the critical path of the first visible webview.
  * `WebviewPlusPreloader.preloadUrl(String url)` loads a URL in an invisible, disposable webview ahead of time to warm the shared HTTP cache, speeding up the real webview's load of the same URL later.
  * Both are no-ops on non-Android platforms.
* Rename the `evaluateJavaScript` setting in controller to `evaluateJavascript` to match with the other webview in flutter.

## 0.4.0

Windows changes:
* Navigation: Fixed an issue where the canGoBack and canGoForward state properties were not functioning.
* Focus: Fixed the WebView hijacking focus and causing the main Flutter window to lose active focus when clicked.
* Cursor: Fixed the mouse cursor failing to adapt (e.g., changing to a text-selection cursor) when hovering over web content.
* Context Menu: Fixed the right-click context menu appearing misaligned/offset when running the application in windowed mode.

Android changes:
* Use initSurfaceAndroidView or initHybridAndroidView when is available (API 23+).
* Add support for Android 12's new "Hybrid Composition++" mode (requires API 34+).

## 0.3.0

* Add WebviewEnvironment for Windows (userDataFolder)

## 0.2.0

* Update onLoadStart / onLoadStop / onReceivedError / onNavigationRequest and remove shouldOverrideUrlLoading (now use onNavigationRequest only)
* Add onDOMContentLoaded / onWindowFocus / onWindowBlur

## 0.1.0

* Initial Commit