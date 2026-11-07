#include "AdobeBanner.h"
#include "AE_EffectSuites.h"
#include "AdobeSuites.h"
#include "adobesdk/DrawbotSuite.h"
#include <algorithm>
#include <cmath>
#include <mutex>

namespace spektrafilm::adobe {
namespace {
struct Bitmap { int width = 0, height = 0; std::vector<uint8_t> pixels; };

// The last size drawn; the panel redraws at the same size most of the time.
const Bitmap* cachedBitmap(int width, int height) {
  static std::mutex mutex;
  static Bitmap cached;
  std::lock_guard<std::mutex> lock(mutex);
  if (cached.width == width && cached.height == height) return &cached;
  Bitmap bitmap{width, height, {}};
  if (width <= 0 || height <= 0 || !loadBannerPixels(width, height, bitmap.pixels)) return nullptr;
  cached = std::move(bitmap);
  return &cached;
}
}

bool drawBanner(PF_InData* in_data, PF_EventExtra* event) {
  if (!event || event->effect_win.area != PF_EA_CONTROL) return false;
  try {
    SPBasicSuite* basic = in_data->pica_basicP;
    // Version 1 of the custom UI suite and no image suite: what Premiere provides.
    Suite<PF_EffectCustomUISuite1> custom(basic, kPFEffectCustomUISuite, kPFEffectCustomUISuiteVersion1);
    Suite<DRAWBOT_DrawbotSuite1> drawbot(basic, kDRAWBOT_DrawSuite, kDRAWBOT_DrawSuite_Version1);
    Suite<DRAWBOT_SupplierSuite1> supplier(basic, kDRAWBOT_SupplierSuite, kDRAWBOT_SupplierSuite_Version1);
    Suite<DRAWBOT_SurfaceSuite1> surface(basic, kDRAWBOT_SurfaceSuite, kDRAWBOT_SurfaceSuite_Version1);
    DRAWBOT_DrawRef drawRef = nullptr;
    DRAWBOT_SupplierRef supplierRef = nullptr;
    DRAWBOT_SurfaceRef surfaceRef = nullptr;
    if (custom->PF_GetDrawingReference(event->contextH, &drawRef) || !drawRef ||
        drawbot->GetSupplier(drawRef, &supplierRef) || drawbot->GetSurface(drawRef, &surfaceRef)) return false;
    const PF_Rect frame = event->effect_win.current_frame;
    const int width = frame.right - frame.left, height = frame.bottom - frame.top;

    // After Effects on a high-density display: draw a bitmap at screen
    // resolution and scale it down with the surface transform. Premiere draws
    // at 1x in panel coordinates, as Adobe's Custom_ECW_UI sample does.
    float screenScale = 1;
    if (in_data->appl_id != kAppID_Premiere) {
      const DRAWBOT_SurfaceSuite2* surface2 = nullptr;
      if (!basic->AcquireSuite(kDRAWBOT_SurfaceSuite, kDRAWBOT_SurfaceSuite_Version2,
            reinterpret_cast<const void**>(&surface2)) && surface2) {
        if (surface2->GetTransformToScreenScale(surfaceRef, &screenScale) || !(screenScale > 0)) screenScale = 1;
        basic->ReleaseSuite(kDRAWBOT_SurfaceSuite, kDRAWBOT_SurfaceSuite_Version2);
      }
      screenScale = std::clamp(std::round(screenScale), 1.0f, 3.0f);
    }
    const Bitmap* bitmap = cachedBitmap(int(width * screenScale), int(height * screenScale));
    if (!bitmap) return false;

    // BGRA where the host takes it; otherwise ARGB.
    DRAWBOT_Boolean bgra = false;
    if (supplier->SupportsPixelLayoutBGRA(supplierRef, &bgra)) bgra = false;
    std::vector<uint8_t> argb;
    if (!bgra) {
      argb.resize(bitmap->pixels.size());
      for (size_t i = 0; i < argb.size(); i += 4) {
        argb[i] = bitmap->pixels[i + 3]; argb[i + 1] = bitmap->pixels[i + 2];
        argb[i + 2] = bitmap->pixels[i + 1]; argb[i + 3] = bitmap->pixels[i];
      }
    }
    DRAWBOT_ImageRef image = nullptr;
    if (supplier->NewImageFromBuffer(supplierRef, bitmap->width, bitmap->height, bitmap->width * 4,
          bgra ? kDRAWBOT_PixelLayout_32BGRA_Premul : kDRAWBOT_PixelLayout_32ARGB_Premul,
          bgra ? bitmap->pixels.data() : argb.data(), &image) || !image) return false;

    SPErr result;
    if (screenScale == 1.0f) {
      const DRAWBOT_PointF32 origin{float(frame.left), float(frame.top)};
      result = surface->DrawImage(surfaceRef, image, &origin, 1.0f);
    } else {
      surface->PushStateStack(surfaceRef);
      // A pure scale reads the same in row- and column-vector conventions; the
      // position goes into the origin, in the scaled coordinates.
      const float inverse = 1.0f / screenScale;
      const DRAWBOT_MatrixF32 transform{{{inverse, 0, 0}, {0, inverse, 0}, {0, 0, 1}}};
      surface->Transform(surfaceRef, &transform);
      const DRAWBOT_PointF32 origin{frame.left * screenScale, frame.top * screenScale};
      result = surface->DrawImage(surfaceRef, image, &origin, 1.0f);
      surface->PopStateStack(surfaceRef);
    }
    supplier->ReleaseObject(reinterpret_cast<DRAWBOT_ObjectRef>(image));
    if (result != kSPNoError) return false;
    event->evt_out_flags = PF_EO_HANDLED_EVENT;
    return true;
  } catch (...) {
    return false;
  }
}
}
