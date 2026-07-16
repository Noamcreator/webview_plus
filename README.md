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
| **Linux** | `WebKitWebview` (WebKitGTK) | Direct `GtkWidget` window overlay anchoring |
| **Web** | Native DOM `<iframe>` | Standard HTML5 Element Embedding |

---

## ✨ Features

- **True Native Embedding:** Zero unnecessary wrappers. Uses `WKWebview` on Apple platforms, Chromium-based `Webview2` on Windows, and `WebKitGTK` on Linux.
- **Bi-directional JavaScript Bridge:** 
  - Execute Dart to JS via `evaluateJavascript` with **automatic type unboxing** (returns real Dart types like `int`, `Map`, `List` instead of raw strings).
  - Handle JS to Dart messages using either basic string streaming or full-featured promises via `window.webview_plus.callHandler`.
- **Custom Native Context Menus:** Fully customize text selection and long-press contextual menus on Android and iOS using native platform APIs (`ActionMode` & `UIContextMenuConfiguration`).
- **Comprehensive Lifecycle Callbacks:** Track page loading starts, stops, navigation interception, and handle platform-specific web view errors.
- **Advanced Asset & File System Access:** Load URLs, bundle assets, or absolute file paths from the local device storage.
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
| `disableContextMenu` | `false` | Android/iOS | Disables long-press menus and touch selection interactions completely. |
| `disableLongPressContextMenuOnLinks`| `false` | Android/iOS | Prevents special links preview/copy contextual windows specifically. |
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

## ⚠️ Known Limitations & Architecture Caveats

- **Windows & Linux (Advanced Composition):** Both Windows (`Webview2`) and Linux (`WebKitWebview`) use simplified window rendering strategies. True seamless stacking layouts (advanced transparency masks, multi-layered Flutter widgets directly over or under the web layer) may require unique configurations within the specific target OS shell runner.
- **Linux Overlay Architecture:** Since Linux lacks generic `PlatformView` composition hooks inside Flutter's engine core, this plugin binds a direct native `GtkWidget` on top of the Flutter window frame coordinates dynamically. Size, placement, and lifecycle updates are synchronised directly over global method channels.
- **Web Iframes Constraints:** `onNavigationRequest` is fully dependable only when loading content with matching origins (such as local bundled assets). Standard web browser security frames block cross-origin navigation interceptions on independent `<iframe>` nodes.
- **Android Composition Mode Detection:** The plugin queries the device's API level asynchronously on first use and optimistically assumes API 23+ (Texture Layer Hybrid Composition) while that check is in flight — accurate for the vast majority of active devices. On the rare API < 23 device, the widget seamlessly rebuilds with the correct legacy mode once the check resolves, which may cause a single, barely noticeable extra rebuild the very first time a webview is shown in the app's lifetime.
- **`preloadUrl` Has No Effect on Uncacheable Content:** Preloading only helps for resources the server allows to be cached (see [Preloading & Faster First Load](#-preloading--faster-first-load-android)).

---

## 📝 Example

For a complete working deployment showcase showcasing full bidirectional communication pipelines, layout changes, and asset mounting routines, review the detailed `example/lib/main.dart` source file.

---

## 📄 License

Developed by Noam. Licensed under standard project conditions.