#pragma once
#include "AE_Effect.h"
#include "AE_EffectUI.h"
#include <cstdint>
#include <vector>

namespace spektrafilm::adobe {
// Banner row at the top of the Effect Controls panel, in points. Premiere
// reserves kBannerWidth; After Effects spans the panel. The image is 1200x280,
// so the Premiere row shows it uncropped.
constexpr int kBannerWidth = 308;
constexpr int kBannerHeight = 72;

// Draws the banner, cropped to fill the control area. Returns false when the
// host offers no Drawbot surface or the image is missing; the row then stays
// empty.
bool drawBanner(PF_InData* in_data, PF_EventExtra* event);

// Platform part (AdobeBannerMac.mm, AdobeBannerWin.cpp): Resources/banner.jpg
// in the plugin bundle, scaled to cover width x height and centered, as
// premultiplied BGRA rows of width * 4 bytes.
bool loadBannerPixels(int width, int height, std::vector<uint8_t>& bgra);
}
