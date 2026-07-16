#include "webview_plus_plugin.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <algorithm>
#include <cmath>
#include <cwctype>
#include <cstdlib>
#include <limits>
#include <map>
#include <string>
#include <vector>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResult;

namespace webview_plus {

namespace {

// ADD THESE THREE HELPERS:
double GetDoubleValue(const EncodableValue& value) {
  if (auto d = std::get_if<double>(&value)) return *d;
  if (auto i = std::get_if<int32_t>(&value)) return static_cast<double>(*i);
  if (auto i64 = std::get_if<int64_t>(&value)) return static_cast<double>(*i64);
  return 0.0;
}

int64_t GetLongValue(const EncodableValue& value) {
  if (auto i64 = std::get_if<int64_t>(&value)) return *i64;
  if (auto i = std::get_if<int32_t>(&value)) return static_cast<int64_t>(*i);
  if (auto d = std::get_if<double>(&value)) return static_cast<int64_t>(*d);
  return 0;
}

std::wstring Utf8ToWide(const std::string& str) {
  if (str.empty()) return std::wstring();
  int size = MultiByteToWideChar(CP_UTF8, 0, str.data(),
                                  static_cast<int>(str.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, str.data(), static_cast<int>(str.size()),
                       result.data(), size);
  return result;
}

std::string WideToUtf8(const std::wstring& str) {
  if (str.empty()) return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, str.data(),
                                  static_cast<int>(str.size()), nullptr, 0,
                                  nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, str.data(), static_cast<int>(str.size()),
                       result.data(), size, nullptr, nullptr);
  return result;
}

std::string WideToUtf8(const wchar_t* str) {
  if (str == nullptr) return std::string();
  return WideToUtf8(std::wstring(str));
}

const EncodableValue* FindKey(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(std::string(key)));
  return it == map.end() ? nullptr : &it->second;
}

bool GetBoolOr(const EncodableMap& map, const char* key, bool def) {
  const auto* v = FindKey(map, key);
  if (!v) return def;
  if (auto b = std::get_if<bool>(v)) return *b;
  return def;
}

// Convertit une couleur ARGB (telle qu'envoyée par Dart, `Color.toARGB32()`)
// en littéral CSS `rgba(...)`. Renvoie une chaîne vide si `key` est absent
// de `settings` (0 est une valeur ARGB valide - transparent noir - donc on
// ne peut pas s'en servir comme sentinelle "absent").
std::wstring ArgbToCssRgbaOr(const EncodableMap& settings, const char* key) {
  const auto* color = FindKey(settings, key);
  if (!color) return L"";

  int64_t argb = 0;
  if (auto v32 = std::get_if<int32_t>(color)) {
    argb = *v32;
  } else if (auto v64 = std::get_if<int64_t>(color)) {
    argb = *v64;
  } else {
    return L"";
  }

  int a = static_cast<int>((argb >> 24) & 0xFF);
  int r = static_cast<int>((argb >> 16) & 0xFF);
  int g = static_cast<int>((argb >> 8) & 0xFF);
  int b = static_cast<int>(argb & 0xFF);
  wchar_t buf[64];
  swprintf_s(buf, L"rgba(%d,%d,%d,%.3f)", r, g, b, a / 255.0);
  return buf;
}

// Traduit `WebviewSettings.initialUserScripts` (liste de `EncodableMap`
// côté Dart, voir `UserScript.toMap()`) en deux listes de scripts
// (`atDocumentStart` / `atDocumentEnd`), converties en UTF-16 pour
// l'injection WebView2.
void ParseUserScripts(const EncodableMap& settings,
                       std::vector<std::wstring>* out_start,
                       std::vector<std::wstring>* out_end) {
  out_start->clear();
  out_end->clear();
  const auto* raw = FindKey(settings, "initialUserScripts");
  const auto* list = raw ? std::get_if<EncodableList>(raw) : nullptr;
  if (!list) return;

  for (const auto& entry_value : *list) {
    const auto* entry = std::get_if<EncodableMap>(&entry_value);
    if (!entry) continue;

    const auto* source_value = FindKey(*entry, "source");
    const auto* source_str =
        source_value ? std::get_if<std::string>(source_value) : nullptr;
    if (!source_str) continue;

    bool is_end = false;
    if (const auto* timing = FindKey(*entry, "injectionTime")) {
      if (const auto* timing_str = std::get_if<std::string>(timing)) {
        is_end = (*timing_str == "atDocumentEnd");
      }
    }

    std::wstring source = Utf8ToWide(*source_str);
    (is_end ? out_end : out_start)->push_back(source);
  }
}

double GetFlutterScrollOffsetMultiplier() {
  constexpr UINT kDefaultLinesPerScroll = 3;
  UINT lines_per_scroll = kDefaultLinesPerScroll;
  SystemParametersInfo(SPI_GETWHEELSCROLLLINES, 0, &lines_per_scroll, 0);
  if (lines_per_scroll == 0 || lines_per_scroll == WHEEL_PAGESCROLL) {
    lines_per_scroll = kDefaultLinesPerScroll;
  }
  return static_cast<double>(lines_per_scroll) * 100.0 / 3.0;
}

class JsonParser {
 public:
  explicit JsonParser(const std::wstring& s) : s_(s), i_(0), n_(s.size()) {}

  EncodableValue Parse() {
    SkipWhitespace();
    return ParseValue();
  }

 private:
  const std::wstring& s_;
  size_t i_;
  size_t n_;

  void SkipWhitespace() {
    while (i_ < n_ && (s_[i_] == L' ' || s_[i_] == L'\t' || s_[i_] == L'\n' ||
                        s_[i_] == L'\r')) {
      ++i_;
    }
  }

  wchar_t Peek() { return i_ < n_ ? s_[i_] : L'\0'; }

  EncodableValue ParseValue() {
    SkipWhitespace();
    wchar_t c = Peek();
    if (c == L'{') return ParseObject();
    if (c == L'[') return ParseArray();
    if (c == L'"') return EncodableValue(WideToUtf8(ParseString()));
    if (c == L't' || c == L'f') return ParseBool();
    if (c == L'n') {
      i_ += 4;
      return EncodableValue();
    }
    return ParseNumber();
  }

  EncodableValue ParseObject() {
    EncodableMap map;
    ++i_;
    SkipWhitespace();
    if (Peek() == L'}') {
      ++i_;
      return EncodableValue(map);
    }
    while (i_ < n_) {
      SkipWhitespace();
      std::wstring key = ParseString();
      SkipWhitespace();
      if (Peek() == L':') ++i_;
      EncodableValue value = ParseValue();
      map.insert({EncodableValue(WideToUtf8(key)), value});
      SkipWhitespace();
      if (Peek() == L',') {
        ++i_;
        continue;
      }
      if (Peek() == L'}') {
        ++i_;
        break;
      }
      break;
    }
    return EncodableValue(map);
  }

  EncodableValue ParseArray() {
    EncodableList list;
    ++i_;
    SkipWhitespace();
    if (Peek() == L']') {
      ++i_;
      return EncodableValue(list);
    }
    while (i_ < n_) {
      list.push_back(ParseValue());
      SkipWhitespace();
      if (Peek() == L',') {
        ++i_;
        continue;
      }
      if (Peek() == L']') {
        ++i_;
        break;
      }
      break;
    }
    return EncodableValue(list);
  }

