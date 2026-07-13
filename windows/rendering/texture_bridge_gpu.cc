#include "rendering/texture_bridge_gpu.h"

#include "util/logging.h"

namespace webview_plus {

TextureBridgeGpu::TextureBridgeGpu(
    GraphicsContext* graphics_context,
    ABI::Windows::UI::Composition::IVisual* visual)
    : TextureBridge(graphics_context, visual) {
  surface_descriptor_.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
  surface_descriptor_.format = kFlutterDesktopPixelFormatNone;
}

void TextureBridgeGpu::ProcessFrame(
    Microsoft::WRL::ComPtr<ID3D11Texture2D> src_texture) {
  D3D11_TEXTURE2D_DESC desc;
  src_texture->GetDesc(&desc);

  const auto width = desc.Width;
  const auto height = desc.Height;

  EnsureSurface(width, height);

  auto device_context = graphics_context_->d3d_device_context();
  device_context->CopyResource(surface_.Get(), src_texture.Get());
  device_context->Flush();
}

void TextureBridgeGpu::EnsureSurface(uint32_t width, uint32_t height) {
  if (!surface_ || surface_size_.width != width ||
      surface_size_.height != height) {
    D3D11_TEXTURE2D_DESC dst_desc = {};
    dst_desc.ArraySize = 1;
    dst_desc.MipLevels = 1;
    dst_desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    dst_desc.CPUAccessFlags = 0;
    dst_desc.Format = static_cast<DXGI_FORMAT>(kPixelFormat);
    dst_desc.Width = width;
    dst_desc.Height = height;
    dst_desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    dst_desc.SampleDesc.Count = 1;
    dst_desc.SampleDesc.Quality = 0;
    dst_desc.Usage = D3D11_USAGE_DEFAULT;

    surface_ = nullptr;
    if (!SUCCEEDED(graphics_context_->d3d_device()->CreateTexture2D(
            &dst_desc, nullptr, surface_.GetAddressOf()))) {
      util::LogWarning("Creating intermediate texture failed.");
      return;
    }

    HANDLE shared_handle;
    if (FAILED(surface_.As(&dxgi_surface_)) || !dxgi_surface_) {
      util::LogWarning("Creating DXGI surface failed.");
      return;
    }
    dxgi_surface_->GetSharedHandle(&shared_handle);

    surface_descriptor_.handle = shared_handle;
    surface_descriptor_.width = surface_descriptor_.visible_width = width;
    surface_descriptor_.height = surface_descriptor_.visible_height = height;
    surface_descriptor_.release_context = surface_.Get();
    surface_descriptor_.release_callback = [](void* release_context) {
      auto texture = reinterpret_cast<ID3D11Texture2D*>(release_context);
      texture->Release();
    };

    surface_size_ = {width, height};
  }
}

const FlutterDesktopGpuSurfaceDescriptor*
TextureBridgeGpu::GetSurfaceDescriptor(size_t width, size_t height) {
  const std::lock_guard<std::mutex> lock(mutex_);

  if (!is_running_) {
    return nullptr;
  }

  if (last_frame_) {
    ProcessFrame(last_frame_);
  }

  if (surface_) {
    surface_->AddRef();
  }

  return &surface_descriptor_;
}

void TextureBridgeGpu::StopInternal() {
  TextureBridge::StopInternal();
  surface_ = nullptr;
}

}  // namespace webview_plus
