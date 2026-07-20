# webview_plus

A high-performance, cross-platform Flutter plugin that **directly encapsulates** native Webview components on all supported platforms. 

Unlike other webview implementations that introduce complex virtualization layers, `webview_plus` embeds the underlying platform's native web view directly for maximum speed, memory efficiency, and standard compliance.

---

## 🚀 Platform Support Matrix

| Platform | Encapsulated Native Component | Backend Layer / Architecture |
| :--- | :--- | :--- |
| **Android** | `android.webkit.Webview` | Native `PlatformView`, using **Texture Layer Hybrid Composition** by default (API 23+) — native-speed scrolling *and* smooth Flutter animations around it |
| **iOS** | `WKWebview` (WebKit) | Native `UiKitView` (Full native composition) |
| **macOS** | `WKWebview` (WebKit) | Native `AppKitView` (Full native composition) |
| **Windows** | `Webview2` (Edge Chromium) | Win32 Composition over Flutter Direct3D Texture |
| **Linux** | `WebKitWebView` (WebKitGTK) | Direct `GtkWidget` window overlay anchoring |
| **Web** | Native DOM `<iframe>` | Standard HTML5 Element Embedding |

---

## ✨ Features

- **True Native Embedding:** Zero unnecessary wrappers. Uses `WKWebview` on Apple platforms, Chromium-based `Webview2` on Windows, and `WebKitGTK` on Linux.
- **Bi-directional JavaScript Bridge:** 
  - Execute Dart to JS via `evaluateJavascript` with **automatic type unboxing** (returns real Dart types like `int`, `Map`, `List` instead of raw strings).
  - Handle JS to Dart messages using either basic string streaming or full-featured promises via `window.webview_plus.callHandler`.