  std::wstring ParseString() {
    std::wstring out;
    if (Peek() != L'"') return out;
    ++i_;
    while (i_ < n_ && s_[i_] != L'"') {
      wchar_t c = s_[i_];
      if (c == L'\\' && i_ + 1 < n_) {
        wchar_t next = s_[i_ + 1];
        switch (next) {
          case L'"':
            out += L'"';
            i_ += 2;
            break;
          case L'\\':
            out += L'\\';
            i_ += 2;
            break;
          case L'/':
            out += L'/';
            i_ += 2;
            break;
          case L'b':
            out += L'\b';
            i_ += 2;
            break;
          case L'f':
            out += L'\f';
            i_ += 2;
            break;
          case L'n':
            out += L'\n';
            i_ += 2;
            break;
          case L'r':
            out += L'\r';
            i_ += 2;
            break;
          case L't':
            out += L'\t';
            i_ += 2;
            break;
          case L'u': {
            if (i_ + 5 < n_) {
              std::wstring hex = s_.substr(i_ + 2, 4);
              wchar_t code =
                  static_cast<wchar_t>(wcstol(hex.c_str(), nullptr, 16));
              out += code;
              i_ += 6;
            } else {
              i_ += 2;
            }
            break;
          }
          default:
            out += next;
            i_ += 2;
        }
      } else {
        out += c;
        ++i_;
      }
    }
    if (i_ < n_) ++i_;
    return out;
  }

  EncodableValue ParseBool() {
    if (s_.compare(i_, 4, L"true") == 0) {
      i_ += 4;
      return EncodableValue(true);
    }
    if (s_.compare(i_, 5, L"false") == 0) {
      i_ += 5;
      return EncodableValue(false);
    }
    ++i_;
    return EncodableValue(false);
  }

  EncodableValue ParseNumber() {
    size_t start = i_;
    bool is_double = false;
    if (Peek() == L'-' || Peek() == L'+') ++i_;
    while (i_ < n_ && (iswdigit(s_[i_]) || s_[i_] == L'.' || s_[i_] == L'e' ||
                       s_[i_] == L'E' || s_[i_] == L'+' || s_[i_] == L'-')) {
      if (s_[i_] == L'.' || s_[i_] == L'e' || s_[i_] == L'E') is_double = true;
      ++i_;
    }
    std::wstring num_str = s_.substr(start, i_ - start);
    if (num_str.empty()) return EncodableValue();
    if (is_double) {
      return EncodableValue(std::stod(num_str));
    }
    try {
      return EncodableValue(static_cast<int64_t>(std::stoll(num_str)));
    } catch (...) {
      return EncodableValue(std::stod(num_str));
    }
  }
};

std::unique_ptr<WebviewPlatform> g_platform;
Microsoft::WRL::ComPtr<ICoreWebView2Environment3> g_environment;
bool g_message_window_class_registered = false;
WNDCLASSW g_message_window_class = {};
std::map<int64_t, std::unique_ptr<WebViewPlusInstance>> g_instances;

bool EnsurePlatform() {
  if (!g_platform) {
    g_platform = std::make_unique<WebviewPlatform>();
  }
  return g_platform && g_platform->IsSupported();
}

// Fenêtre factice invisible utilisée comme hôte du
// ICoreWebView2CompositionController. Elle DOIT être un enfant (WS_CHILD)
// de la vraie fenêtre top-level Flutter, et non un message-only window
// sous HWND_MESSAGE comme auparavant : un message-only window est
// totalement détaché de la hiérarchie de fenêtres réelle. Quand WebView2
// réagit à un clic en appelant en interne SetFocus() sur cette fenêtre,
// Windows désactivait alors la précédente fenêtre active — la vraie
// fenêtre Flutter — faute de lien de parenté entre les deux. En la
// rattachant comme enfant, un SetFocus() dessus reste "à l'intérieur" de
// la fenêtre Flutter du point de vue de Windows, qui ne la désactive
// plus.
HWND CreateMessageWindow(HWND parent) {
  if (!g_message_window_class_registered) {
    g_message_window_class.lpszClassName = L"WebViewPlusMessage";
    g_message_window_class.lpfnWndProc = &DefWindowProc;
    g_message_window_class.hInstance = GetModuleHandle(nullptr);
    RegisterClassW(&g_message_window_class);
    g_message_window_class_registered = true;
  }

  return CreateWindowExW(0, g_message_window_class.lpszClassName, L"",
                         WS_CHILD, 0, 0, 0, 0, parent, nullptr,
                         g_message_window_class.hInstance, nullptr);
}

// Sous-classement de la vraie fenêtre top-level Flutter afin de détecter
// ses déplacements à l'écran (WM_MOVE / WM_WINDOWPOSCHANGED) et de
// prévenir chaque instance WebView2 en conséquence (voir
// WebViewPlusInstance::NotifyWindowMoved). Sans cela, le menu contextuel
// par défaut de WebView2 (et l'IME, etc.) est mal positionné en mode
// fenêtré, WebView2 n'ayant aucun autre moyen de connaître la position
// réelle de la fenêtre.
LRESULT CALLBACK WebViewPlusWindowSubclassProc(HWND hwnd, UINT msg,
                                                WPARAM wparam, LPARAM lparam,
                                                UINT_PTR subclass_id,
                                                DWORD_PTR ref_data) {
  if (msg == WM_MOVE || msg == WM_WINDOWPOSCHANGED) {
    for (auto& entry : g_instances) {
      entry.second->NotifyWindowMoved();
    }
  }
  if (msg == WM_NCDESTROY) {
    RemoveWindowSubclass(hwnd, &WebViewPlusWindowSubclassProc, subclass_id);
  }
  return DefSubclassProc(hwnd, msg, wparam, lparam);
}

bool g_window_subclassed = false;

void EnsureWindowSubclassed(HWND top_level_hwnd) {
  if (g_window_subclassed || !top_level_hwnd) return;
  SetWindowSubclass(top_level_hwnd, &WebViewPlusWindowSubclassProc,
                     /*uIdSubclass=*/1, 0);
  g_window_subclassed = true;
}

}  // namespace

