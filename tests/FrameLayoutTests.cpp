#include "spektrafilm_adobe/FrameLayout.h"
#include <cstdlib>
#include <iostream>
#include <limits>
using namespace spektrafilm::adobe;

void require(bool condition, const char* name) {
  if (!condition) { std::cerr << name << '\n'; std::exit(1); }
}
int main() {
  FrameLayout v{3, 2, 64, 16};
  require(!validateLayout(v, 128), "padded frame with offset");
  require(validateLayout(v, 127), "one byte too small");
  v.offsetBytes = std::numeric_limits<uint64_t>::max() - 3;
  require(validateLayout(v, 128), "offset cannot overflow");
  v.offsetBytes = 0;
  v.rowBytes = std::numeric_limits<uint64_t>::max() - 3;
  require(validateLayout(v, 128), "pitch cannot overflow");
  v.rowBytes = 47;
  require(validateLayout(v, 128), "short row");
  v.rowBytes = 49;
  require(validateLayout(v, 128), "unaligned row");
  v.rowBytes = 64;
  v.width = 0;
  require(validateLayout(v, 128), "empty width");
  v.width = 3;
  v.order = ChannelOrder(99);
  require(validateLayout(v, 128), "unknown channel order");
  v.order = ChannelOrder::ARGB;
  v.alpha = AlphaMode(99);
  require(validateLayout(v, 128), "unknown alpha mode");
  v.alpha = AlphaMode::Straight;
  v.height = std::numeric_limits<uint32_t>::max();
  require(validateLayout(v, 128), "height exceeds upstream int32");
  std::cout << "Frame layout checks passed.\n";
}
