#include "AEConfig.h"
#include "entry.h"
#include "AE_Effect.h"
#include "AE_EffectCB.h"
#include "AE_EffectSuites.h"
#include "AE_EffectCBSuites.h"
#include "AE_EffectPixelFormat.h"
#include "AE_EffectGPUSuites.h"
#include "AE_Macros.h"
#include "Param_Utils.h"
#include "PrSDKAESupport.h"
#include "AdobeSuites.h"
#include "AdobeParameters.h"
#include "AdobeBanner.h"
#include "SpektraRenderer.h"
#ifdef __APPLE__
#include "spektrafilm_adobe/MetalBridge.h"
#endif
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

using namespace spektrafilm;
using namespace spektrafilm::adobe;

namespace {
PF_Err report(PF_OutData* output, const char* message) {
  std::snprintf(output->return_msg, sizeof(output->return_msg), "%s", message);
  output->out_flags |= PF_OutFlag_DISPLAY_ERROR_MESSAGE;
  return PF_Err_INTERNAL_STRUCT_DAMAGED;
}

// The banner's arbitrary data in Premiere: four zero bytes, all values equal.
PF_Err newBannerData(PF_InData* in_data, PF_ArbitraryH* data) {
  *data = PF_NEW_HANDLE(sizeof(A_long));
  if (!*data) return PF_Err_OUT_OF_MEMORY;
  if (void* p = PF_LOCK_HANDLE(*data)) { std::memset(p, 0, sizeof(A_long)); PF_UNLOCK_HANDLE(*data); }
  return PF_Err_NONE;
}

PF_Err bannerDataCallback(PF_InData* in_data, PF_ArbParamsExtra* extra) {
  if (!extra || extra->id != Banner) return PF_Err_NONE;
  auto& u = extra->u;
  switch (extra->which_function) {
    case PF_Arbitrary_NEW_FUNC: return newBannerData(in_data, u.new_func_params.arbPH);
    case PF_Arbitrary_DISPOSE_FUNC:
      if (u.dispose_func_params.arbH) PF_DISPOSE_HANDLE(u.dispose_func_params.arbH);
      return PF_Err_NONE;
    case PF_Arbitrary_COPY_FUNC: return newBannerData(in_data, u.copy_func_params.dst_arbPH);
    case PF_Arbitrary_FLAT_SIZE_FUNC: *u.flat_size_func_params.flat_data_sizePLu = sizeof(A_long); return PF_Err_NONE;
    case PF_Arbitrary_FLATTEN_FUNC:
      if (u.flatten_func_params.buf_sizeLu < sizeof(A_long)) return PF_Err_INTERNAL_STRUCT_DAMAGED;
      std::memset(u.flatten_func_params.flat_dataPV, 0, sizeof(A_long));
      return PF_Err_NONE;
    case PF_Arbitrary_UNFLATTEN_FUNC: return newBannerData(in_data, u.unflatten_func_params.arbPH);
    case PF_Arbitrary_INTERP_FUNC: return newBannerData(in_data, u.interp_func_params.interpPH);
    case PF_Arbitrary_COMPARE_FUNC: *u.compare_func_params.compareP = PF_ArbCompare_EQUAL; return PF_Err_NONE;
    case PF_Arbitrary_PRINT_SIZE_FUNC: *u.print_size_func_params.print_sizePLu = 1; return PF_Err_NONE;
    case PF_Arbitrary_PRINT_FUNC:
      if (u.print_func_params.print_sizeLu) u.print_func_params.print_bufferPC[0] = 0;
      return PF_Err_NONE;
    case PF_Arbitrary_SCAN_FUNC: return newBannerData(in_data, u.scan_func_params.arbPH);
    default: return PF_Err_NONE;
  }
}

PF_Err setupParameters(PF_InData* in_data, PF_OutData* out_data) {
  PF_ParamDef def{};
  std::string films, papers, spaces;
  for (uint32_t i = 0; i < kSpektraFilmCount; ++i) {
    if (i) films += '|'; films += filmProfileCurves(i)->name;
  }
  for (uint32_t i = 0; i < kSpektraPaperCount; ++i) {
    if (i) papers += '|'; papers += paperProfileCurves(i)->name;
  }
  for (int i = 0; i < 26; ++i) { if (i) spaces += '|'; spaces += colorSpaceLabel(i); }
  auto slider = [&](int id) -> PF_Err {
    const FloatSpec s = floatSpec(id);
    PF_ADD_FLOAT_SLIDERX(s.name, s.min, s.max, s.sliderMin, s.sliderMax, s.initial, s.precision, 0, 0, id);
    return PF_Err_NONE;
  };
  auto sliders = [&](int first, int last) -> PF_Err {
    for (int id = first; id <= last; ++id) if (PF_Err err = slider(id)) return err;
    return PF_Err_NONE;
  };
  // The banner row: no value, drawn by the effect (PF_Event_DRAW). Premiere
  // draws custom controls only for arbitrary data parameters, as in the SDK's
  // Custom_ECW_UI sample, and send no draw events for a zero-width control;
  // After Effects also draws them on a null parameter.
  if (in_data->appl_id == kAppID_Premiere) {
    PF_ArbitraryH banner = nullptr;
    if (PF_Err err = newBannerData(in_data, &banner)) return err;
    PF_ADD_ARBITRARY2("", kBannerWidth, kBannerHeight, PF_ParamFlag_CANNOT_TIME_VARY, PF_PUI_CONTROL, banner, Banner, 0);
  } else {
    def.ui_flags = PF_PUI_CONTROL;
    def.ui_width = 0;
    def.ui_height = kBannerHeight;
    PF_ADD_NULL("", Banner);
  }
  PF_CustomUIInfo ui{};
  ui.events = PF_CustomEFlag_EFFECT;
  if (PF_Err err = PF_REGISTER_UI(in_data, &ui)) return err;
  def = {}; PF_ADD_POPUP("Film", kSpektraFilmCount, kSpektraDefaultFilmIndex + 1, films.c_str(), Film);
  def = {}; PF_ADD_POPUP("Print", kSpektraPaperCount, kSpektraDefaultPaperIndex + 1, papers.c_str(), Paper);
  def = {}; PF_ADD_POPUP("Film Format", kFilmFormatCount, filmFormatChoice(kDefaultFilmFormat), filmFormatChoices(), FilmFormatChoice);
  def = {}; PF_ADD_POPUP("Input Color Space", 26, int(ColorSpace::Srgb)+1, spaces.c_str(), InputSpace);
  def = {}; PF_ADD_POPUP("Output Color Space", 26, int(ColorSpace::Srgb)+1, spaces.c_str(), OutputSpace);
  if (PF_Err err = sliders(FilmExposure, PrintExposure)) return err;
  def = {}; PF_ADD_CHECKBOX("Grain", "Enable", FALSE, 0, Grain);
  if (PF_Err err = sliders(GrainAmount, GrainSaturation)) return err;
  // On by default, as in OFX. A new grain pattern every 1/24 s of layer time.
  def = {}; PF_ADD_CHECKBOX("Grain Animate", "Enable", TRUE, 0, GrainAnimate);
  def = {}; PF_ADD_CHECKBOX("Halation", "Enable", FALSE, 0, Halation);
  PF_ADD_TOPICX("Halation Controls", PF_ParamFlag_START_COLLAPSED, HalationTopic);
  if (PF_Err err = sliders(ScatterAmount, HalationProtectEv)) return err;
  def = {}; PF_END_TOPIC(HalationTopicEnd);
  for (const int base : {int(CameraDiffusion), int(PrintDiffusion)}) {
    const bool camera = base == CameraDiffusion;
    PF_ADD_TOPICX(camera ? "Camera Diffusion" : "Print Diffusion", PF_ParamFlag_START_COLLAPSED, base + DiffusionTopic);
    def = {}; PF_ADD_CHECKBOX(camera ? "Camera Diffusion" : "Print Diffusion", "Enable", FALSE, 0, base + DiffusionEnabled);
    def = {}; PF_ADD_POPUP(camera ? "Camera Family" : "Print Family", kDiffusionFamilyCount,
      int(DiffusionFilterFamily::BlackProMist)+1, diffusionFamilyChoices(), base + DiffusionFamily);
    if (PF_Err err = sliders(base + DiffusionStrength, base + DiffusionBloomSize)) return err;
    def = {}; PF_END_TOPIC(base + DiffusionTopicEnd);
  }
  out_data->num_params = ParameterCount;
  return PF_Err_NONE;
}

double valueOf(int i, const PF_ParamDef& p) {
  switch (parameterKind(i)) {
    case ParameterKind::Popup: return p.u.pd.value;
    case ParameterKind::Checkbox: return p.u.bd.value;
    case ParameterKind::Float: return p.u.fs_d.value;
    default: return 0;
  }
}
ParameterValues parameterValues(PF_ParamDef* params[]) {
  ParameterValues values{};
  for (int i = 1; i < ParameterCount; ++i)
    if (hasValue(i)) values[i] = valueOf(i, *params[i]);
  return values;
}

// Animated grain varies with time; otherwise frames of still sources can be cached.
PF_Err queryDynamicFlags(PF_InData* in_data, PF_OutData* out_data) {
  ParameterValues values{};
  for (const int i : {int(Grain), int(GrainAnimate)}) {
    PF_ParamDef p{};
    const PF_Err err = PF_CHECKOUT_PARAM(in_data, i, in_data->current_time,
      in_data->time_step, in_data->time_scale, &p);
    if (err) return err;
    values[i] = valueOf(i, p);
    if (const PF_Err checkin = PF_CHECKIN_PARAM(in_data, &p)) return checkin;
  }
  if (variesWithTime(values)) out_data->out_flags |= PF_OutFlag_NON_PARAM_VARY;
  else out_data->out_flags &= ~PF_OutFlag_NON_PARAM_VARY;
  return PF_Err_NONE;
}

PF_Err preRender(PF_InData* in_data, PF_PreRenderExtra* extra) {
  auto params = std::make_unique<RenderParams>();
  ParameterValues values{};
  for (int i = 1; i < ParameterCount; ++i) {
    if (!hasValue(i)) continue;
    PF_ParamDef p{};
    const PF_Err err = PF_CHECKOUT_PARAM(in_data, i, in_data->current_time,
      in_data->time_step, in_data->time_scale, &p);
    if (err) return err;
    values[i] = valueOf(i, p);
    const PF_Err checkin = PF_CHECKIN_PARAM(in_data, &p);
    if (checkin) return checkin;
  }
  *params = renderParams(values);
  PF_RenderRequest request = extra->input->output_request;
  // The film model includes spatial operations. Request the complete source,
  // and allow AE to return the entire result even for a smaller viewer request.
  request.rect = {0, 0, in_data->width, in_data->height};
  request.preserve_rgb_of_zero_alpha = TRUE;
  PF_CheckoutResult input{};
  const PF_Err err = extra->cb->checkout_layer(in_data->effect_ref, Input, Input,
    &request, in_data->current_time, in_data->time_step, in_data->time_scale, &input);
  if (err) return err;
  extra->output->result_rect = input.result_rect;
  extra->output->max_result_rect = input.max_result_rect;
  extra->output->flags |= PF_RenderOutputFlag_RETURNS_EXTRA_PIXELS;
#ifdef __APPLE__
  // Eligibility is declared before the host selects CPU/GPU rendering. gpu_data
  // is not required at this stage; GPU_DEVICE_SETUP negotiates device support.
  extra->output->flags |= PF_RenderOutputFlag_GPU_RENDER_POSSIBLE;
#endif
  extra->output->pre_render_data = params.release();
  extra->output->delete_pre_render_data_func = [](void* p) { delete static_cast<RenderParams*>(p); };
  return PF_Err_NONE;
}

PF_Err renderCpu(PF_InData* in_data, PF_OutData* out_data, PF_EffectWorld* input,
                 PF_EffectWorld* output, const RenderParams& params, PF_PixelFormat format) {
  if (!input || !output || !input->data || !output->data || input->width != output->width || input->height != output->height)
    return report(out_data, "spektrafilm currently requires matching full-frame input/output buffers.");
  if (output->width <= 0 || output->height <= 0) return PF_Err_NONE;
  const bool premiere = in_data->appl_id == kAppID_Premiere;
  int componentBytes = 4;
  if (!premiere) {
    if (format == PF_PixelFormat_ARGB32) componentBytes = 1;
    else if (format == PF_PixelFormat_ARGB64) componentBytes = 2;
    else if (format != PF_PixelFormat_ARGB128) return PF_Err_BAD_CALLBACK_PARAM;
  }
  const size_t w = output->width, h = output->height;
  if (w > size_t(INT32_MAX / 16) || h > SIZE_MAX / (w * 16)) return PF_Err_OUT_OF_MEMORY;
  struct CpuContext {
    std::unique_ptr<Renderer> renderer;
    std::vector<float> source, result;
  };
  // AE's MFR workers own independent pixels and renderer state. Reuse the
  // full-frame staging memory instead of allocating/zeroing it on every frame.
  thread_local CpuContext context;
  const size_t components = w*h*4;
  if (context.source.size() != components)
    std::vector<float>(components).swap(context.source);
  if (context.result.size() != components)
    std::vector<float>(components).swap(context.result);
  auto& source = context.source;
  auto& result = context.result;
  auto read = [&](const unsigned char* row, size_t c) -> float {
    if (componentBytes == 1) return row[c] / 255.0f;
    if (componentBytes == 2) { uint16_t v; std::memcpy(&v, row+c*2, 2); return v / 32768.0f; }
    float v; std::memcpy(&v, row+c*4, 4); return v;
  };
  auto write = [&](unsigned char* row, size_t c, float v) {
    if (componentBytes == 1) { row[c] = uint8_t(std::lround(std::clamp(v, 0.0f, 1.0f)*255)); return; }
    if (componentBytes == 2) { uint16_t u = uint16_t(std::lround(std::clamp(v, 0.0f, 1.0f)*32768)); std::memcpy(row+c*2, &u, 2); return; }
    std::memcpy(row+c*4, &v, 4);
  };
  for (size_t y = 0; y < h; ++y) {
    const auto* row = reinterpret_cast<const unsigned char*>(input->data) + ptrdiff_t(y)*input->rowbytes;
    for (size_t x = 0; x < w; ++x) {
      const size_t p = (y*w+x)*4, c = x*4;
      const float a = read(row, c+(premiere ? 3 : 0));
      source[p+3] = a;
      source[p] = a > 0 ? read(row, c+(premiere ? 2 : 1))/a : 0;
      source[p+1] = a > 0 ? read(row, c+(premiere ? 1 : 2))/a : 0;
      source[p+2] = a > 0 ? read(row, c+(premiere ? 0 : 3))/a : 0;
    }
  }
  if (!context.renderer) context.renderer = createNativeRenderer();
  auto& renderer = context.renderer;
  if (!renderer || !renderer->isAvailable()) return report(out_data, renderer ? renderer->lastError().c_str() : "Native renderer unavailable.");
  const ImageView from{source.data(), 0, 0, int32_t(w), int32_t(h), int32_t(w*16), 4, 4};
  const MutableImageView to{result.data(), 0, 0, int32_t(w), int32_t(h), int32_t(w*16), 4, 4};
  if (!renderer->render(from, to, {0, 0, int32_t(w), int32_t(h)}, params,
      in_data->time_scale ? double(in_data->current_time)/in_data->time_scale : 0))
    return report(out_data, renderer->lastError().c_str());
  for (size_t y = 0; y < h; ++y) {
    auto* row = reinterpret_cast<unsigned char*>(output->data) + ptrdiff_t(y)*output->rowbytes;
    for (size_t x = 0; x < w; ++x) {
      const size_t p = (y*w+x)*4, c = x*4;
      const float a = source[p+3];
      write(row, c+(premiere ? 3 : 0), a);
      write(row, c+(premiere ? 2 : 1), a > 0 ? result[p]*a : 0);
      write(row, c+(premiere ? 1 : 2), a > 0 ? result[p+1]*a : 0);
      write(row, c+(premiere ? 0 : 3), a > 0 ? result[p+2]*a : 0);
    }
  }
  return PF_Err_NONE;
}

PF_Err smartRender(PF_InData* in_data, PF_OutData* out_data, PF_SmartRenderExtra* extra, bool gpu) {
  auto* params = static_cast<const RenderParams*>(extra->input->pre_render_data);
  if (!params) return PF_Err_BAD_CALLBACK_PARAM;
  PF_EffectWorld *input = nullptr, *output = nullptr;
  PF_Err err = extra->cb->checkout_layer_pixels(in_data->effect_ref, Input, &input);
  if (err) return err;
  // Always check in the input, including allocation, suite, and render failures.
  try {
    err = extra->cb->checkout_output(in_data->effect_ref, &output);
    if (!err && input && output) {
      Suite<PF_WorldSuite2> worlds(in_data->pica_basicP, kPFWorldSuite, kPFWorldSuiteVersion2);
      PF_PixelFormat format = PF_PixelFormat_INVALID;
      err = worlds->PF_GetPixelFormat(input, &format);
      if (!err && gpu) {
#ifdef __APPLE__
        if (format != PF_PixelFormat_GPU_BGRA128 || extra->input->what_gpu != PF_GPU_Framework_METAL ||
            !extra->input->gpu_data || input->width != output->width || input->height != output->height)
          err = PF_Err_BAD_CALLBACK_PARAM;
        else {
          Suite<PF_GPUDeviceSuite1> devices(in_data->pica_basicP, kPFGPUDeviceSuite, kPFGPUDeviceSuiteVersion1);
          PF_GPUDeviceInfo info{}; void *src = nullptr, *dst = nullptr;
          err = devices->GetDeviceInfo(in_data->effect_ref, extra->input->device_index, &info);
          if (!err) err = devices->GetGPUWorldData(in_data->effect_ref, input, &src);
          if (!err) err = devices->GetGPUWorldData(in_data->effect_ref, output, &dst);
          auto* bridge = static_cast<MetalBridge*>(const_cast<void*>(extra->input->gpu_data));
          if (!err && !bridge->render(src, {uint32_t(input->width), uint32_t(input->height), uint64_t(input->rowbytes)},
              dst, {uint32_t(output->width), uint32_t(output->height), uint64_t(output->rowbytes)}, info.command_queuePV, *params,
              in_data->time_scale ? double(in_data->current_time)/in_data->time_scale : 0))
            err = report(out_data, bridge->lastError().c_str());
        }
#else
        err = PF_Err_BAD_CALLBACK_PARAM;
#endif
      } else if (!err) err = renderCpu(in_data, out_data, input, output, *params, format);
    }
  } catch (...) {
    extra->cb->checkin_layer_pixels(in_data->effect_ref, Input);
    throw;
  }
  const PF_Err checkin = extra->cb->checkin_layer_pixels(in_data->effect_ref, Input);
  return err ? err : checkin;
}
} // namespace

