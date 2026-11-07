#include "spektrafilm_adobe/MetalBridge.h"
#include "SpektraMetalRenderer.h"
#include "SpektraProfileCurves.h"
#include "AdobeParameters.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <array>
#include <string>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>
#include <thread>
using namespace spektrafilm;
using namespace spektrafilm::adobe;

void require(bool ok, const std::string& message) {
  if (!ok) { std::cerr << message << '\n'; std::exit(1); }
}
std::array<float, 4> encode(float r, float g, float b, float a, ChannelOrder order, AlphaMode alpha) {
  if (alpha == AlphaMode::Premultiplied) { r *= a; g *= a; b *= a; }
  if (order == ChannelOrder::BGRA) return {b, g, r, a};
  if (order == ChannelOrder::ARGB) return {a, r, g, b};
  return {r, g, b, a};
}

// Reversal stocks must retain the scene's polarity. Printing a developed slide
// onto negative-working paper inverts it a second time.
void filmPolarity(MetalBridge& bridge, id<MTLDevice> device, id<MTLCommandQueue> queue) {
  constexpr uint32_t w = 32;
  std::vector<float> source(w*4);
  for (uint32_t x = 0; x < w; ++x) {
    for (int c = 0; c < 3; ++c) source[x*4+c] = float(x)/(w-1);
    source[x*4+3] = 1;
  }
  const FrameLayout layout{w, 1, w*16, 0, ChannelOrder::RGBA, AlphaMode::Straight};
  id<MTLBuffer> input = [device newBufferWithBytes:source.data() length:source.size()*4 options:MTLResourceStorageModeShared];
  id<MTLBuffer> output = [device newBufferWithLength:source.size()*4 options:MTLResourceStorageModeShared];
  ParameterValues values{};
  for (int i = 1; i < ParameterCount; ++i) {
    if (parameterKind(i) == ParameterKind::Popup) values[i] = 1;
    if (parameterKind(i) == ParameterKind::Float) values[i] = floatSpec(i).initial;
  }
  values[InputSpace] = int(ColorSpace::LinearRec709)+1;
  values[OutputSpace] = int(ColorSpace::Srgb)+1;
  values[Paper] = kSpektraDefaultPaperIndex+1;
  values[FilmFormatChoice] = filmFormatChoice(kDefaultFilmFormat);
  auto render = [&](const RenderParams& params) {
    require(bridge.render((__bridge void*)input, layout, (__bridge void*)output, layout,
      (__bridge void*)queue, params, 0), bridge.lastError());
    const auto* data = static_cast<const float*>(output.contents);
    std::vector<float> luminance(w);
    for (uint32_t x = 0; x < w; ++x) {
      for (int c = 0; c < 4; ++c) require(std::isfinite(data[x*4+c]), "Film ramp must be finite.");
      require(data[x*4+3] == 1, "Film ramp alpha is preserved.");
      luminance[x] = .2126f*data[x*4] + .7152f*data[x*4+1] + .0722f*data[x*4+2];
    }
    return luminance;
  };
  int positiveCount = 0;
  bool correct = true;
  for (uint32_t film = 0; film < kSpektraFilmCount; ++film) {
    values[Film] = film+1;
    auto params = renderParams(values);
    const auto* profile = filmProfileCurves(film);
    const bool positive = std::strcmp(profile->type, "positive") == 0;
    if (!positive) {
      require(params.process == ProcessMode::PrintSimulation && !params.scanNegativeInvert,
        "Negative stocks keep the print simulation.");
      continue;
    }
    ++positiveCount;
    const auto ramp = render(params);
    std::cout << profile->name << ": black " << ramp.front() << ", white " << ramp.back() << '\n';
    correct &= ramp.back() > ramp.front()+.1f;
    for (uint32_t x = 1; x < w; ++x) correct &= ramp[x]+.0001f >= ramp[x-1];
    params.filmExposureEv = 1;
    const auto exposed = render(params);
    correct &= exposed[w/4] > ramp[w/4]+.01f;
  }
  require(positiveCount == 4, "All four reversal stocks are covered, including Ektachrome.");
  require(correct, "Reversal stocks must preserve the gray ramp and brighten with Film Exposure.");
}

