## 0.9.5
Linux: secondary windows, text input, DevTools, notes bug
- **Secondary windows: the runner must create every window through `FlApplication::create_window`.** In 0.9.4 a secondary window (Flutter multi-window API) had no `GtkOverlay`, so the plugin fell back to texture mode, which floods the console with `glGetError 501` (an engine bug in `FlPixelBufferTexture`) and can crash the app on first open. The plugin deliberately does NOT re-parent an existing `FlView` at runtime: that is what corrupted the engine's OpenGL context in 0.8.2. Instead, `example/linux/runner/my_application.cc` (+ `.h`) now derives from `FlApplication` and builds the `GtkWindow` + `GtkOverlay` + transparent `FlView` structure inside `create_window`, before the view is realized. The engine calls it for the main window AND for every secondary window, so both get the native, smooth embedded mode. Requires a Flutter SDK that ships `fl_application.h` (current stable/beta).
- Typing text in a page was impossible since 0.9.4: the webview was made non-focusable to protect the Flutter keyboard, and the synthesized key events never reached WebKit's input method. Now, when an editable element of the page gets focus (`input`, `textarea`, `contenteditable`, detected by an injected script that posts `WebviewPlusEditable`), the webview receives the REAL GTK keyboard focus (IME, dead keys, AltGr...). The focus goes back to the `FlView` as soon as the field loses focus, the page is covered by another route, or the user clicks anywhere else in Flutter (new `blurFocus` message, driven by a global pointer route on the Dart side). Flutter text fields keep working as in 0.9.4.
- DevTools window was displayed but impossible to use: the inspector opened "attached" inside the webview, underneath the `FlView`, so no real mouse/keyboard event could reach it. It is now always detached (its own window). F12 / Ctrl+Shift+I also work when the webview owns the keyboard focus.
- `evaluateJavascript` threw `PlatformException(javascript_error, Unsupported result type)` when the script returned a value that cannot be serialized (DOM node, Promise, function...), e.g. `updateAllNotesUI(...)` after writing a note. The script has run anyway, so the result is now `null`, like on Android/iOS.

## 0.9.4
Linux: secondary windows, page stacking, keyboard, DevTools, context menu
- Secondary window (Flutter multi-window): the Webview was always attached to the PRIMARY `FlView`, so it was invisible in the secondary window. Dart now sends `View.of(context).viewId` (`flutterViewId`) and the native side finds the right `FlView` (`fl_view_get_id`, resolved with `dlsym`: compatible with older engines). A `FlView` that is not an overlay child (secondary window created by the engine) uses texture mode; an unknown view no longer falls back to the main window.
- Stacked Webviews: in embedded mode, a page covered by another route kept its native Webview displayed, and it showed through the hole of the page on top. The Webview is now hidden when its widget is no longer on screen (`TickerMode` is disabled by Flutter on covered routes, `setVisible` message), and when shown again it is raised above the other Webviews (but below the `FlView`). It stays hidden until the first `setRect` (no more 1x1 flash).
- Flutter keyboard lost after clicking a Webview: WebKit took the GTK focus away from the `FlView`. The embedded Webview is no longer focusable on the GTK side (WebKit focus is still signaled with a synthetic focus-in) + a safety net that gives the focus back to the `FlView`.
- F12 / Ctrl+Shift+I open the WebKit inspector (`openDevTools` message). Requires `WebviewSettings(isInspectable: true)` or `WebviewPlusController.setWebContentsDebuggingEnabled()`.
- Native WebKit context menu restored in embedded mode (it only appeared at the wrong place in texture mode); it honors `disableContextMenu`, `disableLongPressContextMenuOnLinks` and `disablePrinting`. "Inspect Element" appears when DevTools are enabled. Custom `ContextMenuItem`s: still Android/iOS only.
- Fullscreen / maximize: in addition to the temporary hiding (0.9.3), resizing the `FlView` forces GTK to recompute the Webview size (anti "old size").

