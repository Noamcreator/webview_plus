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
  