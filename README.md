![spektrafilm](assets/banner.jpg)

# spektrafilm for Adobe

**English** · [Español](README.es.md) · [Português](README.pt-BR.md)

A native After Effects and Premiere Pro effect that brings
[spektrafilm](https://github.com/andreavolpato/spektrafilm), Andrea Volpato's
spectral film simulation, to Adobe hosts. It renders with the C++/GPU engine of
[spektrafilm-ofx](https://github.com/chaert-s/spektrafilm-ofx): Metal on macOS,
Vulkan on Windows.

**Version 0.1.0.** Tested in After Effects and Premiere Pro on macOS (Apple
Silicon). The Windows build is written and checked for compile errors but has
not run on Windows yet. There are no binary releases: build from source.

## What it does

The effect models the whole photochemical chain: the camera negative's
spectral sensitivity and development, printing onto paper or print film, and
scanning. Controls, in panel order:

- **Film** and **Print**: 20 camera stocks (Kodak Vision3, Portra, Ektar, Gold,
  Fujifilm, and reversal films) and 8 print papers and films.
- **Film Format**: 8mm to 70mm/IMAX, Super 35 by default. It sets the physical
  frame size, so grain, halation and diffusion, which have a size in µm, look
  larger on smaller formats.
- **Input Color Space** and **Output Color Space**: 26 spaces, including sRGB,
  Rec.709, Rec.2020, Display P3, ACES and camera log formats. Choose the ones
  that match your footage and project; the effect does not read the host's
  color management.
- **Film Exposure** and **Print Exposure**, in EV.
- **Grain**: amount, saturation and animation. Animated grain changes every
  1/24 s of layer time and repeats for the same instant.
- **Halation**: scatter, amount, size, per-channel strength, and highlight
  boost or protection.
- **Camera Diffusion** and **Print Diffusion**: Glimmerglass, Black Pro-Mist,
  Pro-Mist and CineBloom filters, with core, halo and bloom.

Kodak Ektachrome 100, Kodachrome 64, Fujifilm Velvia 100 and Provia 100F are
reversal (slide) films. They are scanned directly, so **Print**, **Print
Exposure** and **Print Diffusion** do not apply to them; use **Film Exposure**.

## Build

You need CMake 3.24 or later, Git, Python 3.11 or later, and the Adobe SDKs,
which Adobe does not allow to be redistributed. Download them from Adobe's
developer console and extract them so that these files exist:

```text
sdks/after-effects/Examples/Headers/AE_Effect.h
sdks/premiere/Examples/Headers/PrSDKGPUFilter.h      (macOS only)
```

- [After Effects C++ SDK](https://developer.adobe.com/console/servicesandapis/ae)
- [Premiere Pro C++ SDK](https://developer.adobe.com/console/servicesandapis/pr)

Other locations can be given with `-DSPEKTRAFILM_AE_SDK_ROOT=...` and
`-DSPEKTRAFILM_PR_SDK_ROOT=...`.

`tools/bootstrap.py` fetches spektrafilm-ofx and the spektrafilm profiles at the
commits pinned in `upstream.lock.json` and applies this port's patch. Python is
used only at build time, to generate the spectral tables.

### macOS

Xcode or the Command Line Tools.

```sh
python3 tools/bootstrap.py
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-build.txt
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DSPEKTRAFILM_BUILD_ADOBE_PLUGIN=ON
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

The plugin is `build/plugin/SpektraFilm.plugin`, signed ad hoc for local use.

### Windows

Visual Studio 2022 with the C++ workload (x64) and the
[Vulkan SDK](https://vulkan.lunarg.com/sdk/home#windows). Run from a
*x64 Native Tools Command Prompt for VS 2022*:

```bat
python tools\bootstrap.py
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements-build.txt
cmake -S . -B build -A x64 -DSPEKTRAFILM_BUILD_ADOBE_PLUGIN=ON
cmake --build build --config Release --parallel
ctest --test-dir build -C Release --output-on-failure
```

The plugin is the folder `build\plugin\SpektraFilm`, with the `.aex` in
`Contents\Win64` and its data in `Contents\Resources`. Keep that structure.

## Install

Close After Effects and Premiere Pro, then run:

```sh
python3 tools/install.py
```

On Windows run `python tools\install.py` from an administrator terminal. The
script copies the plugin into Adobe's shared MediaCore plug-in folder, which
both hosts read, and keeps the previous copy in `build/install-backups`:

- macOS: `~/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore`
- Windows: `C:\Program Files\Adobe\Common\Plug-ins\7.0\MediaCore`

Start the host and look for **spektrafilm** in the effects list. In After
Effects, *File > Scripts > Run Script File* with `tests/after_effects_smoke.jsx`
applies it to a new composition.

## Limitations

- The effect renders the full frame; region-of-interest and tiled rendering are
  not supported.
- On Windows frames go through CPU memory to the Vulkan renderer; Adobe's GPU
  frames are used only on macOS (Metal).
- Some spektrafilm-ofx controls are not exposed yet: DIR couplers, scanner
  settings and auto exposure.
- The output clips out-of-gamut colors; current spektrafilm compresses them in
  CAM16-UCS. See [docs/PARITY.md](docs/PARITY.md).
- Parameter order can still change before 1.0, and projects saved with an
  earlier build then lose their control values.

## Documentation

- [Architecture](docs/ARCHITECTURE.md): sources, render paths and tests.
- [Parity](docs/PARITY.md): comparison with the Python spektrafilm.
- [Performance](docs/PERFORMANCE.md): GPU optimizations, measurements, and the
  environment variables that restore the exact computation.

## Credits

- [spektrafilm](https://github.com/andreavolpato/spektrafilm) by **Andrea
  Volpato**: the film model and the film and paper profiles.
- [spektrafilm-ofx](https://github.com/chaert-s/spektrafilm-ofx) by **Aedan
  Diez** and contributors: the native renderer and table generator this port
  builds on.
- [vkdt](https://github.com/hanatos/vkdt) by **Johannes Hanika**: the Hanatos
  spectral upsampling.
- **Mallett and Yuksel (2019)**: the alternate spectral reconstruction.

Full notices in [Legal/THIRD_PARTY_NOTICES.md](Legal/THIRD_PARTY_NOTICES.md).
This port is not affiliated with or endorsed by Adobe or the authors above.

## License

[GPL-3.0](LICENSE). The spektrafilm profiles carry their own license,
[Legal/SPEKTRAFILM_PROFILES_LICENSE.txt](Legal/SPEKTRAFILM_PROFILES_LICENSE.txt).