- **Raw JS/CSS Injection Everywhere:** `injectJsData`/`injectCssData` (one-off, via the controller) and `WebviewWidget.initialCss` (re-applied on every page load) are fully functional on **all 5 platforms**.
- **Custom Native Context Menus:** Fully customize text selection and long-press contextual menus on Android and iOS using native platform APIs (`ActionMode` & `UIContextMenuConfiguration`); `disableContextMenu`/`disableLongPressContextMenuOnLinks` additionally work natively on macOS (right-click).
- **Comprehensive Lifecycle Callbacks:** Track page loading starts, stops, navigation interception, and handle platform-specific web view errors.
- **Advanced Asset & File System Access:** Load URLs, bundle assets, or absolute file paths from the local device storage. `allowFileAccessFromFileURLs`/`allowUniversalAccessFromFileURLs` unlock local-file-to-local-file access on iOS/macOS.
- **Scrollbar Theming (Windows/macOS/Linux):** Custom track/thumb colors, width, and light/dark/auto/hidden modes via `windowsScrollbarTheme`, applied through native composition on Windows and injected `::-webkit-scrollbar` CSS on macOS/Linux.
- **Cache & Debug Utilities:** `WebviewCacheManager` clears HTTP cache/cookies/all web data across every Webview in the app; `WebviewPlusController.setWebContentsDebuggingEnabled()` globally toggles remote DevTools/Web Inspector access.
- **Android Rendering Performance:** Defaults to Texture Layer Hybrid Composition (`initSurfaceAndroidView`) on API 23+, giving native-speed scrolling without the janky Flutter animations/transitions that plague classic Hybrid Composition. Automatically falls back to legacy modes on older devices.
- **Android Preloading API:** `WebviewPlusPreloader` lets you warm up the WebView engine and/or prefetch a URL into the shared HTTP cache *before* the user opens a webview screen, for a near-instant first paint. See [Preloading & Faster First Load](#-preloading--faster-first-load-android) below.
- **Automatic Script Injection:** Declare a list of `UserScript`s in `initialSettings.initialUserScripts` to have them injected automatically into every page the webview loads (Android/iOS/macOS).
- **Keyboard-Aware Layout Control:** `disableKeyboardResize` stops the webview from shrinking when the on-screen keyboard appears, using native IME insets rather than a JS `window.innerHeight` workaround (Android/iOS).

---

## 🛠️ Quick Start

```dart
import 'package:flutter/material.dart';
import 'package:webview_plus/webview_plus.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Webview Plus Example')),
        body: WebviewWidget(
          initialAsset: 'assets/index.html',
          onWebViewCreated: (controller) {
            print("Webview has been successfully instantiated.");
          },
          onMessageReceived: (message) {
            print("Received simple message from JS: $message");
          },
          onNavigationRequest: (url) {
            // Block specific navigation paths
            if (url.contains('blocked.com')) {
              print("Navigation to $url blocked!");
              return false; // Prevent navigation
            }
            return true; // Allow navigation
          },
        ),
      ),
    );
  }
}
```

---

## 📖 Deep Dive & Advanced Usage

### 1. Bi-directional JavaScript Interaction

#### Dart to JavaScript (with Native Types)
Forget manual JSON parsing. When evaluating JavaScript, the native bridge deserializes data into native Dart objects directly.

```dart
// Evaluate arithmetic or complex data structures
final dynamic result = await controller.evaluateJavascript('1 + 1'); 
print(result); // Outputs: 2 (as an int, not a String "2"!)

final Map<String, dynamic> user = await controller.evaluateJavascript('''
  (function() {
    return { name: "Noam", roles: ["admin", "developer"] };
  })()
''');
```

#### JavaScript to Dart Handlers (Promises & Callbacks)
Register namespaced handlers in Dart that return values or asynchronous futures directly back to JavaScript as native JS Promises.

**Dart Implementation:**
```dart
controller.addJavaScriptHandler(
  handlerName: 'calculateTax',
  callback: (args) async {
    // args maps exactly to parameters passed from JS
    double subtotal = args[0];
    double rate = args[1];
    return subtotal * rate; // Returned directly to JavaScript
  },
);
```

**JavaScript Call:**
```javascript
// window.webview_plus is automatically injected into the page context
window.webview_plus.callHandler('calculateTax', 100.0, 0.20)
  .then(function(taxResult) {
    console.log("Tax computed by Dart: " + taxResult); // 20
  })
  .catch(function(error) {
    console.error("Error from Dart execution: ", error);
  });
```

---

### 2. Custom Native Context Menus (Android & iOS)

You can strip down or add custom buttons to the native text selection action bar. This is handled deep within native platform architectures (`ActionMode` on Android and `UIContextMenuConfiguration` on iOS).

```dart
WebviewWidget(
  initialUrl: 'https://flutter.dev',
  contextMenuItems: [
    ContextMenuItem(
      id: 'search_lookup',
      name: 'Custom Lookup',
      action: (selectedText) {
        print("User highlighted and clicked lookup for: $selectedText");
      },
    ),
  ],
  initialSettings: const WebviewSettings(
    // Disable standard copy/cut/paste items if necessary
    disabledDefaultContextMenuItems: {
      DefaultContextMenuItem.cut,
      DefaultContextMenuItem.share, // If defined
    },
  ),
)
```

*Note: Context menu customizations are silently ignored on desktop platforms (Windows, macOS, Linux) where traditional right-click drop-down menus operate without touch-selection bars.*

---

### 3. Detailed Controller API Reference

The `WebviewPlusController` exposes full programmatic control over the browser session:

| Method | Description |
| :--- | :--- |
| `loadUrl(String url)` | Navigates to a remote or local URL (`http://`, `https://`, `file://`). |
| `loadFlutterAsset(String assetPath)` | Loads an HTML file bundled inside your Flutter application asset directory. |
| `loadFile(String filePath)` | Absolute filesystem lookup. Loads local files on the device disk. |
| `loadHtmlString(String html, {String? baseUrl})` | Loads a raw HTML string into the webview component directly. |
| `loadData(...)` | Advanced alternative to `loadHtmlString` supporting explicit custom `mimeType` (e.g. `image/svg+xml`) and `encoding`. |
| `evaluateJavascript(String code)` | Runs arbitrary JS in the document scope and retrieves automatically unboxed Dart objects. |
| `getHtml()` | Helper that queries and returns `document.documentElement.outerHTML`. |
| `injectJsData(String jsData)` | Injects raw JavaScript code directly into the live page (executed immediately, once). **All 5 platforms.** |
| `injectCssData(String cssData)` | Injects a raw CSS string directly into the live page via an on-the-fly `<style>` tag. **All 5 platforms.** |
| `injectJavascriptFileFromUrl / Asset` | Injects an external or asset-based `<script>` file straight into the live DOM tree. |
| `injectCSSFileFromUrl / Asset` | Appends remote stylesheets or asset-based CSS rules into the live DOM layout. |
| `goBack() / goForward()` | Navigates backwards or forwards through the session browsing history stack. |
| `canGoBack() / canGoForward()` | Evaluates whether historical steps are available in either direction. |
| `reload()` | Triggers a fresh reload of the current active webpage structure. |

---

## ⚡ Preloading & Faster First Load (Android)

Android's `WebView` pays a one-time cost the first time it's ever instantiated in your app process — loading the Chromium engine, spinning up the sandboxed `:webview_service` process, etc. That cost is *per process*, not per instance, which means:

- Every webview **after** the first one in your app is already fast.
- The **first** webview the user ever opens takes the hit, right when they're waiting for it.

`WebviewPlusPreloader` gives you two independent, Android-only tools (silent no-ops on other platforms) to move that cost out of the user's way.

### Engine warm-up

Pre-builds blank `WebView` instances in the background so the first real `WebviewWidget` the user opens doesn't have to pay the engine init cost itself.

```dart
void main() {
  runApp(const MyApp());
  WidgetsBinding.instance.addPostFrameCallback((_) {
    WebviewPlusPreloader.warmUp(count: 1); // 1–5, call once after the first frame
  });
}
```

### URL preloading

Fetches a URL in the background using an invisible, disposable webview, filling the shared HTTP cache so the real webview that loads the same URL later gets it (partly or fully) from cache instead of the network.

```dart
// e.g. as soon as an article list is shown, warm the article the user
// is most likely to open next
WebviewPlusPreloader.preloadUrl('https://example.com/article/123');
```

| Method | Description |
| :--- | :--- |
| `warmUp({int count = 1})` | Pre-builds `count` (1–5) blank `WebView` engine instances ahead of time. |
| `preloadUrl(String url)` | Loads `url` in the background to warm the shared HTTP cache for that page. |

> **Note:** `preloadUrl` is best-effort — it relies entirely on the target server's HTTP caching headers (`Cache-Control`, `ETag`, etc.). If a resource is served with `no-store` or similar, preloading it simply has no measurable effect; it won't error, it just won't help for that resource.

---

### 4. Cache & Data Management (`WebviewCacheManager`)

Independently of any [WebviewWidget] currently on screen, you can clear the data shared by every non-`incognito` Webview in your app:

```dart
// HTTP cache only (images, scripts, fetch/XHR responses...)
await WebviewCacheManager.clearCache();

// Cookies only
await WebviewCacheManager.clearCookies();

// Everything: cache, cookies, localStorage, IndexedDB, service workers...
await WebviewCacheManager.clearAllData();
```

Available on all 5 platforms. On Windows specifically, `clearCache()`/`clearAllData()` need at least one `WebviewWidget` to have already been created during the app session (the default WebView2 profile only exists from that point on) — call it after your first webview is created rather than at app launch.

### 5. Remote Debugging Toggle (`WebviewPlusController.setWebContentsDebuggingEnabled`)

Unlike `WebviewSettings.isInspectable` (which only applies to the single instance it's set on), this toggles Chrome DevTools / Safari Web Inspector access for **every** Webview in the app, existing and future ones — handy to gate behind `kDebugMode`:

```dart
void main() {
  if (kDebugMode) {
    WebviewPlusController.setWebContentsDebuggingEnabled();
  }
  runApp(const MyApp());
}
```

### 6. Raw CSS Injected on Every Load (`initialCss`)

```dart
WebviewWidget(
  initialUrl: 'https://example.com',
  initialCss: 'body { font-family: "Inter", sans-serif; }',
)
```

Unlike `injectCssData` on the controller (a one-off injection into whatever page is currently loaded), `initialCss` is re-applied automatically on every page load — including subsequent in-app navigations — on all 5 platforms.

---

## ⚙️ Configuration Options (`WebviewSettings`)

Pass a custom `WebviewSettings` configuration object to fully customize behavior per-platform:

```dart
const WebviewSettings(
  javaScriptEnabled: true,
  domStorageEnabled: true,
  transparentBackground: true,
  isInspectable: true, // Enables Chrome DevTools / Safari Web Inspector debugging
)
```

### Full Settings Parameter Grid

| Property | Default | Platform | Scope / Behavior Description |
| :--- | :--- | :--- | :--- |
| `javaScriptEnabled` | `true` | All | Controls JavaScript runtime execution. |
| `domStorageEnabled` | `true` | Mobile/macOS | Enables `localStorage`, `sessionStorage`, and `IndexedDB`. |
| `allowFileAccess` | `true` | Android | Permits explicit file scheme loads (`file://`). |
| `allowContentAccess` | `true` | Android | Permits native Content Provider paths (`content://`). |
| `supportZoom` | `true` | All | Determines if pinch-to-zoom gestures are captured. |
| `builtInZoomControls` | `true` | Android | Displays default Android platform zoom utility components. |
| `displayZoomControls` | `false` | Android | Overlays physical zoom buttons directly inside screen layout. |
| `mediaPlaybackRequiresUserGesture` | `true` | All | Prevents HTML5 videos/media from autoplaying without user clicks. |
| `transparentBackground` | `false` | All | Makes the viewport background transparent to display Flutter widgets behind. |
| `initialBackgroundColor` | `null` | All | Optional default color painted as a fallback behind transparent areas or while the Webview initially initializes. |
| `userAgent` | `null` | All | Override target browser layout engine header. `null` falls back to system default. |
| `isInspectable` | `false` | All | Opens hooks for Safari Web Inspector or Chrome DevTools remote attachment. |
| `disableContextMenu` | `false` | Android/iOS/macOS | Disables long-press (mobile) / right-click (macOS) contextual menus and touch selection interactions completely. |
| `disableLongPressContextMenuOnLinks`| `false` | Android/iOS/macOS | Prevents special links preview/copy contextual windows specifically. |
| `selectionTextColor` | `null` | All (native handle tint: Android only) | Colors selected-text highlighting via an injected `::selection` CSS rule on every loaded page. On Android, also attempts a best-effort native tint of the selection handles themselves — see the caveat below. |
| `selectionHandleColor` | `null` | Android | Companion color for the native selection "handle" drop. Best-effort only: Android doesn't allow overriding a theme attribute with an arbitrary runtime value, so the plugin ships a compiled color resource (`@color/webview_plus_selection_handle_color`) that actually drives the handle tint — override that resource in your own app's `res/values` for a build-time-fixed value. |
| `androidPlatformViewType` | `AndroidPlatformViewType.surfaceComposition` | Android | Choose Android rendering mode: `surfaceComposition` (Texture Layer Hybrid Composition, recommended, API 23+), `hybridComposition` (classic Hybrid Composition, robust but can be janky during Flutter animations), or `virtualDisplay` (TextureView, less fluid scroll but broadest device compatibility). On API < 23, `surfaceComposition` automatically falls back to `hybridComposition` to ensure proper rendering. |
| `allowsBackForwardNavigationGestures`| `false` | iOS | Enables edge swipe gesture history forward/backward navigations. |
| `allowsLinkPreview` | `false` | iOS | Enables 3D Touch/Long Press link "Peek and Pop" preview panels. |
| `disabledDefaultContextMenuItems` | `{}` | Android/iOS | Individually disables default context menu items (copy, cut, paste, select all…). No effect if `disableContextMenu` is already `true`; custom items added via `contextMenuItems` are never affected. |
| `disableLinkHoverPreview` | `true` | Desktop | Hides status bar hover URL strings appearing at the bottom of the pane (mainly Windows/Webview2). |
| `disablePrinting` | `false` | All | Blocks printing triggered via the `Ctrl+P` shortcut and, where the platform supports it, `window.print()`. |
| `initialUserScripts` | `[]` | Android/iOS/macOS | JavaScript `UserScript`s automatically injected into every page that loads. |
| `disableKeyboardResize` | `false` | Android/iOS | Prevents the webview from resizing when the on-screen keyboard appears. Purely native, based on system IME insets — no `window.innerHeight` JS hacks involved. |
| `windowsScrollbarTheme` | `WindowsScrollbarTheme()` | Windows/macOS/Linux | Custom scrollbar colors (track/thumb/thumb-hover) and mode (`auto`/`light`/`dark`/`custom`/`hidden`), via `DesktopScrollbarThemeMode`. Applied through native composition on Windows and via injected `::-webkit-scrollbar` CSS on macOS/Linux. No effect on Android/iOS. |
| `cacheEnabled` | `true` | All | Toggle session and HTTP caching. On iOS/macOS, tied to the same non-persistent data store used by `incognito`. |
| `incognito` | `false` | All | Run webview in a private/incognito profile — no cookies, cache, `localStorage`, or history persisted beyond the webview's lifetime. |
| `applicationNameForUserAgent` | `null` | All | Easily append a custom app name to the default User Agent, without overriding it entirely (see `userAgent` for that). |
| `textZoom` | `100` | Android/Windows/Linux | Adjust text sizing percentage. No effect on iOS/macOS (no equivalent independent of page zoom). |
| `minimumFontSize` | `null` | Android/iOS/macOS | Enforce a minimum readable font size, in CSS pixels. |
| `allowsInlineMediaPlayback` | `true` | iOS | Native control over inline video playback instead of forced fullscreen. Not needed elsewhere: Android/Windows/Linux already play media inline by default, and macOS never forces fullscreen in the first place. |
| `allowsPictureInPicture` | `true` | iOS/macOS | Allow Picture-in-Picture mode on supported native media. |
| `javaScriptCanOpenWindowsAutomatically` | `false` | All | Prevent/allow `window.open()` calls without a prior user gesture. |
| `geolocationEnabled` | `false` | Android | Native hardware geolocation toggle (`navigator.geolocation`). Actual grant also depends on OS-level permissions, requested separately on the Flutter side. |
| `thirdPartyCookiesEnabled` | `true` | Android | Manage cross-site cookie settings (`CookieManager.setAcceptThirdPartyCookies`). |
| `forceDarkMode` | `false` | Android/Windows/macOS | Explicitly force a dark rendering of the page even if it doesn't implement `prefers-color-scheme` itself. On macOS this is done by forcing the view's effective `NSAppearance` to `.darkAqua`, which `WKWebView` picks up for the CSS media query. |
| `overScrollMode` | `OverScrollMode.ifContentScrolls` | Android (native), Windows/Linux (best-effort CSS `overscroll-behavior`) | Controls the overscroll glow/bounce effect at scroll boundaries. No effect on iOS/macOS, where `bounces` drives this instead. |
| `webviewContentMode` | `WebviewContentMode.recommended` | Android | Forces the Desktop or Mobile version of a page, or leaves it to the platform's recommended default. |
| `bounces` | `true` | iOS | Enables the "bounce" scroll physics past content edges (`UIScrollView.bounces`). Not applicable on macOS: `WKWebView` doesn't expose a public equivalent there. |
| `initialScale` | `null` | Android | Set default viewport zoom scale (`WebView.setInitialScale`). `null` leaves the page's own viewport meta tag in control. |
| `hideNativeScrollbars` | `false` | All | Easily hide default scrollbars while keeping the content scrollable. On macOS/Linux this reuses the same `::-webkit-scrollbar` CSS mechanism as `windowsScrollbarTheme` above, and takes priority over it when both are set. |
| `safeBrowsingEnabled` | `true` | Android | Toggle Google Safe Browsing checks for known phishing/malware pages. |
| `allowMixedContent` | `false` | Android | Allow loading `http://` resources inside an `https://` page. |
| `allowFileAccessFromFileURLs` | `false` | iOS/macOS | Allows a page loaded from `file://` to fetch other local files via `fetch`/XHR. Off by default (WebKit blocks this for security) — this is the most common cause of a local file that "won't open" (relative resources not found). No effect on Android/Windows/Linux, which already allow this natively. |
| `allowUniversalAccessFromFileURLs` | `false` | iOS/macOS | More permissive superset of `allowFileAccessFromFileURLs`: also allows a `file://` page to request *any* origin, including `http(s)://`. Only enable this for trusted bundled content you control — never for remote/untrusted pages, as it disables an important security boundary. Implies `allowFileAccessFromFileURLs`. |

> **Note on `selectionHandleColor` (Android):** the CSS-based highlight (`selectionTextColor`) always applies reliably. The native handle tint is best-effort only — Android doesn't let a theme attribute be overridden with an arbitrary runtime value, only with resources compiled into the app. The dynamic color you pass drives the native handle tint only insofar as it matches the compiled `@color/webview_plus_selection_handle_color` resource shipped by the plugin.

---

## Setup in MacOS

Add this code in DebugProfile.entitlements and Release.entitlements to have acces in Internet in WebView and acces to all files in the computer.
```entitlements
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.app-sandbox</key>
<false/>
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
```

---

## 🐧 Setup on Linux

In `linux/my_application.cc`, wrap the `FlView` in a `GtkOverlay` right after it's created, **before** `gtk_widget_realize()` and `fl_register_plugins()` are called:

```cpp
FlView* view = fl_view_new(project);
GdkRGBA background_color;
gdk_rgba_parse(&background_color, "#000000");
fl_view_set_background_color(view, &background_color);
gtk_widget_set_hexpand(GTK_WIDGET(view), TRUE);
gtk_widget_set_vexpand(GTK_WIDGET(view), TRUE);
gtk_widget_show(GTK_WIDGET(view));

// --- Add this block ---
GtkWidget* overlay = gtk_overlay_new();
gtk_widget_set_hexpand(overlay, TRUE);
gtk_widget_set_vexpand(overlay, TRUE);
gtk_widget_show(overlay);
gtk_container_add(GTK_CONTAINER(overlay), GTK_WIDGET(view));
gtk_container_add(GTK_CONTAINER(window), overlay);
// --- instead of the original gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view)); ---

g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb), self);
gtk_widget_realize(GTK_WIDGET(view));

fl_register_plugins(FL_PLUGIN_REGISTRY(view));
```

That's the only change needed — the rest of `my_application.cc` (window/header bar setup, `first_frame_cb`, command line handling, etc.) stays exactly as generated by `flutter create`.

---

## ⚠️ Known Limitations & Architecture Caveats

- **Windows & Linux (Advanced Composition):** Both Windows (`Webview2`) and Linux (`WebKitWebView`) use simplified window rendering strategies. True seamless stacking layouts (advanced transparency masks, multi-layered Flutter widgets directly over or under the web layer) may require unique configurations within the specific target OS shell runner.
- **Linux Overlay Architecture:** Since Linux lacks generic `PlatformView` composition hooks inside Flutter's engine core, this plugin binds a direct native `GtkWidget` on top of the Flutter window frame coordinates dynamically. Size, placement, and lifecycle updates are synchronised directly over global method channels. **Requires a one-time edit to `linux/my_application.cc`** — see [Setup on Linux](#-setup-on-linux).
- **Web Iframes Constraints:** `onNavigationRequest` is fully dependable only when loading content with matching origins (such as local bundled assets). Standard web browser security frames block cross-origin navigation interceptions on independent `<iframe>` nodes.
- **Android Composition Mode Detection:** The plugin queries the device's API level asynchronously on first use and optimistically assumes API 23+ (Texture Layer Hybrid Composition) while that check is in flight — accurate for the vast majority of active devices. On the rare API < 23 device, the widget seamlessly rebuilds with the correct legacy mode once the check resolves, which may cause a single, barely noticeable extra rebuild the very first time a webview is shown in the app's lifetime.
- **`preloadUrl` Has No Effect on Uncacheable Content:** Preloading only helps for resources the server allows to be cached (see [Preloading & Faster First Load](#-preloading--faster-first-load-android)).
- **`WebviewCacheManager.clearCache()`/`clearAllData()` on Windows:** need at least one `WebviewWidget` to have already been created during the app session, since the default WebView2 profile they operate on doesn't otherwise exist yet.
- **`WebviewPlusController.setWebContentsDebuggingEnabled()` on iOS/macOS:** best-effort — relies on `WKWebView.isInspectable`, only available on iOS 16.4+/macOS 13.3+. On older OS versions it's a silent no-op; use `WebviewSettings.isInspectable` at webview creation time instead.
- **`bounces` / `allowsInlineMediaPlayback`:** iOS-only. `WKWebView` on macOS never forces fullscreen media playback and doesn't expose a public bounce-physics API, so neither setting has a macOS equivalent.

---

## 📝 Example

For a complete working deployment showcase showcasing full bidirectional communication pipelines, layout changes, and asset mounting routines, review the detailed `example/lib/main.dart` source file.

---

## 📄 License

Developed by Noam. Licensed under standard project conditions.