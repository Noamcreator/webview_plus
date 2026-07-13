#include "util/direct3d11.interop.h"

namespace webview_plus::util {

namespace {

typedef HRESULT(WINAPI* CreateDirect3D11DeviceFromDXGIDeviceFn)(IDXGIDevice*,
                                                                LPVOID*);

struct D3DFuncs {
  CreateDirect3D11DeviceFromDXGIDeviceFn CreateDirect3D11DeviceFromDXGIDevice =
      nullptr;

  D3DFuncs() {
    auto handle = GetModuleHandle(L"d3d11.dll");
    if (!handle) {
      return;
    }

    CreateDirect3D11DeviceFromDXGIDevice =
        reinterpret_cast<CreateDirect3D11DeviceFromDXGIDeviceFn>(
            GetProcAddress(handle, "CreateDirect3D11DeviceFromDXGIDevice"));
  }

  static const D3DFuncs& instance() {
    static D3DFuncs funcs;
    return funcs;
  }
};

}  // namespace

HRESULT CreateDirect3D11DeviceFromDXGIDevice(IDXGIDevice* dxgi_device,
                                             IInspectable** graphics_device) {
  auto ptr = D3DFuncs::instance().CreateDirect3D11DeviceFromDXGIDevice;
  if (ptr) {
    return ptr(dxgi_device, reinterpret_cast<LPVOID*>(graphics_device));
  }

  return E_NOTIMPL;
}

}  // namespace webview_plus::util
