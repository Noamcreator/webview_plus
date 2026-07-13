#pragma once

#include <D3d11.h>

namespace webview_plus::util {

inline HRESULT CreateD3DDevice(D3D_DRIVER_TYPE const type,
                               Microsoft::WRL::ComPtr<ID3D11Device>& device) {
  UINT flags =
      D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;

  return D3D11CreateDevice(nullptr, type, nullptr, flags, nullptr, 0,
                           D3D11_SDK_VERSION, device.GetAddressOf(), nullptr,
                           nullptr);
}

inline Microsoft::WRL::ComPtr<ID3D11Device> CreateD3DDevice() {
  Microsoft::WRL::ComPtr<ID3D11Device> device;
  HRESULT hr = CreateD3DDevice(D3D_DRIVER_TYPE_HARDWARE, device);

  if (DXGI_ERROR_UNSUPPORTED == hr) {
    CreateD3DDevice(D3D_DRIVER_TYPE_WARP, device);
  }

  return device;
}

}  // namespace webview_plus::util
