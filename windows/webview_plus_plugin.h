#ifndef FLUTTER_PLUGIN_webview_plus_PLUGIN_H_
#define FLUTTER_PLUGIN_webview_plus_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>
#include <windows.h>
#include <windows.ui.composition.h>
#include <wrl.h>
#include "WebView2.h"

#include <functional>
#include <memory>
#include <string>

#include "platform/webview_platform.h"
#include "rendering/texture_bridge_gpu.h"

#ifdef FLUTTER_PLUGIN_IMPL
#define webview_plus_EXPORT __declspec(dllexport)
#else
#define webview_plus_EXPORT __declspec(dllimport)
#endif

namespace webview_plus {

struct VirtualKeyState {
  void set_isLeftButtonDown(bool is_down) {
    set(COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS::
            COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_LEFT_BUTTON,
        is_down);
  }

  void set_isRightButtonDown(bool is_down) {
    set(COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS::
            COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_RIGHT_BUTTON,
        is_down);
  }

  void set_isMiddleButtonDown(bool is_down) {
    set(COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS::
            COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_MIDDLE_BUTTON,
        is_down);
  }

  COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS state() const { return state_; }

 private:
  COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS state_ =
      COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS::
          COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_NONE;

  void set(COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS key, bool flag) {
    if (flag) {
      state_ |= key;
    } else {
      state_ &= ~key;
    }
  }
};

// Encapsule un contrôle WebView2 rendu via composition + texture Flutter.
class WebViewPlusInstance {
 public:
  WebViewPlusInstance(flutter::PluginRegistrarWindows* registrar,
                         WebviewPlatform* platform, HWND message_hwnd,
                         int64_t view_id, const std::string& initial_url,
                         const std::string& initial_asset,
                         const std::string& initial_file,
                         const flutter::EncodableMap& initial_settings,
                         std::function<void(int64_t texture_id)> on_ready,
                         std::function<void(const std::string&)> on_error);
  ~WebViewPlusInstance();

  int64_t texture_id() const { return texture_id_; }

  void LoadUrl(const std::wstring& url);
  void LoadFlutterAsset(const std::string& asset_path);
  void LoadFile(const std::wstring& path);
  void LoadHtmlOrData(const std::wstring& html);
  void GetHtml(std::function<void(std::wstring)> callback);
  void InjectScriptFromUrl(const std::wstring& url);
  void InjectCssFromUrl(const std::wstring& url);
  void EvaluateJavaScript(const std::wstring& code,
                          std::function<void(std::wstring)> callback);
  void SetSize(double width, double height, double scale_factor);
  void SetCursorPos(double x, double y);
  void SetPointerButtonState(int button, bool is_down);
  void SetScrollDelta(double dx, double dy);

 private:
  void InitializeWebView2();
  bool CreateCompositionSurface();
  void RegisterTexture();
  void ApplySettings(const flutter::EncodableMap& settings);
  void InjectBridgeScript();
  void HandleWebMessage(const std::wstring& raw);
  void SendScroll(double delta, bool horizontal);

  static std::wstring GetExecutableDir();
  std::wstring BuildAssetUrl(const std::string& asset_path);
  static std::wstring EscapeJsonString(const std::wstring& s);
  static std::wstring EncodableValueToJsonLiteral(
      const flutter::EncodableValue& value);
  static std::wstring DecodeJsonStringResult(const std::wstring& raw);
  static flutter::EncodableValue ParseJsonToEncodableValue(
      const std::wstring& json);

  HWND message_hwnd_;
  int64_t view_id_;
  int64_t texture_id_ = -1;

  std::string initial_url_;
  std::string initial_asset_;
  std::string initial_file_;
  flutter::EncodableMap initial_settings_;

  bool is_navigating_internally_ = false;
  bool disable_context_menu_ = false;
  bool disable_long_press_links_ = false;
  std::wstring selection_css_color_;
  bool disable_link_hover_preview_ = true;
  bool disable_printing_ = false;

  float scale_factor_ = 1.0f;
  POINT last_cursor_pos_ = {0, 0};
  VirtualKeyState virtual_keys_;
  double horizontal_scroll_remainder_ = 0.0;
  double vertical_scroll_remainder_ = 0.0;

  std::function<void(int64_t texture_id)> on_ready_;
  std::function<void(const std::string&)> on_error_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::TextureVariant> flutter_texture_;
  std::unique_ptr<TextureBridgeGpu> texture_bridge_;

  Microsoft::WRL::ComPtr<ICoreWebView2CompositionController>
      composition_controller_;
  Microsoft::WRL::ComPtr<ICoreWebView2Controller3> controller_;
  Microsoft::WRL::ComPtr<ICoreWebView2> webview_;
  Microsoft::WRL::ComPtr<ABI::Windows::UI::Composition::IVisual> surface_visual_;

  flutter::PluginRegistrarWindows* registrar_;
  WebviewPlatform* platform_;
};

class WebViewPlusPluginCApi : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  WebViewPlusPluginCApi(flutter::PluginRegistrarWindows* registrar);
  virtual ~WebViewPlusPluginCApi();

 private:
  flutter::PluginRegistrarWindows* registrar_;
};

}  // namespace webview_plus

extern "C" {
webview_plus_EXPORT void WebViewPlusPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);
}

#endif  // FLUTTER_PLUGIN_webview_plus_PLUGIN_H_