// The spectral LUT is an approximation of the exact per-pixel integrals. Its
// error must stay below one 10-bit code value across stocks and exposures, and
// the frame-constant cache must never return results for other parameters.
void spectralLutAndFrameCache() {
  constexpr int w = 96, h = 64;
  std::vector<float> source(size_t(w)*h*4), exact(source.size()), approx(source.size()), again(source.size());
  for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
    float* p = &source[(size_t(y)*w+x)*4];
    const float level = std::exp2(-10.0f + 13.0f*x/(w-1));  // about 0.001 to 8 linear
    const float hue = 6.2831853f*y/h;
    p[0] = level*(0.55f + 0.45f*std::cos(hue));
    p[1] = level*(0.55f + 0.45f*std::cos(hue - 2.094f));
    p[2] = level*(0.55f + 0.45f*std::cos(hue + 2.094f));
    p[3] = 1;
  }
  const char* configured = std::getenv("SPEKTRAFILM_SPECTRAL_LUT");
  const std::string lutSetting = configured ? configured : "";
  setenv("SPEKTRAFILM_SPECTRAL_LUT", "off", 1);
  MetalRenderer exactRenderer;
  if (lutSetting.empty()) unsetenv("SPEKTRAFILM_SPECTRAL_LUT");
  else setenv("SPEKTRAFILM_SPECTRAL_LUT", lutSetting.c_str(), 1);
  MetalRenderer lutRenderer;
  require(exactRenderer.isAvailable() && lutRenderer.isAvailable(), "Spectral LUT renderers");
  const ImageView from{source.data(), 0, 0, w, h, w*16, 4, 4};
  const RenderWindow window{0, 0, w, h};
  auto render = [&](MetalRenderer& renderer, const RenderParams& p, std::vector<float>& out) {
    const MutableImageView to{out.data(), 0, 0, w, h, w*16, 4, 4};
    require(renderer.render(from, to, window, p, 0), renderer.lastError());
  };
  RenderParams p;
  p.inputColorSpace = ColorSpace::LinearRec709;
  p.outputColorSpace = ColorSpace::Srgb;
  double worst = 0;
  for (int32_t film : {0, int32_t(kSpektraDefaultFilmIndex), int32_t(kSpektraFilmCount) - 1})
  for (int32_t paper : {0, int32_t(kSpektraDefaultPaperIndex), int32_t(kSpektraPaperCount) - 1})
  for (float printEv : {-2.0f, 0.0f, 2.0f}) {
    p.film = film; p.paper = paper; p.printExposureEv = printEv; p.filmExposureEv = printEv > 0 ? -2.0f : 1.0f;
    render(exactRenderer, p, exact);
    render(lutRenderer, p, approx);
    double caseWorst = 0; size_t at = 0;
    for (size_t i = 0; i < exact.size(); ++i) {
      require(std::isfinite(approx[i]), "Spectral LUT output must be finite.");
      const double d = std::abs(approx[i] - exact[i]);
      if (d > caseWorst) { caseWorst = d; at = i; }
    }
    if (std::getenv("SPEKTRAFILM_TEST_VERBOSE"))
      std::cout << "film " << film << " paper " << paper << " ev " << printEv << " err " << caseWorst
        << " at x " << (at/4)%w << " y " << (at/4)/w << " c " << at%4 << " exact " << exact[at] << "\n";
    worst = std::max(worst, caseWorst);
  }
  require(worst > 0, "The default renderer must use the spectral LUT.");
  require(worst < 1.0/1023, "Spectral LUT error must stay below one 10-bit code value: " + std::to_string(worst));
  std::cout << "Spectral LUT max error " << worst << " over 27 stock/exposure cases.\n";

  // Warm renderer, changed parameters: must equal a cold renderer's result.
  RenderParams a = p, b = p;
  a.printExposureEv = 0; b.printExposureEv = 1.5f; b.film = 1;
  render(lutRenderer, a, approx);
  render(lutRenderer, b, again);
  MetalRenderer cold;
  render(cold, b, exact);
  require(again == exact, "Frame constants must be recomputed when parameters change.");
  render(lutRenderer, a, again);
  require(again == approx, "Frame constants must be recomputed when parameters change back.");
  std::cout << "Frame constant cache follows parameter changes.\n";
}

