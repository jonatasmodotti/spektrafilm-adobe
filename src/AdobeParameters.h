#pragma once
#include "SpektraParameters.h"
#include "SpektraProfileCurves.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <utility>

namespace spektrafilm::adobe {
// Fields of one diffusion filter group; camera and print use the same layout.
enum DiffusionField : int { DiffusionTopic, DiffusionEnabled, DiffusionFamily, DiffusionStrength,
                            DiffusionSpatialScale, DiffusionHaloWarmth, DiffusionCoreIntensity,
                            DiffusionCoreSize, DiffusionHaloIntensity, DiffusionHaloSize,
                            DiffusionBloomIntensity, DiffusionBloomSize, DiffusionTopicEnd,
                            DiffusionFieldCount };

// Indices are the AE parameter indices and disk IDs, and (minus one) the Premiere
// GPU parameter indices. During development they follow the panel order; once
// projects must survive updates, append instead of reordering.
enum Parameter : int { Input, Banner, Film, Paper, FilmFormatChoice, InputSpace, OutputSpace,
                       FilmExposure, PrintExposure,
                       Grain, GrainAmount, GrainSaturation, GrainAnimate,
                       Halation,
                       HalationTopic, ScatterAmount, ScatterScale, HalationAmount, HalationScale,
                       HalationStrengthR, HalationStrengthG, HalationStrengthB,
                       HalationBoostEv, HalationBoostRange, HalationProtectEv, HalationTopicEnd,
                       CameraDiffusion,
                       PrintDiffusion = CameraDiffusion + DiffusionFieldCount,
                       DiffusionEnd = PrintDiffusion + DiffusionFieldCount,
                       ParameterCount = DiffusionEnd };
using ParameterValues = std::array<double, ParameterCount>;

// Banner and Group rows carry no value.
enum class ParameterKind { Layer, Popup, Checkbox, Float, Group, Banner };


constexpr ParameterKind parameterKind(int i) {
  if (i == Input) return ParameterKind::Layer;
  if (i == Banner) return ParameterKind::Banner;
  if (i == Film || i == Paper || i == InputSpace || i == OutputSpace || i == FilmFormatChoice)
    return ParameterKind::Popup;
  if (i == Grain || i == Halation || i == GrainAnimate) return ParameterKind::Checkbox;
  if (i == HalationTopic || i == HalationTopicEnd) return ParameterKind::Group;
  if (i >= CameraDiffusion && i < DiffusionEnd) {
    const int field = (i - CameraDiffusion) % DiffusionFieldCount;
    if (field == DiffusionTopic || field == DiffusionTopicEnd) return ParameterKind::Group;
    if (field == DiffusionEnabled) return ParameterKind::Checkbox;
    if (field == DiffusionFamily) return ParameterKind::Popup;
  }
  return ParameterKind::Float;
}

constexpr bool hasValue(int i) {
  return parameterKind(i) != ParameterKind::Group && parameterKind(i) != ParameterKind::Banner;
}

struct FloatSpec { const char* name; double min, max, sliderMin, sliderMax, initial; int precision; };

// Ranges follow the OFX plugin, and so do the defaults, except Grain Saturation:
// at 1 the strong red and blue grain over weak green reads as a purple cast.
inline FloatSpec floatSpec(int i) {
  switch (i) {
    case FilmExposure: return {"Film Exposure (EV)", -10, 10, -5, 5, 0, 2};
    case PrintExposure: return {"Print Exposure (EV)", -10, 10, -5, 5, 0, 2};
    case GrainAmount: return {"Grain Amount", 0, 4, 0, 2, 1, 2};
    case GrainSaturation: return {"Grain Saturation", 0, 1, 0, 1, 0.5, 2};
    case ScatterAmount: return {"Scatter Amount", 0, 2, 0, 2, 1, 2};
    case ScatterScale: return {"Scatter Scale", 0, 4, 0, 4, 1, 2};
    case HalationAmount: return {"Halation Amount", 0, 4, 0, 4, 1, 2};
    case HalationScale: return {"Halation Scale", 0, 4, 0, 4, 1, 2};
    case HalationStrengthR: return {"Halation Strength R", 0, 1, 0, 0.2, 0.05, 3};
    case HalationStrengthG: return {"Halation Strength G", 0, 1, 0, 0.2, 0.015, 3};
    case HalationStrengthB: return {"Halation Strength B", 0, 1, 0, 0.2, 0, 3};
    case HalationBoostEv: return {"Halation Boost EV", 0, 20, 0, 10, 0, 2};
    case HalationBoostRange: return {"Halation Boost Range", 0, 1, 0, 1, 0.3, 2};
    case HalationProtectEv: return {"Halation Protect EV", 0, 10, 0, 10, 4, 2};
  }
  if (i >= CameraDiffusion && i < DiffusionEnd) {
    const bool camera = i < PrintDiffusion;
    switch ((i - CameraDiffusion) % DiffusionFieldCount) {
      case DiffusionStrength: return {camera ? "Camera Strength" : "Print Strength", 0, 2, 0, 2, 0.5, 2};
      case DiffusionSpatialScale: return {camera ? "Camera Spatial Scale" : "Print Spatial Scale", 0, 4, 0, 4, 1, 2};
      case DiffusionHaloWarmth: return {camera ? "Camera Halo Warmth" : "Print Halo Warmth", -1.5, 1.5, -1.5, 1.5, 0, 2};
      case DiffusionCoreIntensity: return {camera ? "Camera Core Intensity" : "Print Core Intensity", 0, 4, 0, 4, 1, 2};
      case DiffusionCoreSize: return {camera ? "Camera Core Size" : "Print Core Size", 0.1, 4, 0.1, 4, 1, 2};
      case DiffusionHaloIntensity: return {camera ? "Camera Halo Intensity" : "Print Halo Intensity", 0, 4, 0, 4, 1, 2};
      case DiffusionHaloSize: return {camera ? "Camera Halo Size" : "Print Halo Size", 0.1, 4, 0.1, 4, 1, 2};
      case DiffusionBloomIntensity: return {camera ? "Camera Bloom Intensity" : "Print Bloom Intensity", 0, 4, 0, 4, 1, 2};
      case DiffusionBloomSize: return {camera ? "Camera Bloom Size" : "Print Bloom Size", 0.1, 4, 0.1, 4, 1, 2};
    }
  }
  throw std::logic_error("Parameter is not a float slider.");
}

constexpr int kFilmFormatCount = 8;
constexpr int kDiffusionFamilyCount = 4;
// Popup order of the formats. Super 35 is the default.
constexpr std::array<FilmFormat, kFilmFormatCount> kFilmFormatOrder{
  FilmFormat::Standard8, FilmFormat::Super8, FilmFormat::Standard16, FilmFormat::Super16,
  FilmFormat::Standard35, FilmFormat::Standard65, FilmFormat::Super35, FilmFormat::Imax70};
inline const char* filmFormatChoices() {
  return "8mm|Super 8|16mm|Super 16|35mm Still (36x24)|65mm|Super 35|70mm / IMAX";
}
// One-based popup value of a format.
constexpr int filmFormatChoice(FilmFormat format) {
  for (int i = 0; i < kFilmFormatCount; ++i) if (kFilmFormatOrder[i] == format) return i + 1;
  return 0;
}
constexpr FilmFormat kDefaultFilmFormat = FilmFormat::Super35;
inline const char* diffusionFamilyChoices() { return "Glimmerglass|Black Pro-Mist|Pro-Mist|CineBloom"; }

// Output varies with time, beyond the parameter values, only for animated grain.
inline bool variesWithTime(const ParameterValues& v) { return v[Grain] != 0 && v[GrainAnimate] != 0; }

inline RenderParams renderParams(const ParameterValues& v) {
  for (double value : v) if (!std::isfinite(value)) throw std::invalid_argument("Non-finite effect parameter.");
  auto number = [&](int i) { const FloatSpec s = floatSpec(i); return float(std::clamp(v[i], s.min, s.max)); };
  auto choice = [&](int i, int count) { return int(std::clamp(v[i], 1.0, double(count))) - 1; };
  RenderParams p;
  if (kSpektraReferenceModel) {
    // spektrafilm eac6b85 and later compress input chromaticities toward the
    // spectral locus. The OFX curve smoothing has no counterpart there, and the
    // output keeps the hard clip until the CAM16-UCS compression is ported.
    p.colorAdaptation = true;
    p.colorAdaptationInputCompression = true;
    p.colorAdaptationCurveSmoothing = false;
    p.colorAdaptationOutputLightnessCompression = false;
    p.colorAdaptationOutputChromaCompression = false;
  }
  p.film = choice(Film, kSpektraFilmCount);
  p.paper = choice(Paper, kSpektraPaperCount);
  // Reversal film is already positive. Scan it directly; negative-working
  // print stock would reverse its tones a second time.
  if (std::strcmp(filmProfileCurves(p.film)->type, "positive") == 0)
    p.process = ProcessMode::ScanNegative;
  p.inputColorSpace = ColorSpace(choice(InputSpace, 26));
  p.outputColorSpace = ColorSpace(choice(OutputSpace, 26));
  p.filmExposureEv = number(FilmExposure);
  p.printExposureEv = number(PrintExposure);
  p.grainEnabled = v[Grain] != 0;
  p.grainAmount = number(GrainAmount);
  p.grainSaturation = number(GrainSaturation);
  p.grainAnimate = v[GrainAnimate] != 0;
  p.halationEnabled = v[Halation] != 0;
  p.filmFormat = kFilmFormatOrder[choice(FilmFormatChoice, kFilmFormatCount)];
  p.scatterAmount = number(ScatterAmount);
  p.scatterScale = number(ScatterScale);
  p.halationAmount = number(HalationAmount);
  p.halationScale = number(HalationScale);
  p.halationStrengthR = number(HalationStrengthR);
  p.halationStrengthG = number(HalationStrengthG);
  p.halationStrengthB = number(HalationStrengthB);
  p.halationBoostEv = number(HalationBoostEv);
  p.halationBoostRange = number(HalationBoostRange);
  p.halationProtectEv = number(HalationProtectEv);
  struct Diffusion {
    bool& enabled; DiffusionFilterFamily& family;
    float &strength, &spatialScale, &haloWarmth, &coreIntensity, &coreSize,
          &haloIntensity, &haloSize, &bloomIntensity, &bloomSize;
  };
  const Diffusion camera{p.cameraDiffusionEnabled, p.cameraDiffusionFamily, p.cameraDiffusionStrength,
    p.cameraDiffusionSpatialScale, p.cameraDiffusionHaloWarmth, p.cameraDiffusionCoreIntensity,
    p.cameraDiffusionCoreSize, p.cameraDiffusionHaloIntensity, p.cameraDiffusionHaloSize,
    p.cameraDiffusionBloomIntensity, p.cameraDiffusionBloomSize};
  const Diffusion print{p.printDiffusionEnabled, p.printDiffusionFamily, p.printDiffusionStrength,
    p.printDiffusionSpatialScale, p.printDiffusionHaloWarmth, p.printDiffusionCoreIntensity,
    p.printDiffusionCoreSize, p.printDiffusionHaloIntensity, p.printDiffusionHaloSize,
    p.printDiffusionBloomIntensity, p.printDiffusionBloomSize};
  for (const auto& [d, base] : {std::pair{camera, int(CameraDiffusion)}, std::pair{print, int(PrintDiffusion)}}) {
    d.enabled = v[base + DiffusionEnabled] != 0;
    d.family = DiffusionFilterFamily(choice(base + DiffusionFamily, kDiffusionFamilyCount));
    d.strength = number(base + DiffusionStrength);
    d.spatialScale = number(base + DiffusionSpatialScale);
    d.haloWarmth = number(base + DiffusionHaloWarmth);
    d.coreIntensity = number(base + DiffusionCoreIntensity);
    d.coreSize = number(base + DiffusionCoreSize);
    d.haloIntensity = number(base + DiffusionHaloIntensity);
    d.haloSize = number(base + DiffusionHaloSize);
    d.bloomIntensity = number(base + DiffusionBloomIntensity);
    d.bloomSize = number(base + DiffusionBloomSize);
  }
  return p;
}
} // namespace spektrafilm::adobe
