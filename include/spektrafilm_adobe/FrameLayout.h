#pragma once

#include <cstddef>
#include <cstdint>

namespace spektrafilm::adobe {

// Float32 channels in memory order. This is independent of Adobe SDK enums.
enum class ChannelOrder : uint32_t { RGBA = 0, BGRA = 1, ARGB = 2 };
enum class AlphaMode : uint32_t { Straight = 0, Premultiplied = 1 };

struct FrameLayout {
  uint32_t width = 0;
  uint32_t height = 0;
  uint64_t rowBytes = 0;
  uint64_t offsetBytes = 0;
  ChannelOrder order = ChannelOrder::BGRA;
  AlphaMode alpha = AlphaMode::Premultiplied;
  uint32_t bytesPerComponent = 4; // float32 or float16 GPU frames
};

// Reject malformed layouts before the GPU can access host-owned memory.
const char* validateLayout(const FrameLayout& frame, uint64_t bufferBytes);

} // namespace spektrafilm::adobe
