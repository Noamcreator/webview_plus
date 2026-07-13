#include "platform/webview_platform.h"

#include <DispatcherQueue.h>
#include <windows.graphics.capture.h>

#include "util/logging.h"

namespace webview_plus {

WebviewPlatform::WebviewPlatform()
    : runtime_(std::make_unique<WinrtRuntime>(RO_INIT_SINGLETHREADED)) {
  if (runtime_->available()) {
    DispatcherQueueOptions options{sizeof(DispatcherQueueOptions),
                                   DQTYPE_THREAD_CURRENT, DQTAT_COM_STA};

    if (FAILED(runtime_->CreateDispatcherQueueController(
            options, dispatcher_queue_controller_.GetAddressOf()))) {
      util::LogWarning("Creating DispatcherQueueController failed.");
      return;
    }

    if (!IsGraphicsCaptureSessionSupported()) {
      util::LogWarning(
          "Windows::Graphics::Capture::GraphicsCaptureSession is not "
          "supported.");
      return;
    }

    graphics_context_ = std::make_unique<GraphicsContext>(runtime_.get());
    if (!graphics_context_->IsValid()) {
      return;
    }

    compositor_ = graphics_context_->CreateCompositor();
    if (!compositor_) {
      return;
    }

    valid_ = true;
  }
}

bool WebviewPlatform::IsGraphicsCaptureSessionSupported() {
  HSTRING class_name;
  HSTRING_HEADER class_name_header;

  if (FAILED(runtime_->CreateStringReference(
          RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureSession,
          &class_name, &class_name_header))) {
    return false;
  }

  ABI::Windows::Graphics::Capture::IGraphicsCaptureSessionStatics*
      capture_session_statics;
  if (FAILED(runtime_->GetActivationFactory(
          class_name,
          __uuidof(
              ABI::Windows::Graphics::Capture::IGraphicsCaptureSessionStatics),
          reinterpret_cast<void**>(&capture_session_statics)))) {
    return false;
  }

  boolean is_supported = false;
  if (FAILED(capture_session_statics->IsSupported(&is_supported))) {
    return false;
  }

  return !!is_supported;
}

}  // namespace webview_plus
