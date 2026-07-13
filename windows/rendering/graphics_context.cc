#include "rendering/graphics_context.h"

#include "util/d3dutil.h"
#include "util/direct3d11.interop.h"

namespace webview_plus {

GraphicsContext::GraphicsContext(WinrtRuntime* runtime) : runtime_(runtime) {
  device_ = util::CreateD3DDevice();
  if (!device_) {
    return;
  }

  device_->GetImmediateContext(device_context_.GetAddressOf());
  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
  if (FAILED(device_.As(&dxgi_device))) {
    return;
  }

  Microsoft::WRL::ComPtr<IInspectable> inspectable;
  if (FAILED(util::CreateDirect3D11DeviceFromDXGIDevice(
          dxgi_device.Get(), inspectable.GetAddressOf()))) {
    return;
  }

  if (FAILED(inspectable.As(&device_winrt_))) {
    return;
  }

  valid_ = true;
}

Microsoft::WRL::ComPtr<ABI::Windows::UI::Composition::ICompositor>
GraphicsContext::CreateCompositor() {
  HSTRING class_name;
  HSTRING_HEADER class_name_header;

  if (FAILED(runtime_->CreateStringReference(
          RuntimeClass_Windows_UI_Composition_Compositor, &class_name,
          &class_name_header))) {
    return nullptr;
  }

  Microsoft::WRL::ComPtr<IActivationFactory> activation_factory;
  if (FAILED(runtime_->GetActivationFactory(
          class_name, __uuidof(IActivationFactory),
          reinterpret_cast<void**>(activation_factory.GetAddressOf())))) {
    return nullptr;
  }

  Microsoft::WRL::ComPtr<ABI::Windows::UI::Composition::ICompositor> compositor;
  if (FAILED(activation_factory->ActivateInstance(
          reinterpret_cast<IInspectable**>(compositor.GetAddressOf())))) {
    return nullptr;
  }

  return compositor;
}

Microsoft::WRL::ComPtr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>
GraphicsContext::CreateGraphicsCaptureItemFromVisual(
    ABI::Windows::UI::Composition::IVisual* visual) const {
  HSTRING class_name;
  HSTRING_HEADER class_name_header;

  if (FAILED(runtime_->CreateStringReference(
          RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureItem, &class_name,
          &class_name_header))) {
    return nullptr;
  }

  ABI::Windows::Graphics::Capture::IGraphicsCaptureItemStatics*
      capture_item_statics;
  if (FAILED(runtime_->GetActivationFactory(
          class_name,
          __uuidof(
              ABI::Windows::Graphics::Capture::IGraphicsCaptureItemStatics),
          reinterpret_cast<void**>(&capture_item_statics)))) {
    return nullptr;
  }

  Microsoft::WRL::ComPtr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>
      capture_item;
  if (FAILED(capture_item_statics->CreateFromVisual(visual,
                                                    capture_item.GetAddressOf()))) {
    return nullptr;
  }

  return capture_item;
}

Microsoft::WRL::ComPtr<
    ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
GraphicsContext::CreateCaptureFramePool(
    ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice* device,
    ABI::Windows::Graphics::DirectX::DirectXPixelFormat pixel_format,
    INT32 number_of_buffers, ABI::Windows::Graphics::SizeInt32 size) const {
  HSTRING class_name;
  HSTRING_HEADER class_name_header;

  if (FAILED(runtime_->CreateStringReference(
          RuntimeClass_Windows_Graphics_Capture_Direct3D11CaptureFramePool,
          &class_name, &class_name_header))) {
    return nullptr;
  }

  ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePoolStatics*
      capture_frame_pool_statics;
  if (FAILED(runtime_->GetActivationFactory(
          class_name,
          __uuidof(ABI::Windows::Graphics::Capture::
                       IDirect3D11CaptureFramePoolStatics),
          reinterpret_cast<void**>(&capture_frame_pool_statics)))) {
    return nullptr;
  }

  Microsoft::WRL::ComPtr<
      ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
      capture_frame_pool;
  if (FAILED(capture_frame_pool_statics->Create(
          device, pixel_format, number_of_buffers, size,
          capture_frame_pool.GetAddressOf()))) {
    return nullptr;
  }

  return capture_frame_pool;
}

}  // namespace webview_plus