WebViewPlusInstance::WebViewPlusInstance(
    flutter::PluginRegistrarWindows* registrar, WebviewPlatform* platform,
    HWND message_hwnd, int64_t view_id, const std::string& initial_url,
    const std::string& initial_asset, const std::string& initial_file,
    const flutter::EncodableMap& initial_settings,
    const std::string& user_data_folder,
    std::function<void(int64_t texture_id)> on_ready,
    std::function<void(const std::string&)> on_error)
    : message_hwnd_(message_hwnd),
      view_id_(view_id),
      initial_url_(initial_url),
      initial_asset_(initial_asset),
      initial_file_(initial_file),
      initial_settings_(initial_settings),
      user_data_folder_(user_data_folder),
      on_ready_(std::move(on_ready)),
      on_error_(std::move(on_error)),
      registrar_(registrar),
      platform_(platform) {
  std::string channel_name = "webview_plus_" + std::to_string(view_id);
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), channel_name,
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const MethodCall<EncodableValue>& call,
             std::unique_ptr<MethodResult<EncodableValue>> result) {
        const std::string& method = call.method_name();
        const auto* args = std::get_if<EncodableMap>(call.arguments());

        if (method == "loadUrl" && args) {
          auto it = args->find(EncodableValue("url"));
          if (it != args->end()) {
            LoadUrl(Utf8ToWide(std::get<std::string>(it->second)));
          }
          result->Success();
        } else if (method == "loadFlutterAsset" && args) {
          auto it = args->find(EncodableValue("assetPath"));
          if (it != args->end()) {
            LoadFlutterAsset(std::get<std::string>(it->second));
          }
          result->Success();
        } else if (method == "loadFile" && args) {
          auto it = args->find(EncodableValue("filePath"));
          if (it != args->end()) {
            LoadFile(Utf8ToWide(std::get<std::string>(it->second)));
          }
          result->Success();
        } else if (method == "loadHtmlString" && args) {
          auto it = args->find(EncodableValue("html"));
          if (it != args->end()) {
            LoadHtmlOrData(Utf8ToWide(std::get<std::string>(it->second)));
          }
          result->Success();
        } else if (method == "loadData" && args) {
          auto it = args->find(EncodableValue("data"));
          if (it != args->end()) {
            LoadHtmlOrData(Utf8ToWide(std::get<std::string>(it->second)));
          }
          result->Success();
        } else if (method == "evaluateJavascript" && args) {
          auto it = args->find(EncodableValue("code"));
          if (it != args->end()) {
            auto shared_result =
                std::make_shared<std::unique_ptr<MethodResult<EncodableValue>>>(
                    std::move(result));
            EvaluateJavaScript(
                Utf8ToWide(std::get<std::string>(it->second)),
                [shared_result](std::wstring value) {
                  (*shared_result)->Success(
                      WebViewPlusInstance::ParseJsonToEncodableValue(value));
                });
            return;
          }
          result->Success();
        } else if (method == "getHtml") {
          auto shared_result =
              std::make_shared<std::unique_ptr<MethodResult<EncodableValue>>>(
                  std::move(result));
          GetHtml([shared_result](std::wstring html) {
            (*shared_result)->Success(EncodableValue(WideToUtf8(html)));
          });
          return;
        } else if (method == "injectJavascriptFileFromUrl" && args) {
          auto it = args->find(EncodableValue("url"));
          if (it != args->end()) {
            InjectScriptFromUrl(Utf8ToWide(std::get<std::string>(it->second)));
          }
          result->Success();
        } else if (method == "injectJavascriptFileFromAsset" && args) {
          auto it = args->find(EncodableValue("assetFilePath"));
          if (it != args->end()) {
            InjectScriptFromUrl(BuildAssetUrl(std::get<std::string>(it->second)));
          }
          result->Success();
        } else if (method == "injectCSSFileFromUrl" && args) {
          auto it = args->find(EncodableValue("url"));
          if (it != args->end()) {
            InjectCssFromUrl(Utf8ToWide(std::get<std::string>(it->second)));
          }
          result->Success();
        } else if (method == "injectCSSFileFromAsset" && args) {
          auto it = args->find(EncodableValue("assetFilePath"));
          if (it != args->end()) {
            InjectCssFromUrl(BuildAssetUrl(std::get<std::string>(it->second)));
          }
          result->Success();
        } else if (method == "reload") {
          if (webview_) webview_->Reload();
          result->Success();
        } else if (method == "goBack") {
          if (webview_) webview_->GoBack();
          result->Success();
        } else if (method == "goForward") {
          if (webview_) webview_->GoForward();
          result->Success();
        } else if (method == "canGoBack") {
          BOOL can_go_back = FALSE;
          if (webview_) webview_->get_CanGoBack(&can_go_back);
          result->Success(EncodableValue(static_cast<bool>(can_go_back)));
        } else if (method == "canGoForward") {
          BOOL can_go_forward = FALSE;
          if (webview_) webview_->get_CanGoForward(&can_go_forward);
          result->Success(EncodableValue(static_cast<bool>(can_go_forward)));
        } else {
          result->NotImplemented();
        }
      });

  InitializeWebView2();
}

WebViewPlusInstance::~WebViewPlusInstance() {
  if (texture_id_ >= 0) {
    registrar_->texture_registrar()->UnregisterTexture(texture_id_);
  }
  if (controller_) {
    controller_->Close();
  }
  if (message_hwnd_) {
    DestroyWindow(message_hwnd_);
  }
}

bool WebViewPlusInstance::CreateCompositionSurface() {
  auto compositor = platform_->compositor();
  if (!compositor) {
    return false;
  }

  Microsoft::WRL::ComPtr<ABI::Windows::UI::Composition::IContainerVisual> root;
  if (FAILED(compositor->CreateContainerVisual(root.GetAddressOf()))) {
    return false;
  }

  // Conversion sûre d'une interface COM à une autre via QueryInterface
  if (FAILED(root.As(&surface_visual_))) {
    return false;
  }

  surface_visual_->put_Size({1280, 720});
  surface_visual_->put_IsVisible(true);

  Microsoft::WRL::ComPtr<ABI::Windows::UI::Composition::IVisual> webview_visual;
  if (FAILED(compositor->CreateContainerVisual(
          reinterpret_cast<ABI::Windows::UI::Composition::IContainerVisual**>(
              webview_visual.GetAddressOf())))) {
    return false;
  }

  Microsoft::WRL::ComPtr<ABI::Windows::UI::Composition::IVisual2>
      webview_visual2;
  if (SUCCEEDED(webview_visual.As(&webview_visual2)) && webview_visual2) {
    webview_visual2->put_RelativeSizeAdjustment({1.0f, 1.0f});
  }

  Microsoft::WRL::ComPtr<ABI::Windows::UI::Composition::IVisualCollection>
      children;
  if (FAILED(root->get_Children(children.GetAddressOf()))) {
    return false;
  }
  children->InsertAtTop(webview_visual.Get());

  if (!composition_controller_) {
    return false;
  }

  Microsoft::WRL::ComPtr<ABI::Windows::UI::Composition::IVisual2>
      webview_visual_target;
  if (FAILED(webview_visual.As(&webview_visual_target)) ||
      !webview_visual_target) {
    return false;
  }

  composition_controller_->put_RootVisualTarget(webview_visual_target.Get());
  controller_->put_IsVisible(TRUE);
  return true;
}

void WebViewPlusInstance::RegisterTexture() {
  if (!surface_visual_ || texture_id_ >= 0) {
    return;
  }

  texture_bridge_ = std::make_unique<TextureBridgeGpu>(
      platform_->graphics_context(), surface_visual_.Get());

  flutter_texture_ = std::make_unique<flutter::TextureVariant>(
      flutter::GpuSurfaceTexture(
          kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
          [bridge = texture_bridge_.get()](
              size_t width, size_t height) -> const FlutterDesktopGpuSurfaceDescriptor* {
            return bridge->GetSurfaceDescriptor(width, height);
          }));

  texture_id_ =
      registrar_->texture_registrar()->RegisterTexture(flutter_texture_.get());
  texture_bridge_->SetOnFrameAvailable([this]() {
    registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_);
  });
}

