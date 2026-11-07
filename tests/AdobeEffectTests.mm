#include "AEConfig.h"
#include <cstdlib>
#include "AE_Effect.h"
#include "AE_EffectUI.h"
#include "AE_EffectCB.h"
#include "AE_EffectCBSuites.h"
#include "AE_EffectPixelFormat.h"
#include "AE_EffectGPUSuites.h"
#include "SPBasic.h"
#include "PrSDKTypes.h"
#include "PrSDKAESupport.h"
#include "PrSDKGPUFilter.h"
#include "PrSDKGPUDeviceSuite.h"
#include "PrSDKPPixSuite.h"
#include "PrSDKVideoSegmentSuite.h"
#include "PrSDKTimeSuite.h"
#include "AdobeParameters.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <cmath>
#include <cstring>
#include <iostream>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <atomic>
#include <thread>
#include <vector>
using namespace spektrafilm;
using namespace spektrafilm::adobe;

namespace {
void require(bool value, const char* message) {
  if (!value) { std::cerr << message << '\n'; std::exit(1); }
}
std::vector<PF_ParamDef> parameters(1);
PF_EffectWorld inputWorld{}, outputWorld{};
PF_PixelFormat aeFormat = PF_PixelFormat_ARGB128;
id<MTLDevice> device;
id<MTLCommandQueue> queue;
id<MTLBuffer> inputBuffer, outputBuffer;
PF_WorldSuite2 worlds{};
PF_GPUDeviceSuite1 aeDevices{};
PF_PixelFormatSuite1 formats{};
PrSDKGPUDeviceSuite prDevices{};
PrSDKPPixSuite pixels{};
PrSDKVideoSegmentSuite segments{};
PrSDKTimeSuite clockSuite{};
SPBasicSuite basic{};
int checkins = 0, paramCheckins = 0;
std::atomic<int> activeSuites{0};
int w = 7, h = 5;
bool benchmark = false;
int benchmarkCheckins = 0;
template<class Call> void measure(const char* name, Call call) {
  if (!benchmark) return;
  std::vector<double> samples;
  for (int i = 0; i < 12; ++i) {
    const auto start = std::chrono::steady_clock::now();
    require(!call(), name);
    samples.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now()-start).count());
  }
  std::sort(samples.begin(), samples.end());
  std::cout << std::fixed << std::setprecision(3) << "{\"path\":\"" << name
    << "\",\"width\":" << w << ",\"height\":" << h << ",\"median_ms\":" << samples[6]
    << ",\"p95_ms\":" << samples[11] << ",\"fps\":" << 1000/samples[6] << "}\n";
}
PPixHand sourcePix = reinterpret_cast<PPixHand>(&inputWorld);
PPixHand destPix = reinterpret_cast<PPixHand>(&outputWorld);

SPErr acquire(const char* name, int32 version, const void** result) {
  *result = nullptr;
  // Model an installed host without the v9 suite added to the downloaded SDK.
  if (!std::strcmp(name, kPrSDKVideoSegmentSuite) && version > kPrSDKVideoSegmentSuiteVersion4) return -1;
  if (!std::strcmp(name, kPFWorldSuite)) *result = &worlds;
  else if (!std::strcmp(name, kPFGPUDeviceSuite)) *result = &aeDevices;
  else if (!std::strcmp(name, kPFPixelFormatSuite)) *result = &formats;
  else if (!std::strcmp(name, kPrSDKGPUDeviceSuite)) *result = &prDevices;
  else if (!std::strcmp(name, kPrSDKPPixSuite)) *result = &pixels;
  else if (!std::strcmp(name, kPrSDKVideoSegmentSuite)) *result = &segments;
  else if (!std::strcmp(name, kPrSDKTimeSuite)) *result = &clockSuite;
  if (!*result) return -1;
  ++activeSuites;
  return 0;
}

