#pragma once

#include <memory>
#include <optional>
#include <string>
#include <wrl.h>

#include "platform/winrt_runtime.h"
#include "rendering/graphics_context.h"

namespace webview_plus {

class WebviewPlatform {
 public:
  WebviewPlatform();
  bool IsSupported() const { return valid_; }
  GraphicsContext* graphics_context() const { return graphics_context_.get(); }
  WinrtRuntime* runtime() const { return runtime_.get(); }
  Microsoft::WRL::ComPtr<ABI::Windows::UI::Composition::ICompositor>
  compositor() const {
    return compositor_;
  }

 private:
  bool IsGraphicsCaptureSessionSupported();

  std::unique_ptr<WinrtRuntime> runtime_;
  Microsoft::WRL::ComPtr<ABI::Windows::System::IDispatcherQueueController>
      dispatcher_queue_controller_;
  std::unique_ptr<GraphicsContext> graphics_context_;
  Microsoft::WRL::ComPtr<ABI::Windows::UI::Composition::ICompositor>
      compositor_;
  bool valid_ = false;
};

}  // namespace webview_plus