// Wide halation bounces on small formats are blurred at reduced resolution. The
// result must stay within one 10-bit code value of the full-resolution blur,
// even next to small, very bright highlights, away from the frame edge.
void halationDownsample() {
  constexpr int w = 512, h = 288;
  std::vector<float> source(size_t(w)*h*4), exact(source.size()), approx(source.size());
  for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
    float* p = &source[(size_t(y)*w+x)*4];
    const bool spot = (x % 64 < 3 && y % 48 < 3) || (y >= 140 && y < 150);
    const float level = spot ? (x % 128 < 64 ? 4.0f : 1.0f) : 0.02f;
    p[0] = p[1] = p[2] = level;
    p[3] = 1;
  }
  const char* configured = std::getenv("SPEKTRAFILM_BLUR_DOWNSAMPLE");
  const std::string setting = configured ? configured : "";
  setenv("SPEKTRAFILM_BLUR_DOWNSAMPLE", "off", 1);
  MetalRenderer exactRenderer;
  setenv("SPEKTRAFILM_BLUR_DOWNSAMPLE", "auto", 1);
  MetalRenderer downsampledRenderer;
  if (setting.empty()) unsetenv("SPEKTRAFILM_BLUR_DOWNSAMPLE");
  else setenv("SPEKTRAFILM_BLUR_DOWNSAMPLE", setting.c_str(), 1);
  require(exactRenderer.isAvailable() && downsampledRenderer.isAvailable(), "Halation downsample renderers");
  const ImageView from{source.data(), 0, 0, w, h, w*16, 4, 4};
  const RenderWindow window{0, 0, w, h};
  RenderParams p;
  p.inputColorSpace = ColorSpace::LinearRec709;
  p.outputColorSpace = ColorSpace::Srgb;
  p.halationEnabled = true;
  p.filmFormat = FilmFormat::Standard8;
  p.halationScale = 2;  // bounce sigmas of about 14, 20 and 24 px: scales 2, 2 and 4
  const MutableImageView exactView{exact.data(), 0, 0, w, h, w*16, 4, 4};
  const MutableImageView approxView{approx.data(), 0, 0, w, h, w*16, 4, 4};
  require(exactRenderer.render(from, exactView, window, p, 0), exactRenderer.lastError());
  require(downsampledRenderer.render(from, approxView, window, p, 0), downsampledRenderer.lastError());
  // The reduced grid mirrors about the center of its first pixel, (scale-1)/2
  // pixels inside the frame edge, so a highlight on the edge differs more there.
  constexpr int border = 8;
  double worst = 0, interior = 0;
  for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) for (int c = 0; c < 4; ++c) {
    const size_t i = (size_t(y)*w+x)*4+c;
    require(std::isfinite(approx[i]), "Downsampled halation must be finite.");
    const double d = std::abs(approx[i] - exact[i]);
    worst = std::max(worst, d);
    if (x >= border && y >= border && x < w-border && y < h-border) interior = std::max(interior, d);
  }
  require(worst > 0, "Wide halation bounces must take the downsampled path.");
  require(interior < 1.0/1023, "Downsampled halation must stay within one 10-bit code value: " + std::to_string(interior));
  require(worst < 2.0/1023, "Downsampled halation at the frame edge: " + std::to_string(worst));
  std::cout << "Halation downsample max error " << interior << ", " << worst << " at the frame edge.\n";
}

