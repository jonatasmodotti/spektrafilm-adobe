#include "spektrafilm_adobe/MetalBridge.h"
#include "SpektraMetalRenderer.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cmath>
#include <initializer_list>
#include <mutex>

namespace spektrafilm::adobe {
namespace {
// The renderer reads and writes the host frames itself (channel order, alpha mode,
// precision, padding), fused into its first and last passes where it can.
AdobeHostLayout hostLayout(const FrameLayout& v) {
  AdobeHostLayout layout;
  layout.rowComponents = v.rowBytes / v.bytesPerComponent;
  layout.offsetComponents = v.offsetBytes / v.bytesPerComponent;
  layout.width = v.width;
  layout.height = v.height;
  layout.order = uint32_t(v.order);
  layout.premultiplied = uint32_t(v.alpha);
  layout.halfPrecision = v.bytesPerComponent == 2 ? 1u : 0u;
  return layout;
}
}

struct MetalBridge::Impl {
  MetalRenderer renderer;
  id<MTLDevice> device = nil;
  mutable std::mutex mutex;
  std::string error;

  Impl() {
    if (!renderer.isAvailable()) { error = renderer.lastError(); return; }
    device = MTLCreateSystemDefaultDevice();
  }

  // Commits the last command buffer and waits once. The host queue executes the
  // spectral render before it, so its completion means every earlier command
  // finished and every persistent buffer is reusable.
  bool complete(id<MTLCommandBuffer> last, std::initializer_list<id<MTLCommandBuffer>> earlier) {
    if (!last) { error = "Cannot create Metal command buffer."; return false; }
    [last commit];
    [last waitUntilCompleted];
    for (id<MTLCommandBuffer> command : earlier)
      if (!succeeded(command, "GPU command failed.")) return false;
    return succeeded(last, "GPU command failed.");
  }

  bool succeeded(id<MTLCommandBuffer> command, const char* fallback) {
    if (!command || command.status != MTLCommandBufferStatusError) return true;
    error = command.error ? command.error.localizedDescription.UTF8String : fallback;
    return false;
  }
};

MetalBridge::MetalBridge() : impl_(std::make_unique<Impl>()) {}
MetalBridge::~MetalBridge() = default;
bool MetalBridge::isAvailable() const { return impl_->renderer.isAvailable() && impl_->device; }
std::string MetalBridge::lastError() const {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  return impl_->error;
}
bool MetalBridge::usesDevice(void* device) const { return device == (__bridge void*)impl_->device; }

bool MetalBridge::render(void* source, const FrameLayout& src,
                         void* destination, const FrameLayout& dst,
                         void* commandQueue, const RenderParams& params, double time) {
  @autoreleasepool {
    // AE may share gpu_data across MFR workers. The renderer's persistent scratch
    // buffers belong to this device context, never to a caller.
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!isAvailable()) return false;
    impl_->error.clear();
    auto fail = [&](const char* message) { impl_->error = message; return false; };
    id<MTLBuffer> input = (__bridge id<MTLBuffer>)source;
    id<MTLBuffer> output = (__bridge id<MTLBuffer>)destination;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)commandQueue;
    if (!input || !output || !queue) return fail("Source, destination and host queue are required.");
    if (input.device != impl_->device || output.device != impl_->device || queue.device != impl_->device)
      return fail("Host resources must be on the system default Metal device.");
    if (const char* error = validateLayout(src, input.length)) return fail(error);
    if (const char* error = validateLayout(dst, output.length)) return fail(error);
    if (src.width != dst.width || src.height != dst.height) return fail("Source and destination dimensions differ.");
    if (!std::isfinite(time)) return fail("Render time must be finite.");
    if (params.autoExposure) return fail("Auto exposure is not supported by the upstream GPU-buffer path.");
    const uint64_t bytes = uint64_t(src.width) * src.height * 16;
    if (bytes > impl_->device.maxBufferLength) return fail("Frame exceeds the Metal buffer limit.");

    // The views only carry the window size; the host layouts describe the memory.
    const MetalBufferImageView from{source, 0, 0, int32_t(src.width), int32_t(src.height), int32_t(src.width * 16), 4, 4};
    const MetalBufferImageView to{destination, 0, 0, int32_t(dst.width), int32_t(dst.height), int32_t(dst.width * 16), 4, 4};
    const AdobeHostFrames frames{hostLayout(src), hostLayout(dst)};
    const RenderWindow window{0, 0, int32_t(src.width), int32_t(src.height)};
    const bool rendered = impl_->renderer.renderMetalBuffers(from, to, window, params, time, commandQueue, &frames);
    id<MTLCommandBuffer> spectral = (__bridge id<MTLCommandBuffer>)impl_->renderer.lastSubmittedCommandBuffer();
    id<MTLCommandBuffer> after = [queue commandBuffer];
    if (!rendered) {
      // Drain submitted work before the context or the host reuses the buffers.
      impl_->complete(after, {spectral});
      impl_->error = impl_->renderer.lastError();
      return false;
    }
    return impl_->complete(after, {spectral});
  }
}
} // namespace spektrafilm::adobe
