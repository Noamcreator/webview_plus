#pragma once

#include <windows.graphics.capture.h>
#include <wrl.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <mutex>
#include <optional>

#include "rendering/graphics_context.h"

namespace webview_plus {

struct Size {
  size_t width;
  size_t height;
};

class TextureBridge {
 public:
  typedef std::function<void()> FrameAvailableCallback;
  typedef std::function<void(Size size)> SurfaceSizeChangedCallback;
  typedef std::chrono::duration<double, std::milli> FrameDuration;

  TextureBridge(GraphicsContext* graphics_context,
                ABI::Windows::UI::Composition::IVisual* visual);
  virtual ~TextureBridge();

  bool Start();
  void Stop();

  void SetOnFrameAvailable(FrameAvailableCallback callback) {
    frame_available_ = std::move(callback);
  }

  void SetOnSurfaceSizeChanged(SurfaceSizeChangedCallback callback) {
    surface_size_changed_ = std::move(callback);
  }

  void NotifySurfaceSizeChanged();
  void SetFpsLimit(std::optional<int> max_fps);

 protected:
  bool is_running_ = false;

  const GraphicsContext* graphics_context_;
  std::mutex mutex_;
  std::optional<FrameDuration> frame_duration_ = std::nullopt;

  FrameAvailableCallback frame_available_;
  SurfaceSizeChangedCallback surface_size_changed_;
  std::atomic<bool> needs_update_ = false;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> last_frame_;
  std::optional<std::chrono::high_resolution_clock::time_point>
      last_frame_timestamp_;

  Microsoft::WRL::ComPtr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>
      capture_item_;
  Microsoft::WRL::ComPtr<
      ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
      frame_pool_;
  Microsoft::WRL::ComPtr<ABI::Windows::Graphics::Capture::IGraphicsCaptureSession>
      capture_session_;

  EventRegistrationToken on_closed_token_ = {};
  EventRegistrationToken on_frame_arrived_token_ = {};

  virtual void StopInternal();
  void OnFrameArrived();
  bool ShouldDropFrame();

  static constexpr auto kPixelFormat = ABI::Windows::Graphics::DirectX::
      DirectXPixelFormat::DirectXPixelFormat_B8G8R8A8UIntNormalized;
};

}  // namespace webview_plus
