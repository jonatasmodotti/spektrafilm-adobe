#include "AEConfig.h"
#include "AE_Effect.h"
#include "AE_EffectCB.h"
#include "SPBasic.h"
#include "PrSDKTypes.h"
#include "PrSDKAESupport.h"
#include "PrSDKGPUFilter.h"
#include "PrSDKGPUDeviceSuite.h"
#include "PrSDKPPixSuite.h"
#include "PrSDKVideoSegmentSuite.h"
#include "PrSDKTimeSuite.h"
#include "AdobeSuites.h"
#include "AdobeParameters.h"
#include "spektrafilm_adobe/MetalBridge.h"
#include <memory>

using namespace spektrafilm;
using namespace spektrafilm::adobe;

namespace {
struct PremiereInstance {
  Suite<PrSDKGPUDeviceSuite> gpu;
  Suite<PrSDKPPixSuite> pixels;
  Suite<PrSDKVideoSegmentSuite> segments;
  Suite<PrSDKTimeSuite> clock;
  MetalBridge bridge;
  PrGPUDeviceInfo device{};
  PrTime ticksPerSecond = 0;

  explicit PremiereInstance(SPBasicSuite* basic)
    : gpu(basic, kPrSDKGPUDeviceSuite, kPrSDKGPUDeviceSuiteVersion),
      pixels(basic, kPrSDKPPixSuite, kPrSDKPPixSuiteVersion),
      // GetParam belongs to the v4 table. Requiring the SDK's newest v9 suite
      // unnecessarily rejects older installed hosts and selects CPU rendering.
      segments(basic, kPrSDKVideoSegmentSuite, kPrSDKVideoSegmentSuiteVersion4),
      clock(basic, kPrSDKTimeSuite, kPrSDKTimeSuiteVersion) {}
};

prSuiteError create(PrGPUFilterInstance* instance) {
  try {
    auto value = std::make_unique<PremiereInstance>(instance->piSuites->utilFuncs->getSPBasicSuite());
    auto err = value->gpu->GetDeviceInfo(kPrSDKGPUDeviceSuiteVersion, instance->inDeviceIndex, &value->device);
    if (err) return err;
    if (value->device.outDeviceFramework != PrGPUDeviceFramework_Metal ||
        !value->device.outMeetsMinimumRequirementsForAcceleration || !value->bridge.isAvailable() ||
        !value->bridge.usesDevice(value->device.outDeviceHandle)) return suiteError_Fail;
    err = value->clock->GetTicksPerSecond(&value->ticksPerSecond);
    if (err || !value->ticksPerSecond) return suiteError_Fail;
    instance->ioPrivatePluginData = value.release();
    instance->outIsRealtime = kPrFalse;
    return suiteError_NoError;
  } catch (...) { return suiteError_Fail; }
}

prSuiteError dispose(PrGPUFilterInstance* instance) {
  delete static_cast<PremiereInstance*>(instance->ioPrivatePluginData);
  instance->ioPrivatePluginData = nullptr;
  return suiteError_NoError;
}

double number(const PrParam& p) {
  switch (p.mType) {
    case kPrParamType_Int8: return p.mInt8;
    case kPrParamType_Int16: return p.mInt16;
    case kPrParamType_Int32: return p.mInt32;
    case kPrParamType_Int64: return double(p.mInt64);
    case kPrParamType_Float32: return p.mFloat32;
    case kPrParamType_Float64: return p.mFloat64;
    case kPrParamType_Bool: return p.mBool;
    default: throw std::runtime_error("Unsupported Premiere parameter type.");
  }
}

prSuiteError render(PrGPUFilterInstance* instance, const PrGPUFilterRenderParams* context,
    const PPixHand* frames, csSDK_size_t count, PPixHand* output) {
  try {
    if (!frames || !count || !output || !*output) return suiteError_InvalidParms;
    auto* value = static_cast<PremiereInstance*>(instance->ioPrivatePluginData);
    if (!value) return suiteError_Fail;
    ParameterValues values{};
    for (int i = 1; i < ParameterCount; ++i) {
      if (!hasValue(i)) continue;  // topics and the banner carry no value
      PrParam param{};
      const auto err = value->segments->GetParam(instance->inNodeID, i-1, context->inClipTime, &param);
      if (err) return err;
      values[i] = number(param);
    }
    const auto params = renderParams(values);
    PrPixelFormat srcFormat = PrPixelFormat_Invalid, dstFormat = PrPixelFormat_Invalid;
    auto err = value->pixels->GetPixelFormat(frames[0], &srcFormat);
    if (err) return err;
    err = value->pixels->GetPixelFormat(*output, &dstFormat);
    if (err) return err;
    if (srcFormat != dstFormat || (srcFormat != PrPixelFormat_GPU_BGRA_4444_32f &&
        srcFormat != PrPixelFormat_GPU_BGRA_4444_16f)) return suiteError_InvalidParms;
    prRect srcBounds{}, dstBounds{};
    csSDK_int32 srcPitch = 0, dstPitch = 0;
    void *src = nullptr, *dst = nullptr;
    if ((err = value->pixels->GetBounds(frames[0], &srcBounds)) ||
        (err = value->pixels->GetBounds(*output, &dstBounds)) ||
        (err = value->pixels->GetRowBytes(frames[0], &srcPitch)) ||
        (err = value->pixels->GetRowBytes(*output, &dstPitch)) ||
        (err = value->gpu->GetGPUPPixData(frames[0], &src)) ||
        (err = value->gpu->GetGPUPPixData(*output, &dst))) return err;
    const uint32_t bytes = srcFormat == PrPixelFormat_GPU_BGRA_4444_16f ? 2 : 4;
    const FrameLayout from{uint32_t(srcBounds.right-srcBounds.left), uint32_t(srcBounds.bottom-srcBounds.top),
      uint64_t(srcPitch), 0, ChannelOrder::BGRA, AlphaMode::Premultiplied, bytes};
    const FrameLayout to{uint32_t(dstBounds.right-dstBounds.left), uint32_t(dstBounds.bottom-dstBounds.top),
      uint64_t(dstPitch), 0, ChannelOrder::BGRA, AlphaMode::Premultiplied, bytes};
    return value->bridge.render(src, from, dst, to, value->device.outCommandQueueHandle, params,
      double(context->inClipTime)/value->ticksPerSecond) ? suiteError_NoError : suiteError_Fail;
  } catch (...) { return suiteError_Fail; }
}
}

extern "C" __attribute__((visibility("default"))) prSuiteError xGPUFilterEntry(
    csSDK_uint32 version, csSDK_int32* index, prBool startup, piSuitesPtr,
    PrGPUFilter* filter, PrGPUFilterInfo* info) {
  if (!startup) return suiteError_NoError;
  if (!index || *index != 0 || !filter || !info || version < PrSDKGPUFilterInterfaceVersion1)
    return suiteError_InvalidParms;
  *filter = {};
  filter->CreateInstance = create;
  filter->DisposeInstance = dispose;
  filter->Render = render;
  filter->GetFrameDependencies = [](PrGPUFilterInstance*, const PrGPUFilterRenderParams*,
      csSDK_int32*, PrGPUFilterFrameDependency*) { return suiteError_NotImplemented; };
  filter->Precompute = [](PrGPUFilterInstance*, const PrGPUFilterRenderParams*, csSDK_int32, PPixHand) {
    return suiteError_NotImplemented;
  };
  info->outInterfaceVersion = PrSDKGPUFilterInterfaceVersion;
  info->outMatchName = PrSDKString();
  return suiteError_NoError;
}
