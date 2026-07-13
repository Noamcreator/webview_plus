#pragma once

#include <inspectable.h>
#include <windows.foundation.h>
#include <wrl.h>
#include <dxgi.h>

namespace Windows {
namespace Graphics {
namespace DirectX {
namespace Direct3D11 {
struct __declspec(uuid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1"))
    IDirect3DDxgiInterfaceAccess : ::IUnknown {
  virtual HRESULT __stdcall GetInterface(GUID const& id, void** object) = 0;
};
}  // namespace Direct3D11
}  // namespace DirectX
}  // namespace Graphics
}  // namespace Windows

namespace webview_plus::util {

HRESULT CreateDirect3D11DeviceFromDXGIDevice(IDXGIDevice* dxgi_device,
                                             IInspectable** graphics_device);

template <typename T>
Microsoft::WRL::ComPtr<T> TryGetDXGIInterfaceFromObject(
    Microsoft::WRL::ComPtr<IInspectable> object) {
  Microsoft::WRL::ComPtr<
      Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>
      access;
  if (FAILED(object.As(&access)) || !access) {
    return nullptr;
  }
  Microsoft::WRL::ComPtr<T> result;
  access->GetInterface(__uuidof(T), reinterpret_cast<void**>(result.GetAddressOf()));
  return result;
}

}  // namespace webview_plus::util
