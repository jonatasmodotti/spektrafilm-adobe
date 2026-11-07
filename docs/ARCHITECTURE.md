# Architecture

## Sources

`upstream.lock.json` pins two upstream commits:

- **ofx**: spektrafilm-ofx, the native renderer. `tools/bootstrap.py` clones it
  into `third_party/spektrafilm-ofx` and applies `patches/adobe-port.patch`.
- **reference**: spektrafilm, the Python original. Only its profiles, neutral
  print filters and license are checked out, into `third_party/spektrafilm`.

Both checkouts stay out of this repository's history. CMake checks their
commits and the patch at configure time.

The build compiles the spektrafilm-ofx renderer (`SpektraMetalRenderer.mm` on
macOS, `SpektraVulkanRenderer.cpp` on Windows) and its generated profile
tables. It does not compile the OpenFX wrapper or include OpenFX headers.
Python runs only at build time, to generate the tables; the plugin is native
code.

## Render paths

```text
After Effects SmartFX                     Premiere Pro
  GPU frames (Metal, macOS)                 GPU filter, xGPUFilterEntry (macOS)
  CPU frames, 8/16/32 bpc                   CPU frames, BGRA float32
        |                                         |
        +--------------- RenderParams ------------+
                              |
        macOS: MetalBridge -> Metal renderer, on the host's queue
        Windows: CPU frames -> Vulkan renderer (upload and readback)
```

- `src/AdobeParameters.h` defines the controls once: their order (which is also
  the AE disk ID and, minus one, the Premiere GPU parameter index), ranges,
  defaults, and the mapping to the renderer's `RenderParams`.
- `src/adobe/AdobeEffect.cpp` is the effect entry point: parameter setup,
  SmartFX pre-render and render, the CPU frame path, GPU device setup and the
  banner's arbitrary data.
- `src/adobe/PremiereGpu.mm` is Premiere's GPU filter on macOS. It reads the
  same parameters through the video segment suite.
- `src/metal/MetalBridge.mm` validates host frames and runs the Metal renderer
  on the host's command queue. The renderer reads the host layout (channel
  order, alpha, half or float, row padding) in its first pass and writes it in
  its last, so there is no separate conversion. The bridge waits for the GPU
  once per frame, which lets the renderer keep its scratch buffers.
- On Windows the same effect sends CPU frames to the Vulkan renderer. Direct
  use of Adobe's DirectX/CUDA/OpenCL GPU frames is not implemented.
- `src/adobe/AdobeBanner.cpp` draws the banner at the top of the Effect
  Controls panel with Adobe's Drawbot suites. After Effects draws it on a null
  parameter; Premiere draws custom controls only on arbitrary data parameters
  with a non-zero width. The image is decoded with ImageIO on macOS and WIC on
  Windows.

## Tests

`ctest` runs:

1. `frame_layout`: buffer bounds, offsets, pitch and invalid layouts.
2. `metal_bridge` (macOS): every channel order and alpha mode against the
   renderer, padding and offsets, float16, grain, halation, diffusion, the
   reduced resolution halation, and concurrent renders.
3. `adobe_effect_abi` (macOS): loads the built plugin with `dlopen` and drives
   it through the real SDK structures with simulated host callbacks: parameter
   setup in both hosts, the banner's arbitrary data, pre-render, AE CPU render
   at 8/16/32 bpc, AE GPU render and Premiere GPU render, compared with each
   other.

The ABI test covers the entry points under a simulated host. It does not cover
the hosts' plug-in scanners or every callback variant, so each release is also
checked inside After Effects and Premiere Pro. `tests/after_effects_smoke.jsx`
applies the effect to a new composition in After Effects.

`docs/PARITY.md` compares the renderer with the Python original, and
`docs/PERFORMANCE.md` describes the GPU optimizations.

## Not yet covered

- Region-of-interest and tiled rendering: the effect always renders the full
  frame.
- Automated GPU tests on Windows: there `ctest` runs only `frame_layout`. The
  Vulkan renderer was checked by hand with upstream's
  `SpektraVulkanCopyHarness`, and the effect in After Effects and Premiere Pro.
- GPU frames on Windows, and Metal devices other than the system default.
- The remaining spektrafilm-ofx controls (DIR couplers, scanner, auto
  exposure) and reading the host's color management.
