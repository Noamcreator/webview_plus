#pragma once

#include <D3d11.h>
#include <windows.graphics.capture.h>
#include <windows.ui.composition.h>
#include <wrl.h>

#include "platform/winrt_runtime.h"

namespace webview_plus {

class GraphicsContext {
 public:
  explicit GraphicsContext(WinrtRuntime* runtime);

  inline bool IsValid() const { return valid_; }

  ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice* device()
      const {
    return device_winrt_.Get();
  }
  ID3D11Device* d3d_device() const { return device_.Get(); }
  ID3D11DeviceContext* d3d_device_context() const {
    return device_context_.Get();
  }

  Microsoft::WRL::ComPtr<ABI::Windows::UI::Composition::ICompositor>
  CreateCompositor();

  Microsoft::WRL::ComPtr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>
  CreateGraphicsCaptureItemFromVisual(
      ABI::Windows::UI::Composition::IVisual* visual) const;

  Microsoft::WRL::ComPtr<
      ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
  CreateCaptureFramePool(
      ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice* device,
      ABI::Windows::Graphics::DirectX::DirectXPixelFormat pixel_format,
      INT32 number_of_buffers,
      ABI::Windows::Graphics::SizeInt32 size) const;

 private:
  bool valid_ = false;
  WinrtRuntime* runtime_;
  Microsoft::WRL::ComPtr<
      ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice>
      device_winrt_;
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> device_context_;
};

}  // namespace webview_plus