## 0.9.3
Linux (embedded mode): three fixes
- Resizing: the window could grow but no longer shrink. The `WebKitWebView` was a `GtkFixed` child with `set_size_request`, which imposed its size as the minimum size of the whole window. It is now a `GtkOverlay` child (below the `FlView`) positioned through the `get-child-position` signal; `GtkOverlay` ignores its overlay children in its minimum size. The existing `my_application.cc` (`FlView` overlay + `GtkFixed` main child) stays compatible; the main child can be any widget.
- Mouse wheel too fast: Flutter sends pixels (53 per notch) while GTK expects notches. Deltas are now divided by 53 before being sent to WebKit. Optional tuning: `WEBVIEW_PLUS_SCROLL_SPEED` environment variable (e.g. `0.7` slower, `1.5` faster).
- Fullscreen / maximize (double-click on the title bar): double rendering and flickering, because the Webview kept its old rectangle for 1-2 frames while Flutter had already punched the hole at the new size. The Webview is hidden during the state change (maximized/fullscreen/tiled) and shown again once `setRect` has settled (150 ms without change, 1 s max).
- `example/linux/runner/my_application.cc`: updated with the `GtkOverlay` + transparent background (the old example was the standard Flutter runner, i.e. texture mode).

## 0.9.2
- Android: events of a preloaded Webview are no longer replayed as soon as the Dart widget is created but only once the view has been laid out (width/height > 0). Otherwise an init script that freezes its layout on `window.innerWidth/innerHeight` (e.g. `initFromFlutter`) ran at 0x0: invisible page, only the rest of the screen was displayed.
- Android: a preloaded page is reloaded 1 s (instead of 1.5 s) after it has been adopted.

## 0.9.1

- New `controller.requestFocus()` (all platforms): gives the keyboard focus to the Webview, e.g. from a `requestWebViewFocus` JS handler. Android `requestFocus()`, macOS first responder, Linux/Windows Flutter focus of the widget (+ WebKit focus-in on Linux), Web `iframe.focus()`.

## 0.9.0
Linux: new "embedded" mode (replaces the texture by default)
- Cause of `glGetError 501` and random crashes: `FlPixelBufferTexture` does a `glBindTexture` on a texture created in another GL context (a defect of the recent Flutter engine, not fixable from a plugin). In addition, every frame went through X11 capture -> copy -> full upload to the GPU, hence the slowness.
- Embedded mode: the `WebKitWebView` is a real GTK widget placed BELOW the Flutter view (transparent background); the Dart widget punches a hole (`BlendMode.clear`) and reports its rectangle (`setRect`). WebKit draws natively (smooth, GPU), it works on Wayland, and Flutter widgets (dialogs, bars, spinner, color curtain) stay on top.
- Requires the provided `my_application.cc` (`FlView` in a `GtkOverlay` above a `GtkFixed`). Without it: automatic fallback to texture mode. Force the fallback with `WEBVIEW_PLUS_LINUX_MODE=texture`.

## 0.8.9

New callbacks (`WebviewWidget`)
- `onLoadError(controller, Uri url, int code, String message)`: failure to load the main document (also HTTP status >= 400 on Android/macOS). `onReceivedError` keeps working (same event).
- `onContentLoading`: navigation committed, the document starts receiving its content (Android `doUpdateVisitedHistory`, macOS `didCommit`, Linux `COMMITTED`, Web).
- `onPageCommitVisible`: first content ready to be painted (native on Android; macOS/Linux/Web: two `requestAnimationFrame` after the document starts).
- `onProgressChanged(controller, int 0..100)`: Android `WebChromeClient`, macOS `estimatedProgress`, Linux `estimated-load-progress`, synthetic on Web (10 -> 100).
- `onLoadResource` now really works: on macOS the native side NEVER sent anything to Dart (it was just a comment in the code). Implemented on Android (`shouldInterceptRequest`, `file://`), macOS and Linux (`app-assets://` scheme). Only the extensions listed in `WebviewSettings.interceptedResourceExtensions` (images by default) are forwarded, and only if the callback is provided. Windows: identical Dart contract, native side still to implement; Web: impossible with an iframe.

Start color (no more white / black flash)
- Android did not apply `initialBackgroundColor`: the Webview stayed white until the first render. Now applied (`setBackgroundColor`), as well as macOS `underPageBackgroundColor`.
- New `WebviewSettings.coverUntilFirstPaint` (true by default): a Flutter curtain of the `initialBackgroundColor` color covers the native view until the first render, then fades out in 150 ms.

macOS
- New `WebviewSettings.disableRightClickSelection`: right click (and Ctrl+click) no longer selects the word under the cursor.

Android startup
- Native events are queued until Dart is ready (`ready`, sent after `onWebViewCreated`): no more lost `onLoadStart`/`onDOMContentLoaded` and no `callHandler` call before `addJavaScriptHandler`.
- The `window.webview_plus` bridge is injected at document start (`addDocumentStartJavaScript`) instead of a late `evaluateJavascript`.
- `WebviewPlusPreloader.preloadDocument`: loads the page in advance in a detached Webview, instantly adopted by a `WebviewWidget` with the same parameters (events replayed), then reloaded automatically.
- Pool Webviews use a `MutableContextWrapper` re-attached to the Activity (selection theme, dialogs, IME).

