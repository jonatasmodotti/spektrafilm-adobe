#include "spektrafilm_adobe/FrameLayout.h"

#include <limits>

namespace spektrafilm::adobe {

const char* validateLayout(const FrameLayout& frame, uint64_t bufferBytes) {
  if (!frame.width || !frame.height) return "Frame dimensions must be positive.";
  // The upstream renderer's rowBytes and dimensions are signed 32-bit integers.
  if (frame.width > uint32_t(std::numeric_limits<int32_t>::max() / 16) ||
      frame.height > uint32_t(std::numeric_limits<int32_t>::max()))
    return "Frame dimensions exceed the native renderer limits.";
  if (frame.order != ChannelOrder::RGBA && frame.order != ChannelOrder::BGRA &&
      frame.order != ChannelOrder::ARGB) return "Unsupported channel order.";
  if (frame.alpha != AlphaMode::Straight && frame.alpha != AlphaMode::Premultiplied)
    return "Unsupported alpha mode.";
  if (frame.bytesPerComponent != 2 && frame.bytesPerComponent != 4)
    return "Only float16 and float32 components are supported.";
  const uint64_t rowSize = uint64_t(frame.width) * 4 * frame.bytesPerComponent;
  if (frame.rowBytes < rowSize || frame.rowBytes % frame.bytesPerComponent ||
      frame.offsetBytes % frame.bytesPerComponent) return "Invalid floating point pitch or offset.";
  if (frame.offsetBytes > bufferBytes) return "Frame offset exceeds the buffer.";
  const uint64_t available = bufferBytes - frame.offsetBytes;
  if (available < rowSize || uint64_t(frame.height - 1) > (available - rowSize) / frame.rowBytes)
    return "Frame exceeds the buffer.";
  return nullptr;
}

} // namespace spektrafilm::adobe