void WebViewPlusInstance::InitializeWebView2() {
  auto on_failure = [this](const std::string& message) {
    if (on_error_) {
      on_error_(message);
    }
  };

  auto init_controller = [this, on_failure](
                             Microsoft::WRL::ComPtr<ICoreWebView2Environment3>
                                 env) {
    if (!env) {
      on_failure("WebView2 environment unavailable");
      return;
    }

    env->CreateCoreWebView2CompositionController(
        message_hwnd_,
        Microsoft::WRL::Callback<
            ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler>(
            [this, on_failure](
                HRESULT result,
                ICoreWebView2CompositionController* controller) -> HRESULT {
              if (FAILED(result) || controller == nullptr) {
                on_failure("CreateCoreWebView2CompositionController failed");
                return S_OK;
              }

              composition_controller_ = controller;
              if (FAILED(composition_controller_.As(&controller_)) ||
                  !controller_ ||
                  FAILED(controller_->get_CoreWebView2(webview_.GetAddressOf()))) {
                on_failure("CoreWebView2 controller unavailable");
                return S_OK;
              }

              COREWEBVIEW2_COLOR transparent{0, 0, 0, 0};
              controller_->put_DefaultBackgroundColor(transparent);

              controller_->put_BoundsMode(COREWEBVIEW2_BOUNDS_MODE_USE_RAW_PIXELS);
              controller_->put_ShouldDetectMonitorScaleChanges(FALSE);
              controller_->put_RasterizationScale(1.0);

              EventRegistrationToken accel_token;
              controller_->add_AcceleratorKeyPressed(
                  Microsoft::WRL::Callback<
                      ICoreWebView2AcceleratorKeyPressedEventHandler>(
                      [this](ICoreWebView2Controller* sender,
                             ICoreWebView2AcceleratorKeyPressedEventArgs* args)
                          -> HRESULT {
                        if (!disable_printing_) return S_OK;
                        COREWEBVIEW2_KEY_EVENT_KIND kind;
                        args->get_KeyEventKind(&kind);
                        if (kind != COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN &&
                            kind !=
                                COREWEBVIEW2_KEY_EVENT_KIND_SYSTEM_KEY_DOWN) {
                          return S_OK;
                        }
                        UINT32 key = 0;
                        args->get_VirtualKey(&key);
                        // Ctrl+P déclenche l'impression native de
                        // WebView2 avant même que la page ne reçoive
                        // l'événement clavier : on l'intercepte donc ici,
                        // au niveau du contrôleur, plutôt qu'en JavaScript
                        // (voir aussi la surcharge de `window.print` dans
                        // `InjectBridgeScript`, qui couvre l'appel
                        // programmatique depuis la page).
                        if (key == 'P' &&
                            (GetKeyState(VK_CONTROL) & 0x8000) != 0) {
                          args->put_Handled(TRUE);
                        }
                        return S_OK;
                      })
                      .Get(),
                  &accel_token);
              
              EventRegistrationToken focus_token;
              controller_->add_GotFocus(
                  Microsoft::WRL::Callback<ICoreWebView2FocusChangedEventHandler>(
                      [this](ICoreWebView2Controller* sender, IUnknown* args)
                          -> HRESULT {
                        channel_->InvokeMethod("onWindowFocus", nullptr);
                        return S_OK;
                      })
                      .Get(),
                  &focus_token);

              EventRegistrationToken blur_token;
              controller_->add_LostFocus(
                  Microsoft::WRL::Callback<ICoreWebView2FocusChangedEventHandler>(
                      [this](ICoreWebView2Controller* sender, IUnknown* args)
                          -> HRESULT {
                        channel_->InvokeMethod("onWindowBlur", nullptr);
                        return S_OK;
                      })
                      .Get(),
                  &blur_token);

              // En mode composition, WebView2 n'a pas de HWND visible sur
              // lequel poser lui-même le curseur système : c'est la
              // fenêtre Flutter qui doit le faire. On écoute donc les
              // changements de curseur voulus par la page et on les
              // transmet à Dart. add_CursorChanged/get_Cursor font partie
              // de l'interface stable ICoreWebView2CompositionController,
              // pas besoin de QueryInterface vers une variante.
              EventRegistrationToken cursor_token;
              composition_controller_->add_CursorChanged(
                  Microsoft::WRL::Callback<ICoreWebView2CursorChangedEventHandler>(
                      [this](ICoreWebView2CompositionController* sender,
                             IUnknown* args) -> HRESULT {
                        HCURSOR cursor = nullptr;
                        if (sender) {
                          sender->get_Cursor(&cursor);
                        }
                        channel_->InvokeMethod(
                            "onCursorChanged",
                            std::make_unique<EncodableValue>(CursorKindFromHandle(cursor)));
                        return S_OK;
                      })
                      .Get(),
                  &cursor_token);

              if (!CreateCompositionSurface()) {
                on_failure("Composition surface creation failed");
                return S_OK;
              }

              RegisterTexture();

              ApplySettings(initial_settings_);

              EventRegistrationToken token;
              webview_->add_WebMessageReceived(
                  Microsoft::WRL::Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                      [this](ICoreWebView2* sender,
                             ICoreWebView2WebMessageReceivedEventArgs* args)
                          -> HRESULT {
                        LPWSTR message = nullptr;
                        args->TryGetWebMessageAsString(&message);
                        std::wstring raw = message ? message : L"";
                        if (message) CoTaskMemFree(message);
                        HandleWebMessage(raw);
                        return S_OK;
                      })
                      .Get(),
                  &token);

              webview_->add_NavigationStarting(
                  Microsoft::WRL::Callback<ICoreWebView2NavigationStartingEventHandler>(
                      [this](ICoreWebView2* sender,
                             ICoreWebView2NavigationStartingEventArgs* args)
                          -> HRESULT {
                        if (is_navigating_internally_) {
                          is_navigating_internally_ = false;

                          LPWSTR uri = nullptr;
                          args->get_Uri(&uri);
                          std::string url = WideToUtf8(uri);
                          if (uri) CoTaskMemFree(uri);

                          channel_->InvokeMethod(
                              "onLoadStart",
                              std::make_unique<EncodableValue>(url));
                          return S_OK;
                        }

                        LPWSTR uri = nullptr;
                        args->get_Uri(&uri);
                        std::string url = WideToUtf8(uri);
                        if (uri) CoTaskMemFree(uri);

                        args->put_Cancel(TRUE);
                        channel_->InvokeMethod(
                            "onNavigationRequest",
                            std::make_unique<EncodableValue>(url),
                            std::make_unique<
                                flutter::MethodResultFunctions<EncodableValue>>(
                                [this, url](const EncodableValue* r) {
                                  bool allow =
                                      r && std::holds_alternative<bool>(*r)
                                          ? std::get<bool>(*r)
                                          : true;
                                  if (allow && webview_) {
                                    is_navigating_internally_ = true;
                                    webview_->Navigate(Utf8ToWide(url).c_str());
                                  }
                                },
                                nullptr, nullptr));
                        return S_OK;
                      })
                      .Get(),
                  &token);

              webview_->add_NavigationCompleted(
                  Microsoft::WRL::Callback<ICoreWebView2NavigationCompletedEventHandler>(
                      [this](ICoreWebView2* sender,
                             ICoreWebView2NavigationCompletedEventArgs* args)
                          -> HRESULT {
                        BOOL success = TRUE;
                        args->get_IsSuccess(&success);

                        LPWSTR uri = nullptr;
                        if (webview_) webview_->get_Source(&uri);
                        std::string url = uri ? WideToUtf8(uri) : std::string();
                        if (uri) CoTaskMemFree(uri);

                        if (success) {
                          channel_->InvokeMethod(
                              "onLoadStop",
                              std::make_unique<EncodableValue>(url));
                        } else {
                          COREWEBVIEW2_WEB_ERROR_STATUS status =
                              COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
                          args->get_WebErrorStatus(&status);

                          EncodableMap error_map;
                          error_map[EncodableValue("url")] = EncodableValue(url);
                          error_map[EncodableValue("code")] =
                              EncodableValue(static_cast<int32_t>(status));
                          error_map[EncodableValue("description")] =
                              EncodableValue(std::string(
                                  "Erreur de navigation WebView2"));
                          channel_->InvokeMethod(
                              "onReceivedError",
                              std::make_unique<EncodableValue>(
                                  EncodableValue(error_map)));
                        }
                        return S_OK;
                      })
                      .Get(),
                  &token);

              Microsoft::WRL::ComPtr<ICoreWebView2_2> webview2;
              if (SUCCEEDED(webview_.As(&webview2)) && webview2) {
                EventRegistrationToken dcl_token;
                webview2->add_DOMContentLoaded(
                    Microsoft::WRL::Callback<ICoreWebView2DOMContentLoadedEventHandler>(
                        [this](ICoreWebView2* sender,
                                ICoreWebView2DOMContentLoadedEventArgs* args)
                            -> HRESULT {
                          LPWSTR uri = nullptr;
                          if (webview_) webview_->get_Source(&uri);
                          std::string url = uri ? WideToUtf8(uri) : std::string();
                          if (uri) CoTaskMemFree(uri);

                          channel_->InvokeMethod(
                              "onDOMContentLoaded",
                              std::make_unique<EncodableValue>(url));
                          return S_OK;
                        })
                        .Get(),
                    &dcl_token);
              }

              Microsoft::WRL::ComPtr<ICoreWebView2_11> webview11;
              if (SUCCEEDED(webview_.As(&webview11)) && webview11) {
                EventRegistrationToken cm_token;
                webview11->add_ContextMenuRequested(
                    Microsoft::WRL::Callback<
                        ICoreWebView2ContextMenuRequestedEventHandler>(
                        [this](ICoreWebView2* sender,
                               ICoreWebView2ContextMenuRequestedEventArgs* args)
                            -> HRESULT {
                          if (disable_context_menu_) {
                            args->put_Handled(TRUE);
                            return S_OK;
                          }
                          if (!disable_long_press_links_) return S_OK;

                          Microsoft::WRL::ComPtr<ICoreWebView2ContextMenuTarget>
                              target;
                          args->get_ContextMenuTarget(&target);
                          if (target) {
                            BOOL has_link = FALSE;
                            target->get_HasLinkUri(&has_link);
                            if (has_link) {
                              args->put_Handled(TRUE);
                            }
                          }
                          return S_OK;
                        })
                        .Get(),
                    &cm_token);
              }

              InjectBridgeScript();

              if (!initial_asset_.empty()) {
                LoadFlutterAsset(initial_asset_);
              } else if (!initial_file_.empty()) {
                LoadFile(Utf8ToWide(initial_file_));
              } else if (!initial_url_.empty()) {
                is_navigating_internally_ = true;
                webview_->Navigate(Utf8ToWide(initial_url_).c_str());
              }

              if (on_ready_) {
                on_ready_(texture_id_);
              }
              return S_OK;
            })
            .Get());
  };

  if (user_data_folder_.empty() && g_environment) {
    init_controller(g_environment);
    return;
  }

  std::wstring u_data_dir = user_data_folder_.empty() ? L"" : Utf8ToWide(user_data_folder_);

  CreateCoreWebView2EnvironmentWithOptions(
      nullptr, 
      u_data_dir.empty() ? nullptr : u_data_dir.c_str(),
      nullptr,
      Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [init_controller, on_failure, u_data_dir](HRESULT result,
                                          ICoreWebView2Environment* env)
              -> HRESULT {
            if (!env) {
              on_failure("WebView2 environment creation failed");
              return S_OK;
            }

            Microsoft::WRL::ComPtr<ICoreWebView2Environment3> env3;
            if (FAILED(env->QueryInterface(IID_PPV_ARGS(&env3))) || !env3) {
              on_failure("ICoreWebView2Environment3 unavailable");
              return S_OK;
            }

            if (u_data_dir.empty()) {
              g_environment = env3;
            }

            init_controller(env3);
            return S_OK;
          })
          .Get());
}

