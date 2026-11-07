#include "AdobeBanner.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <algorithm>
#include <string>

namespace spektrafilm::adobe {
namespace {
// Contents/Resources/banner.jpg, next to Contents/MacOS/SpektraFilm.
CGImageRef bannerImage() {
  static CGImageRef image = [] () -> CGImageRef {
    Dl_info info{};
    if (!dladdr(reinterpret_cast<const void*>(&loadBannerPixels), &info) || !info.dli_fname) return nullptr;
    std::string path = info.dli_fname;
    path = path.substr(0, path.rfind('/'));
    path = path.substr(0, path.rfind('/')) + "/Resources/banner.jpg";
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr,
      reinterpret_cast<const UInt8*>(path.c_str()), CFIndex(path.size()), false);
    if (!url) return nullptr;
    CGImageSourceRef source = CGImageSourceCreateWithURL(url, nullptr);
    CFRelease(url);
    if (!source) return nullptr;
    CGImageRef decoded = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
    CFRelease(source);
    return decoded;
  }();
  return image;
}
}

bool loadBannerPixels(int width, int height, std::vector<uint8_t>& bgra) {
  CGImageRef image = bannerImage();
  if (!image) return false;
  bgra.assign(size_t(width) * height * 4, 0);
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context = CGBitmapContextCreate(bgra.data(), width, height, 8, size_t(width) * 4, space,
    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(space);
  if (!context) return false;
  const double imageWidth = double(CGImageGetWidth(image)), imageHeight = double(CGImageGetHeight(image));
  const double scale = std::max(width / imageWidth, height / imageHeight);
  const double drawWidth = imageWidth * scale, drawHeight = imageHeight * scale;
  CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
  CGContextDrawImage(context, CGRectMake((width - drawWidth) / 2, (height - drawHeight) / 2, drawWidth, drawHeight), image);
  CGContextRelease(context);
  return true;
}
}