Important fix
- `WebviewBaseController` used a shared `static` field: with several live Webviews, the callbacks of an old view received the controller of the LAST created view. There is now one controller per view.

## 0.8.8

- Linux: fixed a use-after-free of the pixel buffer (Flutter raster thread vs resize) that could crash the app when launching a WebView page.
- Linux: X11 errors during capture (BadMatch/BadWindow) are now trapped instead of killing the process.
- Linux: no more dangling pointers after `dispose` (`callHandler` callbacks, WebKit signals, channel handler).
- Linux: on-demand capture (`draw` signal) instead of a permanent 60 fps -> CPU ~0 when idle, smoother rendering.
- Linux: support for `allowFileAccessFromFileURLs`, `allowUniversalAccessFromFileURLs`, `mediaPlaybackRequiresUserGesture`, `domStorageEnabled`, `initialBackgroundColor`; console logs on stdout if `isInspectable`.
- Linux: `WEBKIT_DISABLE_DMABUF_RENDERER=1` and `WEBKIT_DISABLE_COMPOSITING_MODE=1` by default (without overwriting the existing environment).
- Linux: fixed a leaked `FlMethodResponse` per call; CMake creates `PkgConfig::GTK` if missing.
- Dart: if the widget is unmounted during `create`, the native view is now destroyed.
- Web: rewrite of the iframe implementation. `initialFile`, `initialCss`, `initialSettings` (user scripts, selection colors, context menu, background), `onLoadStart`, `onLoadStop`, `onDOMContentLoaded` and `onFontsIsLoaded` are now supported.
- Web: the `window.webview_plus.callHandler` / `WebviewPlusChannel` bridge is injected at document START (same-origin pages), not only on `load`.
- Web: Flutter asset URLs are resolved through `ui_web.assetManager` (the old resolution gave a 404 for `assets/xxx`, which is actually served under `assets/assets/xxx`).
- Web: messages are filtered per iframe (several Webviews no longer receive each other's messages), the `message` listener is released on dispose, `onWebViewCreated` is called before the first load.

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

[Changed]
* **Native URL Scheme Registration**: Replaced the private, non-functional `_setURLSchemeHandler:forURLScheme:` method (which attempted to override `http`/`https`) with the official `setURLSchemeHandler(_:forURLScheme:)` method targeting the new `app-assets` scheme.
* **Dart HTML Resource Paths**: Updated the local image path conversion in the Flutter layer to replace the restricted `file://` protocol with the new custom `app-assets://` prefix.
* **Resource Loading Logic**: Rewrote the Swift resource handler to capture `app-assets://` URIs, dynamically convert them back to local file system paths (`file://`), read the data securely from the disk, and stream it back to the `WKWebView`.

[Fixed]
* **`onLoadResource` Silent Failures**: Fixed a limitation where `WKWebView` silently ignored or blocked custom scheme handlers bound to standard web protocols (`http`, `https`, `file`), preventing resource interception events from triggering.

## 0.8.3

* Remove the "Picture in picture" in macOS to remove the build failed.

## 0.8.2

Fixed
* **Linux: fixed a critical bug where opening a `WebviewWidget` could corrupt the Flutter engine's OpenGL rendering context**, breaking rendering across the *entire* app — not just the webview. Depending on timing, this ranged from a black band covering all Flutter widgets to a complete engine failure (`FlutterEngineRunTask` repeatedly returning `kInvalidArguments`, nothing rendering at all). Root cause: the plugin reparented the Flutter `FlView` into a new `GtkOverlay` *after* the engine had already bound its GL resource context to the view's original `GdkWindow`; tearing that window down and rebuilding it mid-session invalidated the context.

Changed — action required on Linux
* **The `GtkOverlay` used to host native Webviews must now be created up front in `linux/my_application.cc`, before the engine starts rendering**, instead of being assembled at runtime by the plugin. This is what actually fixes the bug above. See the new **[Setup on Linux](README.md#setup-on-linux)** section for the exact snippet to add.
* The plugin's previous runtime fallback (reparenting the `FlView` on first Webview creation) is kept only as a safety net for projects that haven't applied this change yet, and is no longer the recommended path — it remains susceptible to the rendering bug described above.

## 0.8.1

Fixed
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