void WebViewPlusInstance::ApplySettings(const EncodableMap& settings) {
  if (!webview_) return;

  Microsoft::WRL::ComPtr<ICoreWebView2Settings> core_settings;
  webview_->get_Settings(&core_settings);
  if (!core_settings) return;

  core_settings->put_IsScriptEnabled(
      GetBoolOr(settings, "javaScriptEnabled", true) ? TRUE : FALSE);

  disable_context_menu_ = GetBoolOr(settings, "disableContextMenu", false);
  core_settings->put_AreDefaultContextMenusEnabled(
      disable_context_menu_ ? FALSE : TRUE);

  disable_long_press_links_ =
      GetBoolOr(settings, "disableLongPressContextMenuOnLinks", false);

  core_settings->put_AreDevToolsEnabled(
      GetBoolOr(settings, "isInspectable", false) ? TRUE : FALSE);

  core_settings->put_IsZoomControlEnabled(
      GetBoolOr(settings, "supportZoom", true) ? TRUE : FALSE);

  if (const auto* ua = FindKey(settings, "userAgent")) {
    if (auto ua_str = std::get_if<std::string>(ua)) {
      Microsoft::WRL::ComPtr<ICoreWebView2Settings2> settings2;
      if (SUCCEEDED(core_settings.As(&settings2)) && settings2) {
        settings2->put_UserAgent(Utf8ToWide(*ua_str).c_str());
      }
    }
  }

  if (GetBoolOr(settings, "transparentBackground", false) && controller_) {
    COREWEBVIEW2_COLOR transparent{0, 0, 0, 0};
    controller_->put_DefaultBackgroundColor(transparent);
  }

  selection_css_color_ = ArgbToCssRgbaOr(settings, "selectionHandleColor");
  selection_text_css_color_ = ArgbToCssRgbaOr(settings, "selectionHandleColor");

  disable_link_hover_preview_ =
      GetBoolOr(settings, "disableLinkHoverPreview", true);
  core_settings->put_IsStatusBarEnabled(disable_link_hover_preview_ ? FALSE
                                                                     : TRUE);

  disable_printing_ = GetBoolOr(settings, "disablePrinting", false);

  // `initialUserScripts` : voir `ParseUserScripts` (helpers ci-dessus) et
  // `InjectBridgeScript` (utilisation). `user_scripts_at_start_` /
  // `user_scripts_at_end_` doivent être déclarés côté header de la classe,
  // en `std::vector<std::wstring>`, au même titre que
  // `selection_css_color_`.
  ParseUserScripts(settings, &user_scripts_at_start_, &user_scripts_at_end_);
}

void WebViewPlusInstance::InjectBridgeScript() {
  std::wstring css_block;
  if (!selection_css_color_.empty() || !selection_text_css_color_.empty()) {
    std::wstring background_rule = selection_css_color_.empty()
        ? L""
        : L"background:" + selection_css_color_ + L";";
    std::wstring color_rule = selection_text_css_color_.empty()
        ? L""
        : L"color:" + selection_text_css_color_ + L";";
    css_block =
        L"document.addEventListener('DOMContentLoaded', function(){"
        L"var st=document.createElement('style');"
        L"st.innerHTML='::selection{" +
        background_rule + color_rule +
        L"}';"
        L"(document.head||document.documentElement).appendChild(st);});";
  }

  std::wstring print_block;
  if (disable_printing_) {
    print_block = L"window.print=function(){};";
  }

  // `initialUserScripts` en atDocumentStart : exécutés à chaque création de
  // document (avant même `if(window.webview_plus) return;`, pour qu'ils
  // s'exécutent à chaque navigation et pas uniquement à la première).
  std::wstring start_user_scripts_block;
  for (const auto& source : user_scripts_at_start_) {
    start_user_scripts_block += L"(function(){" + source + L"})();";
  }

  // `initialUserScripts` en atDocumentEnd : exécutés juste après
  // DOMContentLoaded, avant la notification `onDOMContentLoaded` (le canal
  // Dart, lui, est notifié séparément via l'évènement natif
  // `add_DOMContentLoaded` de WebView2 — voir plus haut dans ce fichier).
  std::wstring end_user_scripts_block;
  for (const auto& source : user_scripts_at_end_) {
    end_user_scripts_block += L"(function(){" + source + L"})();";
  }
  if (!end_user_scripts_block.empty()) {
    end_user_scripts_block =
        L"document.addEventListener('DOMContentLoaded', function(){" +
        end_user_scripts_block + L"});";
  }

  std::wstring script =
      L"(function(){" +
      start_user_scripts_block +
      L"if(window.webview_plus) return;" +
      css_block + print_block + end_user_scripts_block +
      L"var __fwCbId=0;var __fwCallbacks={};"
      L"window.webview_plus={"
      L"callHandler:function(handlerName){"
      L"var args=Array.prototype.slice.call(arguments,1);"
      L"var id='cb'+(__fwCbId++);"
      L"return new Promise(function(resolve,reject){"
      L"__fwCallbacks[id]={resolve:resolve,reject:reject};"
      L"window.chrome.webview.postMessage('__FW_HANDLER__:'+handlerName+':'+id+':'+JSON.stringify(args));"
      L"});},"
      L"_resolveCallback:function(id,result){var cb=__fwCallbacks[id];if(cb){cb.resolve(result);delete __fwCallbacks[id];}},"
      L"_rejectCallback:function(id,error){var cb=__fwCallbacks[id];if(cb){cb.reject(error);delete __fwCallbacks[id];}}"
      L"};"
      L"window.WebViewPlusChannel={postMessage:function(msg){window.chrome.webview.postMessage(msg);}};"
      L"})();";

  if (webview_) {
    webview_->AddScriptToExecuteOnDocumentCreated(script.c_str(), nullptr);
  }
}

