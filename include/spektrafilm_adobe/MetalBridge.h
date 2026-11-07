#pragma once

#include <memory>
#include <string>
#include "spektrafilm_adobe/FrameLayout.h"
#include "SpektraParameters.h"

namespace spektrafilm::adobe {

// Thread-safe device context. No Adobe SDK dependency or host ownership.
class MetalBridge final {
public:
  MetalBridge();
  ~MetalBridge();
  MetalBridge(const MetalBridge&) = delete;
  MetalBridge& operator=(const MetalBridge&) = delete;

  bool isAvailable() const;
  std::string lastError() const;
  bool usesDevice(void* device) const;

  // Opaque arguments are id<MTLBuffer> and id<MTLCommandQueue>, respectively.
  // Full-frame float16/float32 input/output on the system default Metal device.
  // Uses the supplied host queue. Returns only after GPU completion.
  bool render(void* source, const FrameLayout& sourceLayout,
              void* destination, const FrameLayout& destinationLayout,
              void* commandQueue, const RenderParams& params, double timeSeconds);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace spektrafilm::adobe