int main() {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { std::cerr << "Metal device unavailable in this process.\n"; return 77; }
    MetalBridge bridge;
    require(bridge.isAvailable(), bridge.lastError());
    MetalRenderer reference;
    require(reference.isAvailable(), reference.lastError());
    id<MTLCommandQueue> queue = [device newCommandQueue];
    filmPolarity(bridge, device, queue);
    constexpr uint32_t w = 7, h = 5;
    std::vector<float> rgba(w*h*4), expected(w*h*4);
    for (uint32_t p = 0; p < w*h; ++p) {
      const float a = float(p % 4) / 3;
      rgba[p*4] = a ? 0.02f + p*0.011f : 0;
      rgba[p*4+1] = a ? 0.18f : 0;
      rgba[p*4+2] = a ? 0.7f - p*0.009f : 0;
      rgba[p*4+3] = a;
    }
    const ImageView from{rgba.data(), 0, 0, int32_t(w), int32_t(h), int32_t(w*16), 4, 4};
    const MutableImageView to{expected.data(), 0, 0, int32_t(w), int32_t(h), int32_t(w*16), 4, 4};
    const RenderWindow window{0, 0, w, h};
    // The renderer reads and writes host frames inside its first and last passes on
    // the default path, and through unpack/pack passes otherwise; both must match.
    auto checkLayouts = [&](const RenderParams& params, const char* label) {
      require(reference.render(from, to, window, params, 0), reference.lastError());
      bool changed = false;
      for (size_t i = 0; i < rgba.size(); ++i) {
        require(std::isfinite(expected[i]), "Reference must be finite.");
        if (i % 4 != 3 && std::abs(expected[i] - rgba[i]) > 0.001f) changed = true;
      }
      require(changed, "Reference must perform film simulation.");
      int cases = 0;
      for (auto srcOrder : {ChannelOrder::RGBA, ChannelOrder::BGRA, ChannelOrder::ARGB})
      for (auto dstOrder : {ChannelOrder::RGBA, ChannelOrder::BGRA, ChannelOrder::ARGB})
      for (auto srcAlpha : {AlphaMode::Straight, AlphaMode::Premultiplied})
      for (auto dstAlpha : {AlphaMode::Straight, AlphaMode::Premultiplied}) {
        const FrameLayout src{w, h, w*16 + 32, 16, srcOrder, srcAlpha};
        const FrameLayout dst{w, h, w*16 + 48, 32, dstOrder, dstAlpha};
        const size_t srcBytes = src.offsetBytes + src.rowBytes*h;
        const size_t dstBytes = dst.offsetBytes + dst.rowBytes*h;
        std::vector<float> input(srcBytes/4, -999), wanted(dstBytes/4, -999);
        for (uint32_t y = 0; y < h; ++y) for (uint32_t x = 0; x < w; ++x) {
          const size_t p = (y*w+x)*4;
          const auto a = encode(rgba[p], rgba[p+1], rgba[p+2], rgba[p+3], srcOrder, srcAlpha);
          const auto b = encode(expected[p], expected[p+1], expected[p+2], rgba[p+3], dstOrder, dstAlpha);
          for (int c = 0; c < 4; ++c) {
            input[(src.offsetBytes+y*src.rowBytes)/4+x*4+c] = a[c];
            wanted[(dst.offsetBytes+y*dst.rowBytes)/4+x*4+c] = b[c];
          }
        }
        id<MTLBuffer> inBuffer = [device newBufferWithBytes:input.data() length:srcBytes options:MTLResourceStorageModeShared];
        std::vector<float> sentinel(dstBytes/4, -999);
        id<MTLBuffer> outBuffer = [device newBufferWithBytes:sentinel.data() length:dstBytes options:MTLResourceStorageModeShared];
        require(bridge.render((__bridge void*)inBuffer, src, (__bridge void*)outBuffer, dst,
          (__bridge void*)queue, params, 0), bridge.lastError());
        const auto* actual = static_cast<const float*>(outBuffer.contents);
        for (size_t i = 0; i < wanted.size(); ++i)
          require(std::isfinite(actual[i]) && std::abs(actual[i]-wanted[i]) < 0.0001f,
            "Layout/alpha/padding mismatch in case " + std::to_string(cases) + " at " + std::to_string(i));
        ++cases;
      }
      std::cout << cases << " GPU layout/alpha cases match the native film renderer (" << label << ").\n";

    };
    RenderParams params;
    params.inputColorSpace = ColorSpace::LinearRec709;
    params.outputColorSpace = ColorSpace::LinearRec709;
    params.film = kSpektraDefaultFilmIndex;
    params.paper = kSpektraDefaultPaperIndex;
    RenderParams staged = params;
    staged.enlargerScale = 1.2f;   // source transform: the host source is unpacked first
    staged.scannerEnabled = true;  // scanner post-process: the result is packed last
    checkLayouts(staged, "unpack/pack passes");
    RenderParams controls = params;  // film format, halation and both diffusion stages
    controls.filmFormat = FilmFormat::Super8;
    controls.halationEnabled = true;
    controls.halationStrengthR = 0.1f;
    controls.cameraDiffusionEnabled = true;
    controls.printDiffusionEnabled = true;
    controls.printDiffusionFamily = DiffusionFilterFamily::CineBloom;
    checkLayouts(controls, "film format, halation, diffusion");
    const std::vector<float> controlled = expected;
    checkLayouts(params, "fused host passes");  // last, so `expected` holds the default result
    float controlDelta = 0;
    for (size_t i = 0; i < expected.size(); ++i) controlDelta = std::max(controlDelta, std::abs(controlled[i] - expected[i]));
    require(controlDelta > 0.001f, "Film format, halation and diffusion change the image.");
    std::cout << "Format, halation and diffusion controls change the image (max delta " << controlDelta << ").\n";
    {
      // Animated grain: a new pattern per 1/24 s, reproducible for the same time.
      RenderParams grain = params;
      grain.grainEnabled = true;
      grain.grainAnimate = true;
      const FrameLayout layout{w, h, w*16, 0, ChannelOrder::RGBA, AlphaMode::Straight};
      id<MTLBuffer> in = [device newBufferWithBytes:rgba.data() length:rgba.size()*4 options:MTLResourceStorageModeShared];
      auto frame = [&](const RenderParams& settings, double time) {
        id<MTLBuffer> out = [device newBufferWithLength:rgba.size()*4 options:MTLResourceStorageModeShared];
        require(bridge.render((__bridge void*)in, layout, (__bridge void*)out, layout, (__bridge void*)queue, settings, time),
          bridge.lastError());
        const auto* data = static_cast<const float*>(out.contents);
        return std::vector<float>(data, data + rgba.size());
      };
      const auto first = frame(grain, 0.0), again = frame(grain, 0.0), next = frame(grain, 1.0/24);
      require(first == again, "Animated grain is reproducible for the same time.");
      require(first != next, "Animated grain changes between frames.");
      grain.grainAnimate = false;
      require(frame(grain, 0.0) == frame(grain, 1.0/24), "Static grain does not change over time.");
      std::cout << "Animated grain changes per frame and repeats for the same time.\n";
    }
    // Premiere commonly supplies half precision GPU frames. Compare using the
    // quantized source, including its alpha, rather than a float32 approximation.
    std::vector<_Float16> halfInput(w*h*4);
    std::vector<float> quantized(w*h*4), halfExpected(w*h*4);
    for (uint32_t p = 0; p < w*h; ++p) {
      const auto v = encode(rgba[p*4], rgba[p*4+1], rgba[p*4+2], rgba[p*4+3], ChannelOrder::BGRA, AlphaMode::Premultiplied);
      for (int c = 0; c < 4; ++c) halfInput[p*4+c] = _Float16(v[c]);
      const float a = float(halfInput[p*4+3]);
      quantized[p*4+3] = a;
      for (int c = 0; c < 3; ++c) quantized[p*4+c] = a > 0 ? float(halfInput[p*4+2-c])/a : 0;
    }
    const ImageView halfFrom{quantized.data(), 0, 0, int32_t(w), int32_t(h), int32_t(w*16), 4, 4};
    const MutableImageView halfTo{halfExpected.data(), 0, 0, int32_t(w), int32_t(h), int32_t(w*16), 4, 4};
    const FrameLayout halfLayout{w, h, w*8, 0, ChannelOrder::BGRA, AlphaMode::Premultiplied, 2};
    id<MTLBuffer> halfSource = [device newBufferWithBytes:halfInput.data() length:halfInput.size()*2 options:MTLResourceStorageModeShared];
    id<MTLBuffer> halfResult = [device newBufferWithLength:halfInput.size()*2 options:MTLResourceStorageModeShared];
    for (bool spatial : {false, true}) {
      params.halationEnabled = spatial;
      params.grainEnabled = spatial;
      require(reference.render(halfFrom, halfTo, window, params, 0), reference.lastError());
      require(bridge.render((__bridge void*)halfSource, halfLayout, (__bridge void*)halfResult, halfLayout,
        (__bridge void*)queue, params, 0), bridge.lastError());
      const auto* actual = static_cast<const _Float16*>(halfResult.contents);
      for (uint32_t p = 0; p < w*h; ++p) {
        const float a = quantized[p*4+3];
        require(float(actual[p*4+3]) == a, "Half precision alpha preserved exactly.");
        for (int c = 0; c < 3; ++c) {
          const float wanted = float(_Float16(a > 0 ? halfExpected[p*4+c]*a : 0));
          require(std::isfinite(float(actual[p*4+2-c])) && std::abs(float(actual[p*4+2-c])-wanted) < .001f,
            "Half precision / spatial film result mismatch.");
        }
      }
    }
    std::cout << "Float16 and grain/halation cases match the native film renderer.\n";
    std::vector<std::vector<float>> concurrentExpected(3, std::vector<float>(rgba.size()));
    std::vector<RenderParams> concurrentParams(3, params);
    for (int worker = 0; worker < 3; ++worker) {
      auto& p = concurrentParams[worker];
      p.grainEnabled = p.halationEnabled = false;
      p.filmExposureEv = worker*.375f;
      MutableImageView target{concurrentExpected[worker].data(), 0, 0, int32_t(w), int32_t(h), int32_t(w*16), 4, 4};
      require(reference.render(from, target, window, p, 0), reference.lastError());
    }
    std::vector<std::thread> workers;
    for (int worker = 0; worker < 3; ++worker) workers.emplace_back([&, worker] {
      @autoreleasepool {
        id<MTLCommandQueue> ownQueue = [device newCommandQueue];
        id<MTLBuffer> input = [device newBufferWithBytes:rgba.data() length:rgba.size()*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> output = [device newBufferWithLength:rgba.size()*4 options:MTLResourceStorageModeShared];
        const FrameLayout straight{w, h, w*16, 0, ChannelOrder::RGBA, AlphaMode::Straight};
        for (int frame = 0; frame < 3; ++frame) {
          require(bridge.render((__bridge void*)input, straight, (__bridge void*)output, straight,
            (__bridge void*)ownQueue, concurrentParams[worker], 0), "Shared device context render");
          const auto* actual = static_cast<const float*>(output.contents);
          for (size_t i = 0; i < rgba.size(); ++i) {
            const float wanted = i%4 == 3 ? rgba[i] : concurrentExpected[worker][i];
            require(std::isfinite(actual[i]) && std::abs(actual[i]-wanted) < .0001f, "Concurrent GPU frame isolation");
          }
        }
      }
    });
    for (auto& worker : workers) worker.join();
    std::cout << "Shared Metal context is safe across concurrent callers.\n";
    id<MTLBuffer> cachedInput = [device newBufferWithBytes:rgba.data() length:rgba.size()*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> cachedOutput = [device newBufferWithLength:rgba.size()*4 options:MTLResourceStorageModeShared];
    const MetalBufferImageView cachedFrom{(__bridge void*)cachedInput, 0, 0, int32_t(w), int32_t(h), int32_t(w*16), 4, 4};
    const MetalBufferImageView cachedTo{(__bridge void*)cachedOutput, 0, 0, int32_t(w), int32_t(h), int32_t(w*16), 4, 4};
    require(reference.renderMetalBuffers(cachedFrom, cachedTo, window, params, 0, (__bridge void*)queue), reference.lastError());
    require(reference.renderMetalBuffers(cachedFrom, cachedTo, window, params, 0, (__bridge void*)queue), reference.lastError());
    require(reference.lastDiagnostics().scratchAllocationCount == 0, "Warm external GPU frames must reuse scratch buffers.");
    spectralLutAndFrameCache();
    halationDownsample();
  }
}