void WebViewPlusInstance::HandleWebMessage(const std::wstring& raw) {
  const std::wstring prefix = L"__FW_HANDLER__:";
  if (raw.rfind(prefix, 0) == 0) {
    std::wstring rest = raw.substr(prefix.size());
    size_t p1 = rest.find(L':');
    if (p1 == std::wstring::npos) return;
    std::wstring handler_name = rest.substr(0, p1);

    size_t p2 = rest.find(L':', p1 + 1);
    if (p2 == std::wstring::npos) return;
    std::wstring callback_id = rest.substr(p1 + 1, p2 - p1 - 1);
    std::wstring args_json = rest.substr(p2 + 1);

    EncodableMap payload;
    payload[EncodableValue(std::string("handlerName"))] =
        EncodableValue(WideToUtf8(handler_name));
    payload[EncodableValue(std::string("args"))] =
        EncodableValue(WideToUtf8(args_json));

    channel_->InvokeMethod(
        "onJavaScriptHandler",
        std::make_unique<EncodableValue>(EncodableValue(payload)),
        std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
            [this, callback_id](const EncodableValue* r) {
              std::wstring json =
                  r ? EncodableValueToJsonLiteral(*r) : L"null";
              std::wstring script =
                  L"window.webview_plus && window.webview_plus._resolveCallback('" +
                  callback_id + L"', " + json + L");";
              if (webview_) webview_->ExecuteScript(script.c_str(), nullptr);
            },
            [this, callback_id](const std::string& error_code,
                                 const std::string& error_message,
                                 const EncodableValue* error_details) {
              std::wstring json = EncodableValueToJsonLiteral(
                  EncodableValue(error_message.empty() ? error_code
                                                        : error_message));
              std::wstring script =
                  L"window.webview_plus && window.webview_plus._rejectCallback('" +
                  callback_id + L"', " + json + L");";
              if (webview_) webview_->ExecuteScript(script.c_str(), nullptr);
            },
            nullptr));
    return;
  }

  channel_->InvokeMethod("onMessageReceived",
                          std::make_unique<EncodableValue>(WideToUtf8(raw)));
}

std::wstring WebViewPlusInstance::EscapeJsonString(const std::wstring& s) {
  std::wstring out;
  out.reserve(s.size() + 8);
  for (wchar_t c : s) {
    switch (c) {
      case L'"':
        out += L"\\\"";
        break;
      case L'\\':
        out += L"\\\\";
        break;
      case L'\n':
        out += L"\\n";
        break;
      case L'\r':
        out += L"\\r";
        break;
      case L'\t':
        out += L"\\t";
        break;
      default:
        out += c;
    }
  }
  return out;
}

std::wstring WebViewPlusInstance::EncodableValueToJsonLiteral(
    const EncodableValue& value) {
  if (std::holds_alternative<std::monostate>(value)) return L"null";
  if (auto b = std::get_if<bool>(&value)) return *b ? L"true" : L"false";
  if (auto i = std::get_if<int32_t>(&value)) return std::to_wstring(*i);
  if (auto i64 = std::get_if<int64_t>(&value)) return std::to_wstring(*i64);
  if (auto d = std::get_if<double>(&value)) return std::to_wstring(*d);
  if (auto s = std::get_if<std::string>(&value)) {
    return L"\"" + EscapeJsonString(Utf8ToWide(*s)) + L"\"";
  }
  if (auto list = std::get_if<EncodableList>(&value)) {
    std::wstring out = L"[";
    for (size_t idx = 0; idx < list->size(); ++idx) {
      if (idx > 0) out += L",";
      out += EncodableValueToJsonLiteral((*list)[idx]);
    }
    out += L"]";
    return out;
  }
  if (auto map = std::get_if<EncodableMap>(&value)) {
    std::wstring out = L"{";
    bool first = true;
    for (const auto& kv : *map) {
      if (!first) out += L",";
      first = false;
      auto key = std::get_if<std::string>(&kv.first);
      out += L"\"" + EscapeJsonString(Utf8ToWide(key ? *key : std::string())) +
             L"\":";
      out += EncodableValueToJsonLiteral(kv.second);
    }
    out += L"}";
    return out;
  }
  return L"null";
}

std::wstring WebViewPlusInstance::DecodeJsonStringResult(
    const std::wstring& raw) {
  if (raw.empty() || raw == L"null") return L"";
  std::wstring s = raw;
  if (s.size() >= 2 && s.front() == L'"' && s.back() == L'"') {
    s = s.substr(1, s.size() - 2);
  }
  std::wstring out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size(); ++i) {
    if (s[i] == L'\\' && i + 1 < s.size()) {
      wchar_t next = s[i + 1];
      switch (next) {
        case L'"':
          out += L'"';
          ++i;
          break;
        case L'\\':
          out += L'\\';
          ++i;
          break;
        case L'n':
          out += L'\n';
          ++i;
          break;
        case L'r':
          out += L'\r';
          ++i;
          break;
        case L't':
          out += L'\t';
          ++i;
          break;
        default:
          out += s[i];
      }
    } else {
      out += s[i];
    }
  }
  return out;
}

flutter::EncodableValue WebViewPlusInstance::ParseJsonToEncodableValue(
    const std::wstring& json) {
  if (json.empty()) return EncodableValue();
  JsonParser parser(json);
  return parser.Parse();
}

std::wstring WebViewPlusInstance::GetExecutableDir() {
  wchar_t path[MAX_PATH];
  GetModuleFileNameW(nullptr, path, MAX_PATH);
  std::wstring full(path);
  size_t pos = full.find_last_of(L"\\/");
  return pos == std::wstring::npos ? L"" : full.substr(0, pos);
}

std::wstring WebViewPlusInstance::BuildAssetUrl(
    const std::string& asset_path) {
  std::wstring full = GetExecutableDir() + L"\\data\\flutter_assets\\" +
                      Utf8ToWide(asset_path);
  for (auto& c : full) {
    if (c == L'\\') c = L'/';
  }
  return L"file:///" + full;
}

