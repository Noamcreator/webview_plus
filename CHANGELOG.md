## 0.4.0

Windows changes:
- Navigation: Fixed an issue where the canGoBack and canGoForward state properties were not functioning.
- Focus: Fixed the WebView hijacking focus and causing the main Flutter window to lose active focus when clicked.
- Cursor: Fixed the mouse cursor failing to adapt (e.g., changing to a text-selection cursor) when hovering over web content.
- Context Menu: Fixed the right-click context menu appearing misaligned/offset when running the application in windowed mode.

Android changes:
- Use initSurfaceAndroidView or initHybridAndroidView when is available (API 23+).
- Add support for Android 12's new "Hybrid Composition++" mode (requires API 34+).

## 0.3.0

- Add WebviewEnvironment for Windows (userDataFolder)

## 0.2.0

- Update onLoadStart / onLoadStop / onReceivedError / onNavigationRequest and remove shouldOverrideUrlLoading (now use onNavigationRequest only)
- Add onDOMContentLoaded / onWindowFocus / onWindowBlur

## 0.1.0

- Initial Commit
  