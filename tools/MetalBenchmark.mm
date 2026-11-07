#include "spektrafilm_adobe/MetalBridge.h"
#include "SpektraMetalRenderer.h"
#include "SpektraProfileCurves.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <vector>
using namespace spektrafilm;
using namespace spektrafilm::adobe;
using Clock = std::chrono::steady_clock;
double ms(Clock::time_point a) { return std::chrono::duration<double, std::milli>(Clock::now()-a).count(); }

int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc < 5) { std::cerr << "Usage: metal_benchmark WIDTH HEIGHT ITERATIONS cpu|gpu|bridge [base|grain|halation|diffusion|all] [OUTPUT.f32] [INPUT.f32]\n"; return 2; }
    const int w = std::stoi(argv[1]), h = std::stoi(argv[2]), n = std::stoi(argv[3]);
    const std::string path = argv[4], effects = argc > 5 ? argv[5] : "base";
    if (w < 1 || h < 1 || w > 8192 || h > 8192 || n < 1 || n > 1000 ||
        (path != "cpu" && path != "gpu" && path != "bridge")) return 2;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return 77;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    std::vector<float> source(size_t(w)*h*4), result(source.size());
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
      const size_t i = (size_t(y)*w+x)*4;
      const float a = .25f + .75f * float((x+y)%17)/16;
      source[i] = (0.01f + 1.2f*float(x)/w)*a;
      source[i+1] = (0.02f + .9f*float(y)/h)*a;
      source[i+2] = (.05f + .7f*float((x*7+y*13)%251)/250)*a;
      source[i+3] = a;
    }
    if (argc > 7) {
      std::ifstream file(argv[7], std::ios::binary);
      file.read(reinterpret_cast<char*>(source.data()), source.size()*4);
      if (!file) return 1;
    }
    RenderParams p;
    p.inputColorSpace = ColorSpace::Srgb; p.outputColorSpace = ColorSpace::Srgb;
    p.film = kSpektraDefaultFilmIndex; p.paper = kSpektraDefaultPaperIndex;
    p.grainEnabled = effects == "grain"; p.halationEnabled = effects == "halation";
    p.cameraDiffusionEnabled = effects == "diffusion" || effects == "all";
    p.printDiffusionEnabled = effects == "diffusion" || effects == "all";
    if (effects == "all") p.grainEnabled = p.halationEnabled = true;
    p.grainAnimate = !std::getenv("SPEKTRAFILM_BENCH_STATIC_GRAIN");  // the plugin animates by default
    // SPEKTRAFILM_BENCH_FORMAT=0..7 picks the film format (0 = 8mm, 4 = 35mm, the default);
    // spatial effects are sized in micrometres, so smaller formats blur wider.
    if (const char* format = std::getenv("SPEKTRAFILM_BENCH_FORMAT")) p.filmFormat = FilmFormat(std::clamp(std::atoi(format), 0, 7));
    id<MTLBuffer> input = [device newBufferWithBytes:source.data() length:source.size()*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [device newBufferWithLength:source.size()*4 options:MTLResourceStorageModeShared];
    const auto init = Clock::now();
    std::unique_ptr<MetalBridge> bridge;
    std::unique_ptr<MetalRenderer> renderer;
    if (path == "bridge") bridge = std::make_unique<MetalBridge>();
    else renderer = std::make_unique<MetalRenderer>();
    if (bridge ? !bridge->isAvailable() : !renderer->isAvailable()) {
      std::cerr << (bridge ? bridge->lastError() : renderer->lastError()) << '\n'; return 1;
    }
    const double initMs = ms(init);
    const ImageView from{source.data(), 0, 0, w, h, w*16, 4, 4};
    const MutableImageView to{result.data(), 0, 0, w, h, w*16, 4, 4};
    const MetalBufferImageView gpuFrom{(__bridge void*)input, 0, 0, w, h, w*16, 4, 4};
    const MetalBufferImageView gpuTo{(__bridge void*)output, 0, 0, w, h, w*16, 4, 4};
    std::vector<double> times;
    double firstMs = 0;
    for (int frame = -2; frame < n; ++frame) {
      // SPEKTRAFILM_BENCH_SCRUB=1 changes a control every frame, as when a
      // slider is dragged, so per-parameter caches must be rebuilt.
      if (std::getenv("SPEKTRAFILM_BENCH_SCRUB")) p.printExposureEv = 0.01f * float(frame + 2);
      const auto start = Clock::now();
      bool ok;
      if (bridge) ok = bridge->render((__bridge void*)input, {uint32_t(w), uint32_t(h), uint64_t(w)*16},
        (__bridge void*)output, {uint32_t(w), uint32_t(h), uint64_t(w)*16}, (__bridge void*)queue, p, (frame+2)/24.0);
      else if (path == "gpu") ok = renderer->renderMetalBuffers(gpuFrom, gpuTo, {0, 0, w, h}, p, (frame+2)/24.0, (__bridge void*)queue);
      else ok = renderer->render(from, to, {0, 0, w, h}, p, (frame+2)/24.0);
      if (!ok) { std::cerr << (bridge ? bridge->lastError() : renderer->lastError()) << '\n'; return 1; }
      if (path == "gpu") { id<MTLCommandBuffer> fence = [queue commandBuffer]; [fence commit]; [fence waitUntilCompleted]; }
      const double elapsed = ms(start);
      if (frame == -2) firstMs = elapsed;
      if (frame >= 0) times.push_back(elapsed);
    }
    std::sort(times.begin(), times.end());
    const double median = times[times.size()/2], mean = std::accumulate(times.begin(), times.end(), 0.0)/n;
    std::cout << std::fixed << std::setprecision(3) << "{\"width\":" << w << ",\"height\":" << h
      << ",\"iterations\":" << n << ",\"path\":\"" << path << "\",\"effects\":\"" << effects
      << "\",\"init_ms\":" << initMs << ",\"first_ms\":" << firstMs << ",\"median_ms\":" << median
      << ",\"mean_ms\":" << mean << ",\"p95_ms\":" << times[size_t((n-1)*.95)] << ",\"fps\":" << 1000/median;
    if (renderer) {
      const auto& d = renderer->lastDiagnostics();
      std::cout << ",\"cpu_setup_ms\":" << d.cpuSetupMs << ",\"encode_ms\":" << d.commandEncodingMs
        << ",\"gpu_ms\":" << d.gpuCommandBufferMs << ",\"scratch_allocations\":" << d.scratchAllocationCount
        << ",\"static_allocations\":" << d.staticAllocationCount << ",\"pass_count\":" << d.passCount
        << ",\"timing\":\"" << d.passTimingMode << "\",\"passes\":[";
      for (size_t i = 0; i < d.passes.size(); ++i)
        std::cout << (i ? "," : "") << "{\"name\":\"" << d.passes[i].name << "\",\"gpu_ms\":" << d.passes[i].gpuMs << "}";
      std::cout << "]";
    }
    std::cout << "}\n";
    if (argc > 6) {
      const void* pixels = path == "cpu" ? result.data() : output.contents;
      std::ofstream file(argv[6], std::ios::binary);
      file.write(static_cast<const char*>(pixels), source.size()*sizeof(float));
      if (!file) return 1;
    }
  }
}