extern "C" DllExport PF_Err PluginDataEntryFunction2(PF_PluginDataPtr plugin,
    PF_PluginDataCB2 callback, SPBasicSuite*, const char*, const char*) {
  PF_Err result = PF_Err_NONE;
  PF_REGISTER_EFFECT_EXT2(plugin, callback, "spektrafilm", "org.spektrafilm.adobe",
    "spektrafilm", AE_RESERVED_INFO, "EffectMain", SPEKTRAFILM_SUPPORT_URL);
  return result;
}

extern "C" DllExport PF_Err EffectMain(PF_Cmd command, PF_InData* in_data, PF_OutData* out_data,
    PF_ParamDef* params[], PF_LayerDef* output, void* extra) {
  try {
    switch (command) {
      case PF_Cmd_ABOUT:
        std::snprintf(out_data->return_msg, sizeof(out_data->return_msg),
          "spektrafilm for Adobe " SPEKTRAFILM_VERSION "\rFilm model: spektrafilm by Andrea Volpato. "
          "Native engine: spektrafilm-ofx by Aedan Diez. GPL-3.0.");
        return PF_Err_NONE;
      case PF_Cmd_GLOBAL_SETUP:
        // Same value as AE_Effect_Version in the PiPL; both come from CMake.
        out_data->my_version = SPEKTRAFILM_PF_VERSION;
        // Keep in sync with SpektraFilmPiPL.r.
        out_data->out_flags = PF_OutFlag_DEEP_COLOR_AWARE | PF_OutFlag_NON_PARAM_VARY | PF_OutFlag_CUSTOM_UI;
        out_data->out_flags2 = PF_OutFlag2_FLOAT_COLOR_AWARE | PF_OutFlag2_SUPPORTS_SMART_RENDER |
          PF_OutFlag2_SUPPORTS_QUERY_DYNAMIC_FLAGS;
#ifdef __APPLE__
        out_data->out_flags2 |= PF_OutFlag2_SUPPORTS_THREADED_RENDERING;
#endif
        if (in_data->appl_id == kAppID_Premiere) {
          Suite<PF_PixelFormatSuite1> formats(in_data->pica_basicP, kPFPixelFormatSuite, kPFPixelFormatSuiteVersion1);
          PF_Err err = formats->ClearSupportedPixelFormats(in_data->effect_ref);
          return err ? err : formats->AddSupportedPixelFormat(in_data->effect_ref, PrPixelFormat_BGRA_4444_32f);
        }
#ifdef __APPLE__
        out_data->out_flags2 |= PF_OutFlag2_SUPPORTS_GPU_RENDER_F32;
#endif
        return PF_Err_NONE;
      case PF_Cmd_PARAMS_SETUP: return setupParameters(in_data, out_data);
      case PF_Cmd_ARBITRARY_CALLBACK: return bannerDataCallback(in_data, static_cast<PF_ArbParamsExtra*>(extra));
      case PF_Cmd_EVENT: {
        auto* event = static_cast<PF_EventExtra*>(extra);
        if (event && event->e_type == PF_Event_DRAW) drawBanner(in_data, event);
        return PF_Err_NONE;
      }
      case PF_Cmd_QUERY_DYNAMIC_FLAGS: return queryDynamicFlags(in_data, out_data);
      case PF_Cmd_SMART_PRE_RENDER: return preRender(in_data, static_cast<PF_PreRenderExtra*>(extra));
      case PF_Cmd_SMART_RENDER: return smartRender(in_data, out_data, static_cast<PF_SmartRenderExtra*>(extra), false);
      case PF_Cmd_SMART_RENDER_GPU: return smartRender(in_data, out_data, static_cast<PF_SmartRenderExtra*>(extra), true);
      case PF_Cmd_RENDER: {
        PF_PixelFormat format = PF_PixelFormat_ARGB32;
        if (in_data->appl_id == kAppID_Premiere) {
          Suite<PF_PixelFormatSuite1> formats(in_data->pica_basicP, kPFPixelFormatSuite, kPFPixelFormatSuiteVersion1);
          PrPixelFormat prFormat{};
          PF_Err err = formats->GetPixelFormat(&params[Input]->u.ld, &prFormat);
          if (err) return err;
          if (prFormat != PrPixelFormat_BGRA_4444_32f) return PF_Err_BAD_CALLBACK_PARAM;
        } else if (PF_WORLD_IS_DEEP(output)) format = PF_PixelFormat_ARGB64;
        return renderCpu(in_data, out_data, &params[Input]->u.ld, output, renderParams(parameterValues(params)), format);
      }
#ifdef __APPLE__
      case PF_Cmd_GPU_DEVICE_SETUP: {
        auto* setup = static_cast<PF_GPUDeviceSetupExtra*>(extra);
        setup->output->gpu_data = nullptr;
        out_data->out_flags2 = 0;
        if (setup->input->what_gpu != PF_GPU_Framework_METAL) return PF_Err_NONE;
        Suite<PF_GPUDeviceSuite1> devices(in_data->pica_basicP, kPFGPUDeviceSuite, kPFGPUDeviceSuiteVersion1);
        PF_GPUDeviceInfo info{};
        PF_Err err = devices->GetDeviceInfo(in_data->effect_ref, setup->input->device_index, &info);
        if (err) return err;
        auto bridge = std::make_unique<MetalBridge>();
        if (info.compatibleB && bridge->isAvailable() && bridge->usesDevice(info.devicePV)) {
          setup->output->gpu_data = bridge.release();
          out_data->out_flags2 = PF_OutFlag2_SUPPORTS_GPU_RENDER_F32;
        }
        return PF_Err_NONE;
      }
      case PF_Cmd_GPU_DEVICE_SETDOWN:
        delete static_cast<MetalBridge*>(static_cast<PF_GPUDeviceSetdownExtra*>(extra)->input->gpu_data);
        return PF_Err_NONE;
#endif
      default: return PF_Err_NONE;
    }
  } catch (const std::bad_alloc&) { return PF_Err_OUT_OF_MEMORY; }
    catch (const std::exception& error) { return report(out_data, error.what()); }
    catch (...) { return report(out_data, "Unexpected native renderer error."); }
}