void WebViewPlusInstance::LoadUrl(const std::wstring& url) {
  if (webview_) {
    is_navigating_internally_ = true;
    webview_->Navigate(url.c_str());
  }
}

void WebViewPlusInstance::LoadFlutterAsset(const std::string& asset_path) {
  if (!webview_) return;
  is_navigating_internally_ = true;
  webview_->Navigate(BuildAssetUrl(asset_path).c_str());
}

void WebViewPlusInstance::LoadFile(const std::wstring& path) {
  if (!webview_) return;
  std::wstring uri = path;
  bool already_uri = uri.rfind(L"file://", 0) == 0 ||
                      uri.rfind(L"http://", 0) == 0 ||
                      uri.rfind(L"https://", 0) == 0;
  if (!already_uri) {
    std::wstring normalized = path;
    for (auto& c : normalized) {
      if (c == L'\\') c = L'/';
    }
    uri = L"file:///" + normalized;
  }
  is_navigating_internally_ = true;
  webview_->Navigate(uri.c_str());
}

void WebViewPlusInstance::LoadHtmlOrData(const std::wstring& html) {
  if (!webview_) return;
  is_navigating_internally_ = true;
  webview_->NavigateToString(html.c_str());
}

void WebViewPlusInstance::GetHtml(
    std::function<void(std::wstring)> callback) {
  EvaluateJavaScript(L"document.documentElement.outerHTML",
                      [callback](std::wstring raw) {
                        callback(DecodeJsonStringResult(raw));
                      });
}

void WebViewPlusInstance::InjectScriptFromUrl(const std::wstring& url) {
  if (!webview_) return;
  std::wstring js =
      L"(function(){var s=document.createElement('script');s.src=\"" +
      EscapeJsonString(url) +
      L"\";(document.head||document.documentElement).appendChild(s);})();";
  webview_->ExecuteScript(js.c_str(), nullptr);
}

void WebViewPlusInstance::InjectCssFromUrl(const std::wstring& url) {
  if (!webview_) return;
  std::wstring js =
      L"(function(){var l=document.createElement('link');l.rel='stylesheet';l.href=\"" +
      EscapeJsonString(url) +
      L"\";(document.head||document.documentElement).appendChild(l);})();";
  webview_->ExecuteScript(js.c_str(), nullptr);
}

void WebViewPlusInstance::EvaluateJavaScript(
    const std::wstring& code, std::function<void(std::wstring)> callback) {
  if (!webview_) {
    callback(L"");
    return;
  }
  webview_->ExecuteScript(
      code.c_str(),
      Microsoft::WRL::Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
          [callback](HRESULT error, LPCWSTR result) -> HRESULT {
            callback(result ? result : L"");
            return S_OK;
          })
          .Get());
}

void WebViewPlusInstance::SetSize(double width, double height,
                                     double scale_factor) {
  if (!controller_ || !surface_visual_ || width <= 0 || height <= 0) {
    return;
  }

  scale_factor_ = static_cast<float>(scale_factor);
  const auto scaled_width = static_cast<float>(width * scale_factor);
  const auto scaled_height = static_cast<float>(height * scale_factor);

  RECT bounds;
  bounds.left = 0;
  bounds.top = 0;
  bounds.right = static_cast<LONG>(scaled_width);
  bounds.bottom = static_cast<LONG>(scaled_height);

  surface_visual_->put_Size({scaled_width, scaled_height});
  controller_->put_RasterizationScale(scale_factor_);
  controller_->put_Bounds(bounds);

  if (texture_bridge_) {
    texture_bridge_->NotifySurfaceSizeChanged();
    texture_bridge_->Start();
  }
}

void WebViewPlusInstance::SetCursorPos(double x, double y) {
  if (!composition_controller_) return;

  POINT point;
  point.x = static_cast<LONG>(x * scale_factor_);
  point.y = static_cast<LONG>(y * scale_factor_);
  last_cursor_pos_ = point;

  composition_controller_->SendMouseInput(
      COREWEBVIEW2_MOUSE_EVENT_KIND_MOVE, virtual_keys_.state(), 0, point);
}

void WebViewPlusInstance::SetPointerButtonState(int button, bool is_down) {
  if (!composition_controller_) return;

  COREWEBVIEW2_MOUSE_EVENT_KIND kind;
  switch (button) {
    case 1:
      virtual_keys_.set_isLeftButtonDown(is_down);
      kind = is_down ? COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_DOWN
                     : COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_UP;
      break;
    case 2:
      virtual_keys_.set_isRightButtonDown(is_down);
      kind = is_down ? COREWEBVIEW2_MOUSE_EVENT_KIND_RIGHT_BUTTON_DOWN
                     : COREWEBVIEW2_MOUSE_EVENT_KIND_RIGHT_BUTTON_UP;
      break;
    case 4:
      virtual_keys_.set_isMiddleButtonDown(is_down);
      kind = is_down ? COREWEBVIEW2_MOUSE_EVENT_KIND_MIDDLE_BUTTON_DOWN
                     : COREWEBVIEW2_MOUSE_EVENT_KIND_MIDDLE_BUTTON_UP;
      break;
    default:
      return;
  }

  composition_controller_->SendMouseInput(kind, virtual_keys_.state(), 0,
                                          last_cursor_pos_);
}

void WebViewPlusInstance::SendScroll(double delta, bool horizontal) {
  auto& remainder =
      horizontal ? horizontal_scroll_remainder_ : vertical_scroll_remainder_;
  const auto native_delta =
      (delta / GetFlutterScrollOffsetMultiplier()) * WHEEL_DELTA + remainder;
  auto wheel_delta = static_cast<long>(std::round(native_delta));
  remainder = native_delta - static_cast<double>(wheel_delta);

  if (wheel_delta == 0 || !composition_controller_) {
    return;
  }

  wheel_delta = std::clamp<long>(
      wheel_delta, (std::numeric_limits<short>::min)(),
      (std::numeric_limits<short>::max)());
  auto offset = static_cast<short>(wheel_delta);

  if (horizontal) {
    composition_controller_->SendMouseInput(
        COREWEBVIEW2_MOUSE_EVENT_KIND_HORIZONTAL_WHEEL, virtual_keys_.state(),
        offset, last_cursor_pos_);
  } else {
    composition_controller_->SendMouseInput(
        COREWEBVIEW2_MOUSE_EVENT_KIND_WHEEL, virtual_keys_.state(), offset,
        last_cursor_pos_);
  }
}

void WebViewPlusInstance::SetScrollDelta(double dx, double dy) {
  if (dx != 0.0) {
    SendScroll(dx, true);
  }
  if (dy != 0.0) {
    SendScroll(dy, false);
  }
}

void WebViewPlusInstance::NotifyWindowMoved() {
  if (controller_) {
    controller_->NotifyParentWindowPositionChanged();
  }
}