void configureSuites() {
  basic.AcquireSuite = acquire;
  basic.ReleaseSuite = [](const char*, int32) -> SPErr { --activeSuites; return 0; };
  worlds.PF_GetPixelFormat = [](const PF_EffectWorld*, PF_PixelFormat* format) -> PF_Err { *format = aeFormat; return 0; };
  aeDevices.GetDeviceInfo = [](PF_ProgPtr, A_u_long, PF_GPUDeviceInfo* info) -> PF_Err {
    *info = {}; info->compatibleB = TRUE; info->device_framework = PF_GPU_Framework_METAL;
    info->devicePV = (__bridge void*)device; info->command_queuePV = (__bridge void*)queue; return 0;
  };
  aeDevices.GetGPUWorldData = [](PF_ProgPtr, PF_EffectWorld* world, void** value) -> PF_Err {
    *value = world == &inputWorld ? (__bridge void*)inputBuffer : (__bridge void*)outputBuffer; return 0;
  };
  formats.ClearSupportedPixelFormats = [](PF_ProgPtr) -> PF_Err { return 0; };
  formats.AddSupportedPixelFormat = [](PF_ProgPtr, PrPixelFormat format) -> PF_Err {
    return format == PrPixelFormat_BGRA_4444_32f ? 0 : PF_Err_BAD_CALLBACK_PARAM;
  };
  formats.GetPixelFormat = [](PF_EffectWorld*, PrPixelFormat* format) -> PF_Err {
    *format = PrPixelFormat_BGRA_4444_32f; return 0;
  };
  prDevices.GetDeviceInfo = [](csSDK_uint32, csSDK_uint32, PrGPUDeviceInfo* info) -> prSuiteError {
    *info = {}; info->outDeviceFramework = PrGPUDeviceFramework_Metal;
    info->outMeetsMinimumRequirementsForAcceleration = kPrTrue;
    info->outDeviceHandle = (__bridge void*)device;
    info->outCommandQueueHandle = (__bridge void*)queue; return 0;
  };
  prDevices.GetGPUPPixData = [](PPixHand pix, void** value) -> prSuiteError {
    *value = pix == sourcePix ? (__bridge void*)inputBuffer : (__bridge void*)outputBuffer; return 0;
  };
  pixels.GetPixelFormat = [](PPixHand, PrPixelFormat* format) -> prSuiteError {
    *format = PrPixelFormat_GPU_BGRA_4444_32f; return 0;
  };
  pixels.GetBounds = [](PPixHand, prRect* rect) -> prSuiteError {
    rect->left = rect->top = 0; rect->right = w; rect->bottom = h; return 0;
  };
  pixels.GetRowBytes = [](PPixHand, csSDK_int32* bytes) -> prSuiteError { *bytes = w*16; return 0; };
  clockSuite.GetTicksPerSecond = [](PrTime* ticks) -> prSuiteError { *ticks = 1000; return 0; };
  segments.GetParam = [](csSDK_int32, csSDK_int32 index, PrTime, PrParam* value) -> prSuiteError {
    const auto& p = parameters.at(index+1);
    if (p.param_type == PF_Param_POPUP) { value->mType = kPrParamType_Int32; value->mInt32 = p.u.pd.value; }
    else if (p.param_type == PF_Param_CHECKBOX) { value->mType = kPrParamType_Bool; value->mBool = p.u.bd.value; }
    else { value->mType = kPrParamType_Float64; value->mFloat64 = p.u.fs_d.value; }
    return 0;
  };
}
}

