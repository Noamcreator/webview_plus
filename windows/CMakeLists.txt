cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "webview_plus")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "webview_plus_plugin")

include(FetchContent)

set(WEBVIEW2_VERSION "1.0.2903.40")

FetchContent_Declare(
  webview2sdk
  URL "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/${WEBVIEW2_VERSION}"
  DOWNLOAD_NAME "webview2sdk.zip"
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(webview2sdk)

if(CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64" OR CMAKE_VS_PLATFORM_NAME STREQUAL "ARM64")
  set(WEBVIEW2_ARCH "arm64")
elseif(CMAKE_GENERATOR_PLATFORM STREQUAL "Win32" OR CMAKE_VS_PLATFORM_NAME STREQUAL "Win32")
  set(WEBVIEW2_ARCH "x86")
else()
  set(WEBVIEW2_ARCH "x64")
endif()

set(WEBVIEW2_INCLUDE_DIR "${webview2sdk_SOURCE_DIR}/build/native/include")
set(WEBVIEW2_LIB "${webview2sdk_SOURCE_DIR}/build/native/${WEBVIEW2_ARCH}/WebView2LoaderStatic.lib")

set(PLUGIN_SOURCES
  "webview_plus_plugin.cpp"
  "webview_plus_plugin_c_api.cpp"
  "platform/winrt_runtime.cc"
  "platform/webview_platform.cc"
  "rendering/graphics_context.cc"
  "rendering/texture_bridge.cc"
  "rendering/texture_bridge_gpu.cc"
  "util/direct3d11.interop.cc"
)

add_library(${PLUGIN_NAME} SHARED ${PLUGIN_SOURCES})

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${WEBVIEW2_INCLUDE_DIR}")
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
target_link_libraries(${PLUGIN_NAME} PRIVATE "${WEBVIEW2_LIB}")
target_link_libraries(${PLUGIN_NAME} PRIVATE d3d11 dxgi windowsapp)
# Comctl32 : requis par SetWindowSubclass/DefSubclassProc/RemoveWindowSubclass
# (util/window_subclass), utilisés pour détecter les déplacements de la
# fenêtre top-level (WM_MOVE / WM_WINDOWPOSCHANGED) et notifier WebView2 en
# conséquence via NotifyParentWindowPositionChanged (fix du menu contextuel
# mal positionné en mode fenêtré).
target_link_libraries(${PLUGIN_NAME} PRIVATE comctl32)

set(webview_plus_bundled_libraries
  ""
  PARENT_SCOPE
)