// Best-effort : WebView2 ne renvoie qu'un HCURSOR brut (pas de "type"
// symbolique), donc on le compare aux curseurs système standards chargés
// une seule fois. Couvre les cas les plus courants (lien, texte, resize,
// etc.) ; tout curseur non reconnu (ex. curseur CSS personnalisé) retombe
// sur "basic".
std::string WebViewPlusInstance::CursorKindFromHandle(HCURSOR cursor) {
  static const HCURSOR kArrow = LoadCursor(nullptr, IDC_ARROW);
  static const HCURSOR kHand = LoadCursor(nullptr, IDC_HAND);
  static const HCURSOR kIBeam = LoadCursor(nullptr, IDC_IBEAM);
  static const HCURSOR kWait = LoadCursor(nullptr, IDC_WAIT);
  static const HCURSOR kCross = LoadCursor(nullptr, IDC_CROSS);
  static const HCURSOR kSizeWE = LoadCursor(nullptr, IDC_SIZEWE);
  static const HCURSOR kSizeNS = LoadCursor(nullptr, IDC_SIZENS);
  static const HCURSOR kSizeNWSE = LoadCursor(nullptr, IDC_SIZENWSE); // Diagonale haut-gauche / bas-droite (\)
  static const HCURSOR kSizeNESW = LoadCursor(nullptr, IDC_SIZENESW); // Diagonale haut-droite / bas-gauche (/)
  static const HCURSOR kSizeAll = LoadCursor(nullptr, IDC_SIZEALL);
  static const HCURSOR kNo = LoadCursor(nullptr, IDC_NO);

  if (!cursor) return "basic";
  if (cursor == kHand) return "click";
  if (cursor == kIBeam) return "text";
  if (cursor == kWait) return "wait";
  if (cursor == kCross) return "precise";
  if (cursor == kSizeWE) return "resizeLeftRight";
  if (cursor == kSizeNS) return "resizeUpDown";
  if (cursor == kSizeNWSE) return "resizeUpLeftDownRight";
  if (cursor == kSizeNESW) return "resizeUpRightDownLeft";
  if (cursor == kSizeAll) return "allScroll";
  if (cursor == kNo) return "forbidden";
  if (cursor == kArrow) return "basic";
  
  return "basic";
}

void WebViewPlusPluginCApi::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<WebViewPlusPluginCApi>(registrar);

  auto global_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "plugins.noam.me/webview_plus_windows",
      &flutter::StandardMethodCodec::GetInstance());

  global_channel->SetMethodCallHandler(
      [registrar](const MethodCall<EncodableValue>& call,
                  std::unique_ptr<MethodResult<EncodableValue>> result) {
        const std::string& method = call.method_name();
        const auto* args = std::get_if<EncodableMap>(call.arguments());

        if (!args) {
          result->Error("Bad arguments", "Expected Map");
          return;
        }

        auto id_it = args->find(EncodableValue(std::string("viewId")));
        if (id_it == args->end()) {
          result->Error("Bad arguments", "Missing viewId");
          return;
        }
        int64_t view_id = GetLongValue(id_it->second);

        if (method == "create") {
          if (!EnsurePlatform()) {
            result->Error("unsupported_platform",
                          "Texture-based WebView2 is not supported on this "
                          "system.");
            return;
          }

          auto url_it = args->find(EncodableValue(std::string("initialUrl")));
          std::string initial_url =
              (url_it != args->end() &&
               std::holds_alternative<std::string>(url_it->second))
                  ? std::get<std::string>(url_it->second)
                  : "";

          auto asset_it = args->find(EncodableValue(std::string("initialAsset")));
          std::string initial_asset =
              (asset_it != args->end() &&
               std::holds_alternative<std::string>(asset_it->second))
                  ? std::get<std::string>(asset_it->second)
                  : "";

          auto file_it = args->find(EncodableValue(std::string("initialFile")));
          std::string initial_file =
              (file_it != args->end() &&
               std::holds_alternative<std::string>(file_it->second))
                  ? std::get<std::string>(file_it->second)
                  : "";
          
          auto udf_it = args->find(EncodableValue(std::string("userDataFolder")));
          std::string user_data_folder =
              (udf_it != args->end() &&
               std::holds_alternative<std::string>(udf_it->second))
                  ? std::get<std::string>(udf_it->second)
                  : "";

          EncodableMap initial_settings;
          auto settings_it =
              args->find(EncodableValue(std::string("initialSettings")));
          if (settings_it != args->end()) {
            if (auto m = std::get_if<EncodableMap>(&settings_it->second)) {
              initial_settings = *m;
            }
          }

          HWND top_level_hwnd =
              registrar->GetView() ? registrar->GetView()->GetNativeWindow()
                                   : nullptr;
          if (!top_level_hwnd) {
            result->Error("creation_failed",
                          "Native top-level window unavailable");
            return;
          }
          EnsureWindowSubclassed(top_level_hwnd);

          HWND message_hwnd = CreateMessageWindow(top_level_hwnd);
          if (!message_hwnd) {
            result->Error("creation_failed", "Failed to create message window");
            return;
          }

          auto shared_result =
              std::make_shared<std::unique_ptr<MethodResult<EncodableValue>>>(
                  std::move(result));

          auto instance = std::make_unique<WebViewPlusInstance>(
              registrar, g_platform.get(), message_hwnd, view_id, initial_url,
              initial_asset, initial_file, initial_settings, user_data_folder,
              [shared_result, view_id](int64_t texture_id) {
                EncodableMap response;
                response[EncodableValue("textureId")] =
                    EncodableValue(texture_id);
                response[EncodableValue("viewId")] = EncodableValue(view_id);
                (*shared_result)->Success(EncodableValue(response));
              },
              [shared_result](const std::string& message) {
                (*shared_result)->Error("creation_failed", message);
              });

          g_instances[view_id] = std::move(instance);
        } else if (method == "setSize") {
          auto width_it = args->find(EncodableValue(std::string("width")));
          auto height_it = args->find(EncodableValue(std::string("height")));
          auto scale_it =
              args->find(EncodableValue(std::string("scaleFactor")));

          if (width_it != args->end() && height_it != args->end()) {
            double width = GetDoubleValue(width_it->second);
            double height = GetDoubleValue(height_it->second);
            double scale = scale_it != args->end() ? GetDoubleValue(scale_it->second) : 1.0;

            auto it = g_instances.find(view_id);
            if (it != g_instances.end()) {
              it->second->SetSize(width, height, scale);
            }
          }
          result->Success();
        } else if (method == "setCursorPos") {
          auto x_it = args->find(EncodableValue(std::string("x")));
          auto y_it = args->find(EncodableValue(std::string("y")));
          if (x_it != args->end() && y_it != args->end()) {
            auto it = g_instances.find(view_id);
            if (it != g_instances.end()) {
              it->second->SetCursorPos(GetDoubleValue(x_it->second), GetDoubleValue(y_it->second));
            }
          }
          result->Success();
        } else if (method == "setPointerButton") {
          auto button_it = args->find(EncodableValue(std::string("button")));
          auto is_down_it = args->find(EncodableValue(std::string("isDown")));
          if (button_it != args->end() && is_down_it != args->end()) {
            auto it = g_instances.find(view_id);
            if (it != g_instances.end()) {
              bool is_down = false;
              if (auto b = std::get_if<bool>(&is_down_it->second)) {
                is_down = *b;
              }
              it->second->SetPointerButtonState(static_cast<int>(GetLongValue(button_it->second)), is_down);
            }
          }
          result->Success();
        } else if (method == "setScrollDelta") {
          auto dx_it = args->find(EncodableValue(std::string("dx")));
          auto dy_it = args->find(EncodableValue(std::string("dy")));
          if (dx_it != args->end() && dy_it != args->end()) {
            auto it = g_instances.find(view_id);
            if (it != g_instances.end()) {
              it->second->SetScrollDelta(GetDoubleValue(dx_it->second), GetDoubleValue(dy_it->second));
            }
          }
          result->Success();
        } else if (method == "dispose") {
          g_instances.erase(view_id);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  registrar->AddPlugin(std::move(plugin));
}

WebViewPlusPluginCApi::WebViewPlusPluginCApi(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

WebViewPlusPluginCApi::~WebViewPlusPluginCApi() {}

}  // namespace webview_plus