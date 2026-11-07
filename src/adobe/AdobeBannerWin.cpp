#include "AdobeBanner.h"
#include <windows.h>
#include <objbase.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <string>

using Microsoft::WRL::ComPtr;

namespace spektrafilm::adobe {
namespace {
// Contents\Resources\banner.jpg, next to Contents\Win64\SpektraFilm.aex.
std::filesystem::path bannerPath() {
  HMODULE module = nullptr;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        reinterpret_cast<LPCWSTR>(&loadBannerPixels), &module)) return {};
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD length = GetModuleFileNameW(module, path.data(), DWORD(path.size()));
    if (!length) return {};
    if (length < path.size() - 1) { path.resize(length); break; }
    path.resize(path.size() * 2);
  }
  return std::filesystem::path(path).parent_path().parent_path() / L"Resources" / L"banner.jpg";
}

// Balances CoInitializeEx when this call initialized COM on the thread. The
// host's UI thread normally has COM already; RPC_E_CHANGED_MODE leaves it as is.
struct ComScope {
  HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  ~ComScope() { if (SUCCEEDED(result)) CoUninitialize(); }
  bool usable() const { return SUCCEEDED(result) || result == RPC_E_CHANGED_MODE; }
};
}

bool loadBannerPixels(int width, int height, std::vector<uint8_t>& bgra) {
  const std::filesystem::path path = bannerPath();
  ComScope com;
  if (path.empty() || !com.usable()) return false;
  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  ComPtr<IWICBitmapScaler> scaler;
  ComPtr<IWICBitmapClipper> clipper;
  ComPtr<IWICFormatConverter> converter;
  UINT imageWidth = 0, imageHeight = 0;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))) ||
      FAILED(factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
        WICDecodeMetadataCacheOnDemand, &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame)) || FAILED(frame->GetSize(&imageWidth, &imageHeight)) ||
      !imageWidth || !imageHeight) return false;
  // Scale to cover the area, then crop the centre.
  const double scale = std::max(double(width) / imageWidth, double(height) / imageHeight);
  const UINT scaledWidth = std::max(UINT(width), UINT(std::lround(imageWidth * scale)));
  const UINT scaledHeight = std::max(UINT(height), UINT(std::lround(imageHeight * scale)));
  const WICRect crop{INT(scaledWidth - width) / 2, INT(scaledHeight - height) / 2, width, height};
  const UINT stride = UINT(width) * 4;
  bgra.assign(size_t(stride) * height, 0);
  return SUCCEEDED(factory->CreateBitmapScaler(&scaler)) &&
    SUCCEEDED(scaler->Initialize(frame.Get(), scaledWidth, scaledHeight, WICBitmapInterpolationModeFant)) &&
    SUCCEEDED(factory->CreateBitmapClipper(&clipper)) &&
    SUCCEEDED(clipper->Initialize(scaler.Get(), &crop)) &&
    SUCCEEDED(factory->CreateFormatConverter(&converter)) &&
    SUCCEEDED(converter->Initialize(clipper.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone,
      nullptr, 0.0, WICBitmapPaletteTypeCustom)) &&
    SUCCEEDED(converter->CopyPixels(nullptr, stride, UINT(bgra.size()), bgra.data()));
}
}