int main(int argc, char** argv) {
  @autoreleasepool {
    require(argc == 2 || argc == 4 || argc == 5, "Pass plugin binary [width height [BGRA.f32]].");
    if (argc >= 4) { w = std::stoi(argv[2]); h = std::stoi(argv[3]); benchmark = true; }
    require(w > 0 && h > 0 && w <= 8192 && h <= 8192, "Dimensions out of range.");
    device = MTLCreateSystemDefaultDevice();
    if (!device) return 77;
    queue = [device newCommandQueue];
    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    require(library, dlerror());
    using Effect = PF_Err (*)(PF_Cmd, PF_InData*, PF_OutData*, PF_ParamDef*[], PF_LayerDef*, void*);
    auto effect = reinterpret_cast<Effect>(dlsym(library, "EffectMain"));
    require(effect, "EffectMain export");
    configureSuites();
    PF_InData in{}; PF_OutData out{};
    in.appl_id = 'FXTC'; in.width = w; in.height = h; in.time_scale = 1000;
    in.pica_basicP = &basic;
    in.inter.add_param = [](PF_ProgPtr, PF_ParamIndex, PF_ParamDef* p) -> PF_Err { parameters.push_back(*p); return 0; };
    in.inter.checkout_param = [](PF_ProgPtr, PF_ParamIndex index, A_long, A_long, A_u_long, PF_ParamDef* p) -> PF_Err {
      *p = parameters.at(index); return 0;
    };
    in.inter.checkin_param = [](PF_ProgPtr, PF_ParamDef*) -> PF_Err { ++paramCheckins; return 0; };
    static int registeredUi = 0;
    in.inter.register_ui = [](PF_ProgPtr, PF_CustomUIInfo* ui) -> PF_Err {
      require(ui->events & PF_CustomEFlag_EFFECT, "Banner draws in the Effect Controls panel"); ++registeredUi; return 0; };
    require(!effect(PF_Cmd_GLOBAL_SETUP, &in, &out, nullptr, nullptr, nullptr), "AE global setup");
    require(out.out_flags2 & PF_OutFlag2_SUPPORTS_THREADED_RENDERING, "AE declares verified threaded rendering");
    require((out.out_flags & PF_OutFlag_NON_PARAM_VARY) && (out.out_flags2 & PF_OutFlag2_SUPPORTS_QUERY_DYNAMIC_FLAGS),
      "Time-varying output declared globally and refined per frame");
    require(!effect(PF_Cmd_PARAMS_SETUP, &in, &out, nullptr, nullptr, nullptr), "Parameter registration");
    require(parameters.size() == ParameterCount && out.num_params == ParameterCount, "Stable parameter count");
    {
      // Premiere draws custom controls only on arbitrary data parameters. The
      // banner's data must survive every arbitrary data callback.
      static int liveHandles = 0;
      PF_UtilCallbacks utils{};
      utils.host_new_handle = [](A_u_longlong size) -> PF_Handle {
        ++liveHandles; auto h = new void*; *h = std::calloc(1, size_t(size)); return reinterpret_cast<PF_Handle>(h); };
      utils.host_lock_handle = [](PF_Handle h) -> void* { return *reinterpret_cast<void**>(h); };
      utils.host_unlock_handle = [](PF_Handle) {};
      utils.host_dispose_handle = [](PF_Handle h) {
        --liveHandles; std::free(*reinterpret_cast<void**>(h)); delete reinterpret_cast<void**>(h); };
      const auto aeParameters = parameters;
      const int aeUi = registeredUi;
      parameters.resize(1);  // the input layer, as before the AE registration
      PF_InData pr = in; pr.appl_id = kAppID_Premiere; pr.utils = &utils;
      PF_OutData prOut{};
      require(!effect(PF_Cmd_PARAMS_SETUP, &pr, &prOut, nullptr, nullptr, nullptr), "Premiere parameter registration");
      require(parameters.size() == ParameterCount && parameters[Banner].param_type == PF_Param_ARBITRARY_DATA &&
        (parameters[Banner].ui_flags & PF_PUI_CONTROL) && parameters[Banner].ui_height > 0 &&
        parameters[Banner].ui_width > 0 && (parameters[Banner].flags & PF_ParamFlag_CANNOT_TIME_VARY) &&
        parameters[Banner].u.arb_d.dephault, "Premiere banner is an arbitrary data control");
      PF_ArbitraryH dephault = parameters[Banner].u.arb_d.dephault, copy = nullptr, unflat = nullptr;
      auto call = [&](PF_ArbParamsExtra& extra) {
        extra.id = Banner;
        require(!effect(PF_Cmd_ARBITRARY_CALLBACK, &pr, &prOut, nullptr, nullptr, &extra), "Banner arbitrary callback");
      };
      PF_ArbParamsExtra e{}; e.which_function = PF_Arbitrary_COPY_FUNC;
      e.u.copy_func_params.src_arbH = dephault; e.u.copy_func_params.dst_arbPH = &copy; call(e);
      A_u_long flatSize = 0; e = {}; e.which_function = PF_Arbitrary_FLAT_SIZE_FUNC;
      e.u.flat_size_func_params.arbH = copy; e.u.flat_size_func_params.flat_data_sizePLu = &flatSize; call(e);
      std::vector<char> flat(flatSize); e = {}; e.which_function = PF_Arbitrary_FLATTEN_FUNC;
      e.u.flatten_func_params.arbH = copy; e.u.flatten_func_params.buf_sizeLu = flatSize;
      e.u.flatten_func_params.flat_dataPV = flat.data(); call(e);
      e = {}; e.which_function = PF_Arbitrary_UNFLATTEN_FUNC; e.u.unflatten_func_params.buf_sizeLu = flatSize;
      e.u.unflatten_func_params.flat_dataPV = flat.data(); e.u.unflatten_func_params.arbPH = &unflat; call(e);
      PF_ArbCompareResult same = PF_ArbCompare_NOT_EQUAL; e = {}; e.which_function = PF_Arbitrary_COMPARE_FUNC;
      e.u.compare_func_params.a_arbH = copy; e.u.compare_func_params.b_arbH = unflat;
      e.u.compare_func_params.compareP = &same; call(e);
      require(copy && unflat && flatSize > 0 && same == PF_ArbCompare_EQUAL, "Banner data copies and round-trips");
      for (PF_ArbitraryH h : {dephault, copy, unflat}) {
        e = {}; e.which_function = PF_Arbitrary_DISPOSE_FUNC; e.u.dispose_func_params.arbH = h; call(e);
      }
      require(liveHandles == 0, "Banner data handles are released");
      parameters = aeParameters;
      registeredUi = aeUi;
    }
    std::vector<PF_ParamDef*> ptrs; for (auto& p : parameters) ptrs.push_back(&p);
    std::vector<float> argb(w*h*4), cpu(w*h*4), bgra(w*h*4);
    for (int p = 0; p < w*h; ++p) {
      const float a = float(p%4)/3;
      argb[p*4] = a; argb[p*4+1] = .18f*a; argb[p*4+2] = .35f*a; argb[p*4+3] = .6f*a;
      bgra[p*4] = argb[p*4+3]; bgra[p*4+1] = argb[p*4+2]; bgra[p*4+2] = argb[p*4+1]; bgra[p*4+3] = a;
    }
    if (argc == 5) {
      std::ifstream file(argv[4], std::ios::binary);
      file.read(reinterpret_cast<char*>(bgra.data()), bgra.size()*4);
      require(bool(file), "Cannot read input frame.");
      for (int p = 0; p < w*h; ++p) {
        argb[p*4] = bgra[p*4+3]; argb[p*4+1] = bgra[p*4+2];
        argb[p*4+2] = bgra[p*4+1]; argb[p*4+3] = bgra[p*4];
      }
    }
    inputWorld.width = outputWorld.width = w; inputWorld.height = outputWorld.height = h;
    inputWorld.rowbytes = outputWorld.rowbytes = w*16;
    inputWorld.data = reinterpret_cast<PF_PixelPtr>(argb.data());
    outputWorld.data = reinterpret_cast<PF_PixelPtr>(cpu.data());
    PF_PreRenderInput preInput{}; PF_PreRenderOutput preOutput{}; PF_PreRenderCallbacks preCallbacks{};
    preCallbacks.checkout_layer = [](PF_ProgPtr, PF_ParamIndex, A_long, const PF_RenderRequest* request,
        A_long, A_long, A_u_long, PF_CheckoutResult* result) -> PF_Err {
      require(request->rect.right == w && request->rect.bottom == h, "Complete spatial input requested");
      result->result_rect = result->max_result_rect = {0, 0, w, h}; return 0;
    };
    PF_PreRenderExtra pre{&preInput, &preOutput, &preCallbacks};
    require(!effect(PF_Cmd_SMART_PRE_RENDER, &in, &out, nullptr, nullptr, &pre), "Smart pre-render");
    require(preOutput.flags & PF_RenderOutputFlag_GPU_RENDER_POSSIBLE, "GPU eligibility precedes device selection");
    int valueParameters = 0;
    for (int i = 1; i < ParameterCount; ++i) valueParameters += hasValue(i);
    require(paramCheckins == valueParameters, "Every checked out parameter is checked in");
    {
      // The AE index is the parameter ID, and topics enclose their controls.
      for (int i = 1; i < ParameterCount; ++i) {
        require(parameters[i].uu.id == i, "Parameter ID equals its stable index");
        const auto type = parameters[i].param_type;
        if (i == Banner) {
          require(type == PF_Param_NO_DATA && (parameters[i].ui_flags & PF_PUI_CONTROL) &&
            parameters[i].ui_height > 0 && registeredUi == 1, "Banner row with custom UI");
        } else if (parameterKind(i) == ParameterKind::Group) {
          const bool start = i == HalationTopic || (i >= CameraDiffusion && (i - CameraDiffusion) % DiffusionFieldCount == DiffusionTopic);
          require(type == (start ? PF_Param_GROUP_START : PF_Param_GROUP_END), "Topic boundaries");
        } else {
          require(type == (parameterKind(i) == ParameterKind::Popup ? PF_Param_POPUP :
            parameterKind(i) == ParameterKind::Checkbox ? PF_Param_CHECKBOX : PF_Param_FLOAT_SLIDER), "Parameter kind");
        }
      }
      // Defaults follow the engine, except the Super 35 frame and half grain saturation.
      const RenderParams base{};
      const auto& d = *static_cast<RenderParams*>(preOutput.pre_render_data);
      require(d.filmFormat == FilmFormat::Super35 && d.grainSaturation == 0.5f && d.grainAmount == base.grainAmount,
        "Super 35 and grain saturation 0.5 by default");
      require(d.scatterAmount == base.scatterAmount &&
        d.scatterScale == base.scatterScale && d.halationAmount == base.halationAmount &&
        d.halationScale == base.halationScale && d.halationStrengthR == base.halationStrengthR &&
        d.halationStrengthG == base.halationStrengthG && d.halationStrengthB == base.halationStrengthB &&
        d.halationBoostEv == base.halationBoostEv && d.halationBoostRange == base.halationBoostRange &&
        d.halationProtectEv == base.halationProtectEv, "Halation defaults");
      require(d.grainAnimate, "Grain animates by default, as in OFX");
      // The tables say which spektrafilm they follow; only the reference model
      // compresses input chromaticities. OFX curve smoothing and output
      // compression stay off in both.
      require(colorAdaptationFlags(d) == (kSpektraReferenceModel ? uint32_t(kColorAdaptationInputCompression) : 0u),
        "Input gamut compression follows the table model");
      auto sameDiffusion = [](bool e, DiffusionFilterFamily f, std::array<float, 9> v,
                              bool be, DiffusionFilterFamily bf, std::array<float, 9> bv) { return e == be && f == bf && v == bv; };
      require(sameDiffusion(d.cameraDiffusionEnabled, d.cameraDiffusionFamily, {d.cameraDiffusionStrength,
          d.cameraDiffusionSpatialScale, d.cameraDiffusionHaloWarmth, d.cameraDiffusionCoreIntensity, d.cameraDiffusionCoreSize,
          d.cameraDiffusionHaloIntensity, d.cameraDiffusionHaloSize, d.cameraDiffusionBloomIntensity, d.cameraDiffusionBloomSize},
        base.cameraDiffusionEnabled, base.cameraDiffusionFamily, {base.cameraDiffusionStrength,
          base.cameraDiffusionSpatialScale, base.cameraDiffusionHaloWarmth, base.cameraDiffusionCoreIntensity, base.cameraDiffusionCoreSize,
          base.cameraDiffusionHaloIntensity, base.cameraDiffusionHaloSize, base.cameraDiffusionBloomIntensity, base.cameraDiffusionBloomSize}) &&
        sameDiffusion(d.printDiffusionEnabled, d.printDiffusionFamily, {d.printDiffusionStrength,
          d.printDiffusionSpatialScale, d.printDiffusionHaloWarmth, d.printDiffusionCoreIntensity, d.printDiffusionCoreSize,
          d.printDiffusionHaloIntensity, d.printDiffusionHaloSize, d.printDiffusionBloomIntensity, d.printDiffusionBloomSize},
        base.printDiffusionEnabled, base.printDiffusionFamily, {base.printDiffusionStrength,
          base.printDiffusionSpatialScale, base.printDiffusionHaloWarmth, base.printDiffusionCoreIntensity, base.printDiffusionCoreSize,
          base.printDiffusionHaloIntensity, base.printDiffusionHaloSize, base.printDiffusionBloomIntensity, base.printDiffusionBloomSize}),
        "Diffusion defaults");
      // Edited controls reach the engine.
      const auto saved = parameters;
      parameters[FilmFormatChoice].u.pd.value = 2;                     // Super 8
      parameters[GrainSaturation].u.fs_d.value = 0.25;
      parameters[HalationStrengthR].u.fs_d.value = 0.12;
      parameters[HalationBoostEv].u.fs_d.value = 99;                   // clamped to 20
      parameters[CameraDiffusion + DiffusionEnabled].u.bd.value = TRUE;
      parameters[PrintDiffusion + DiffusionFamily].u.pd.value = 4;     // CineBloom
      parameters[PrintDiffusion + DiffusionBloomSize].u.fs_d.value = 2.5;
      parameters[GrainAnimate].u.bd.value = FALSE;
      PF_PreRenderOutput edited{};
      PF_PreRenderExtra editedPre{&preInput, &edited, &preCallbacks};
      require(!effect(PF_Cmd_SMART_PRE_RENDER, &in, &out, nullptr, nullptr, &editedPre), "Edited pre-render");
      const auto& e = *static_cast<RenderParams*>(edited.pre_render_data);
      require(e.filmFormat == FilmFormat::Super8 && e.grainSaturation == 0.25f && std::abs(e.halationStrengthR - 0.12f) < 1e-6f &&
        e.halationBoostEv == 20.0f && e.cameraDiffusionEnabled && !e.printDiffusionEnabled &&
        e.printDiffusionFamily == DiffusionFilterFamily::CineBloom && e.printDiffusionBloomSize == 2.5f &&
        e.cameraDiffusionFamily == DiffusionFilterFamily::BlackProMist && !e.grainAnimate,
        "Edited controls reach RenderParams");
      edited.delete_pre_render_data_func(edited.pre_render_data);
      parameters = saved;
      // Only animated grain makes still sources vary over time.
      auto timeVarying = [&](bool grain, bool animate) {
        parameters[Grain].u.bd.value = grain;
        parameters[GrainAnimate].u.bd.value = animate;
        PF_OutData flags{}; flags.out_flags = PF_OutFlag_DEEP_COLOR_AWARE | PF_OutFlag_NON_PARAM_VARY;
        require(!effect(PF_Cmd_QUERY_DYNAMIC_FLAGS, &in, &flags, nullptr, nullptr, nullptr), "Dynamic flags query");
        require(flags.out_flags & PF_OutFlag_DEEP_COLOR_AWARE, "Dynamic flags keep the other bits");
        return (flags.out_flags & PF_OutFlag_NON_PARAM_VARY) != 0;
      };
      require(!timeVarying(false, true) && timeVarying(true, true) && !timeVarying(true, false),
        "NON_PARAM_VARY follows animated grain");
      parameters = saved;
      paramCheckins = 0;
    }
    PF_SmartRenderInput smartInput{}; smartInput.pre_render_data = preOutput.pre_render_data;
    PF_SmartRenderCallbacks smartCallbacks{};
    smartCallbacks.checkout_layer_pixels = [](PF_ProgPtr, A_long, PF_EffectWorld** world) -> PF_Err { *world = &inputWorld; return 0; };
    smartCallbacks.checkout_output = [](PF_ProgPtr, PF_EffectWorld** world) -> PF_Err { *world = &outputWorld; return 0; };
    smartCallbacks.checkin_layer_pixels = [](PF_ProgPtr, A_long) -> PF_Err { ++checkins; return 0; };
    PF_SmartRenderExtra smart{&smartInput, &smartCallbacks};
    require(!effect(PF_Cmd_SMART_RENDER, &in, &out, nullptr, nullptr, &smart), out.return_msg);
    require(checkins == 1, "CPU input checked in");
    measure("ae-cpu32", [&] { ++benchmarkCheckins; return effect(PF_Cmd_SMART_RENDER, &in, &out, nullptr, nullptr, &smart); });
    inputBuffer = [device newBufferWithBytes:bgra.data() length:bgra.size()*4 options:MTLResourceStorageModeShared];
    outputBuffer = [device newBufferWithLength:bgra.size()*4 options:MTLResourceStorageModeShared];
    PF_GPUDeviceSetupInput setupInput{PF_GPU_Framework_METAL, 0}; PF_GPUDeviceSetupOutput setupOutput{};
    PF_GPUDeviceSetupExtra setup{&setupInput, &setupOutput};
    require(!effect(PF_Cmd_GPU_DEVICE_SETUP, &in, &out, nullptr, nullptr, &setup) && setupOutput.gpu_data, "AE GPU device setup");
    smartInput.gpu_data = setupOutput.gpu_data; smartInput.what_gpu = PF_GPU_Framework_METAL;
    aeFormat = PF_PixelFormat_GPU_BGRA128;
    require(!effect(PF_Cmd_SMART_RENDER_GPU, &in, &out, nullptr, nullptr, &smart), out.return_msg);
    measure("ae-gpu", [&] { ++benchmarkCheckins; return effect(PF_Cmd_SMART_RENDER_GPU, &in, &out, nullptr, nullptr, &smart); });
    const float* gpu = static_cast<const float*>(outputBuffer.contents);
    for (int p = 0; p < w*h; ++p) {
      require(std::abs(cpu[p*4]-gpu[p*4+3]) < 1e-6f, "GPU alpha equals CPU");
      for (int c = 0; c < 3; ++c)
        require(std::isfinite(gpu[p*4+2-c]) && std::abs(cpu[p*4+1+c]-gpu[p*4+2-c]) < .0001f, "AE GPU equals software-frame path");
    }
    PF_GPUDeviceSetdownInput downInput{setupOutput.gpu_data, PF_GPU_Framework_METAL, 0};
    PF_GPUDeviceSetdownExtra down{&downInput};
    require(!effect(PF_Cmd_GPU_DEVICE_SETDOWN, &in, &out, nullptr, nullptr, &down), "GPU cleanup");
    for (int bytes : {1, 2}) {
      const int scale = bytes == 1 ? 255 : 32768;
      std::vector<uint8_t> integerInput(w*h*4*bytes), integerOutput(integerInput.size());
      std::vector<float> quantized(argb.size()), expected(argb.size());
      for (size_t i = 0; i < argb.size(); ++i) {
        const uint16_t q = uint16_t(std::lround(argb[i]*scale));
        quantized[i] = float(q)/scale;
        if (bytes == 1) integerInput[i] = uint8_t(q);
        else std::memcpy(integerInput.data()+i*2, &q, 2);
      }
      aeFormat = PF_PixelFormat_ARGB128;
      inputWorld.data = reinterpret_cast<PF_PixelPtr>(quantized.data());
      outputWorld.data = reinterpret_cast<PF_PixelPtr>(expected.data());
      require(!effect(PF_Cmd_SMART_RENDER, &in, &out, nullptr, nullptr, &smart), "Quantized float reference");
      inputWorld.data = reinterpret_cast<PF_PixelPtr>(integerInput.data());
      outputWorld.data = reinterpret_cast<PF_PixelPtr>(integerOutput.data());
      inputWorld.rowbytes = outputWorld.rowbytes = w*4*bytes;
      inputWorld.world_flags = outputWorld.world_flags = bytes == 2 ? PF_WorldFlag_DEEP : 0;
      parameters[Input].u.ld = inputWorld;
      require(!effect(PF_Cmd_RENDER, &in, &out, ptrs.data(), &outputWorld, nullptr), "AE integer render");
      measure(bytes == 1 ? "ae-cpu8" : "ae-cpu16", [&] { return effect(PF_Cmd_RENDER, &in, &out, ptrs.data(), &outputWorld, nullptr); });
      for (size_t i = 0; i < expected.size(); ++i) {
        uint16_t actual = integerOutput[i];
        if (bytes == 2) std::memcpy(&actual, integerOutput.data()+i*2, 2);
        const int wanted = int(std::lround(std::clamp(expected[i], 0.0f, 1.0f)*scale));
        require(std::abs(int(actual)-wanted) <= 1, "AE 8/16 bpc differs from float reference");
      }
      inputWorld.rowbytes = outputWorld.rowbytes = w*16;
      inputWorld.world_flags = outputWorld.world_flags = 0;
    }
    if (!benchmark) {
      struct Worker {
        PF_EffectWorld source{}, output{};
        std::vector<float> actual, expected;
        RenderParams settings;
        int checkedIn = 0;
      } workers[3];
      PF_SmartRenderCallbacks callbacks{};
      callbacks.checkout_layer_pixels = [](PF_ProgPtr ref, A_long, PF_EffectWorld** world) -> PF_Err {
        *world = &reinterpret_cast<Worker*>(ref)->source; return 0;
      };
      callbacks.checkout_output = [](PF_ProgPtr ref, PF_EffectWorld** world) -> PF_Err {
        *world = &reinterpret_cast<Worker*>(ref)->output; return 0;
      };
      callbacks.checkin_layer_pixels = [](PF_ProgPtr ref, A_long) -> PF_Err {
        ++reinterpret_cast<Worker*>(ref)->checkedIn; return 0;
      };
      aeFormat = PF_PixelFormat_ARGB128;
      auto renderWorker = [&](Worker& worker) {
        PF_InData input = in; input.effect_ref = reinterpret_cast<PF_ProgPtr>(&worker);
        PF_OutData output{};
        PF_SmartRenderInput request{}; request.pre_render_data = &worker.settings;
        PF_SmartRenderExtra render{&request, &callbacks};
        require(!effect(PF_Cmd_SMART_RENDER, &input, &output, nullptr, nullptr, &render), "Concurrent AE render");
      };
      for (int i = 0; i < 3; ++i) {
        auto& worker = workers[i];
        worker.settings = *static_cast<RenderParams*>(preOutput.pre_render_data);
        worker.settings.filmExposureEv = i*.375f;
        worker.actual.resize(argb.size());
        worker.source = inputWorld; worker.output = outputWorld;
        worker.source.data = reinterpret_cast<PF_PixelPtr>(argb.data());
        worker.output.data = reinterpret_cast<PF_PixelPtr>(worker.actual.data());
        renderWorker(worker);
        worker.expected = worker.actual;
      }
      std::vector<std::thread> threads;
      for (auto& worker : workers) threads.emplace_back([&, ptr = &worker] {
        @autoreleasepool {
          for (int frame = 0; frame < 3; ++frame) {
            renderWorker(*ptr);
            for (size_t i = 0; i < ptr->actual.size(); ++i)
              require(std::abs(ptr->actual[i]-ptr->expected[i]) < .0001f, "MFR state isolation");
          }
        }
      });
      for (auto& thread : threads) thread.join();
      for (const auto& worker : workers) require(worker.checkedIn == 4, "MFR callbacks checked in");
    }
    preOutput.delete_pre_render_data_func(preOutput.pre_render_data);

    using Entry = prSuiteError (*)(csSDK_uint32, csSDK_int32*, prBool, piSuitesPtr, PrGPUFilter*, PrGPUFilterInfo*);
    auto premiere = reinterpret_cast<Entry>(dlsym(library, "xGPUFilterEntry"));
    require(premiere, "Premiere GPU export");
    PlugUtilFuncs utilities{}; utilities.getSPBasicSuite = []() -> SPBasicSuite* { return &basic; };
    piSuites suites{}; suites.utilFuncs = &utilities;
    PrGPUFilter filter{}; PrGPUFilterInfo info{}; csSDK_int32 index = 0;
    require(!premiere(PrSDKGPUFilterInterfaceVersion, &index, kPrTrue, &suites, &filter, &info), "Premiere GPU startup");
    PrGPUFilterInstance instance{}; instance.piSuites = &suites;
    require(!filter.CreateInstance(&instance), "Premiere GPU create");
    PrGPUFilterRenderParams context{}; context.inRenderWidth = w; context.inRenderHeight = h;
    require(!filter.Render(&instance, &context, &sourcePix, 1, &destPix), "Premiere GPU render");
    measure("premiere-gpu", [&] { return filter.Render(&instance, &context, &sourcePix, 1, &destPix); });
    gpu = static_cast<const float*>(outputBuffer.contents);
    for (int p = 0; p < w*h; ++p) for (int c = 0; c < 3; ++c)
      require(std::isfinite(gpu[p*4+2-c]) && std::abs(cpu[p*4+1+c]-gpu[p*4+2-c]) < .0001f, "Premiere GPU equals AE CPU");
    int reversalCheckins = 0;
    if (!benchmark) {
      // Exercise the actual parameter translation in all three host entry paths.
      for (int p = 0; p < w*h; ++p) {
        const float gray = float(p)/(w*h-1);
        argb[p*4] = bgra[p*4+3] = 1;
        for (int c = 0; c < 3; ++c) argb[p*4+1+c] = bgra[p*4+c] = gray;
      }
      std::memcpy(inputBuffer.contents, bgra.data(), bgra.size()*4);
      inputWorld.data = reinterpret_cast<PF_PixelPtr>(argb.data());
      outputWorld.data = reinterpret_cast<PF_PixelPtr>(cpu.data());
      setupOutput = {};
      require(!effect(PF_Cmd_GPU_DEVICE_SETUP, &in, &out, nullptr, nullptr, &setup), "Reversal GPU setup");
      smartInput.gpu_data = setupOutput.gpu_data;
      for (int film = 17; film <= 20; ++film) {  // Ektachrome, Kodachrome, Velvia, Provia
        parameters[Film].u.pd.value = film;
        PF_PreRenderOutput reversal{};
        PF_PreRenderExtra request{&preInput, &reversal, &preCallbacks};
        require(!effect(PF_Cmd_SMART_PRE_RENDER, &in, &out, nullptr, nullptr, &request), "Reversal pre-render");
        require(static_cast<RenderParams*>(reversal.pre_render_data)->process == ProcessMode::ScanNegative,
          "Reversal profiles bypass negative printing");
        smartInput.pre_render_data = reversal.pre_render_data;
        aeFormat = PF_PixelFormat_ARGB128;
        require(!effect(PF_Cmd_SMART_RENDER, &in, &out, nullptr, nullptr, &smart), "Reversal AE CPU render");
        require(cpu[(w*h-1)*4+2] > cpu[2]+.1f, "Reversal gray ramp keeps its polarity");
        aeFormat = PF_PixelFormat_GPU_BGRA128;
        require(!effect(PF_Cmd_SMART_RENDER_GPU, &in, &out, nullptr, nullptr, &smart), "Reversal AE GPU render");
        reversalCheckins += 2;
        auto compareReversal = [&] {
          const auto* actual = static_cast<const float*>(outputBuffer.contents);
          for (int p = 0; p < w*h; ++p) {
            require(actual[p*4+3] == 1, "Reversal alpha preserved");
            for (int c = 0; c < 3; ++c)
              require(std::isfinite(actual[p*4+2-c]) && std::abs(cpu[p*4+1+c]-actual[p*4+2-c]) < .0001f,
                "Reversal AE/Premiere GPU equals AE CPU");
          }
        };
        compareReversal();
        require(!filter.Render(&instance, &context, &sourcePix, 1, &destPix), "Reversal Premiere GPU render");
        compareReversal();
        reversal.delete_pre_render_data_func(reversal.pre_render_data);
      }
      downInput.gpu_data = setupOutput.gpu_data;
      require(!effect(PF_Cmd_GPU_DEVICE_SETDOWN, &in, &out, nullptr, nullptr, &down), "Reversal GPU cleanup");
      std::cout << "All four reversal stocks preserve polarity through AE CPU/GPU and Premiere GPU.\n";
    }
    require(!filter.DisposeInstance(&instance), "Premiere GPU dispose");
    require(!activeSuites, "All acquired suites released");
    require(checkins == 4 + benchmarkCheckins + reversalCheckins, "All CPU/GPU inputs checked in");
    std::cout << "Adobe ABI harness passed: registration, pre-render, AE 8/16/32 bpc, AE/Premiere GPU and cleanup.\n";
    // Keep the module loaded until process exit: its native software-frame cache
    // has thread-local state, as do host render workers.
  }
}
