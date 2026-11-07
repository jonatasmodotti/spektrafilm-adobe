# GPU performance (Metal)

Measured on a MacBook Pro with an M2 Pro (16-core GPU), Release builds, through
the GPU bridge (`metal_benchmark ... bridge`), five interleaved rounds of 40
frames. The baseline is the port before these optimizations, running
spektrafilm-ofx's renderer as published.

| Effects | Resolution | Baseline, median | Current, median | Speed-up |
| --- | --- | ---: | ---: | ---: |
| base | 1920×1080 | 13.6 ms | 3.55 ms | 3.8× |
| grain | 1920×1080 | 26.4 ms | 5.02 ms | 5.3× |
| halation | 1920×1080 | 28.7–29.4 ms | 11.4–12.2 ms | 2.5× |
| base | 3840×2160 | 52.2 ms | 13.1 ms | 4.0× |
| grain | 3840×2160 | 104.3 ms | 19.8 ms | 5.3× |
| halation | 3840×2160 | 141.7 ms | 63.3 ms | 2.2× |

This comparison ran on battery, at lower clocks; on AC power the current build
takes about 2.7 ms (base), 4.0 ms (grain) and 10.9 ms (halation) at 1080p. The
ratios hold for both builds under the same conditions. Playback inside After
Effects and Premiere Pro also depends on decoding, other effects and the host.

Camera and print diffusion together add about 40 ms per 1080p frame.

## Optimizations

Each one can be switched off with an environment variable, set before starting
the host, to restore the exact computation for comparison.

1. **Spectral LUTs** (`SPEKTRAFILM_SPECTRAL_LUT=off`). The per-pixel spectral
   integrations go through 3D tables with 49 points per axis, built on the GPU
   when the parameters change. Each table is checked against the exact
   computation and discarded above a 5e-4 tolerance. Largest observed
   difference: about 5e-4 in code values.
2. **Cached constants, one GPU wait.** Per-frame constants and LUTs are rebuilt
   only when the parameters change, and the frame waits for the GPU once.
3. **Halation** (`SPEKTRAFILM_HALATION_GROUPED_TAIL=0` for the per-component
   tail). The mirrored index is used only at the Gaussian's borders, clear
   passes are gone (the first component writes instead of accumulating), the
   scatter tail processes its three components together, the Y blur computes
   four rows per thread with a sliding window in registers, and the scatter
   resolve is fused into the last Y blur. Bit-identical.
4. **Math** (`SPEKTRAFILM_PRECISE_MATH=1`). On macOS 15 and later the shader
   compiles with safe arithmetic (`MTLMathModeSafe`) and fast transcendental
   functions. Grain cell coordinates use `precise::divide` and `precise::sqrt`
   so no pixel changes cell. Largest difference: about 1e-6.
5. **Host frames read and written by the renderer.** The first kernel reads the
   Adobe frame directly (BGRA or ARGB, half or float, premultiplied) and the
   last one writes the destination. Paths that cannot fuse this (scanner,
   enlarger, production grain) convert inside the renderer. Bit-identical,
   tested for every channel order and alpha mode.
6. **Wide blurs at reduced resolution** (`SPEKTRAFILM_BLUR_DOWNSAMPLE=off`).
   Halation has a physical size: its three bounces have a sigma of 65 µm (50 µm
   for some films) times 1, √2 and √3, which is 26 to 45 px for 8mm at 1080p.
   Bounces with a sigma of 12 px or more are blurred at 1/2, 1/4 or 1/8
   resolution, with spektrafilm-ofx's diffusion thresholds and kernels, and
   added back with bilinear interpolation. Smaller bounces stay exact, so 35mm,
   Super 35 and 65mm at 1080p do not change. `off` also restores exact
   diffusion.

   | Format, 1920×1080 | Exact | Reduced | Largest difference |
   | --- | ---: | ---: | ---: |
   | 8mm | 48.5 ms | 11.7 ms | 0.49 10-bit code |
   | Super 8 | 40.2 ms | 12.5 ms | 0.27 code |
   | 16mm | 24.7 ms | 11.3 ms | — |
   | Super 16 | 21.2 ms | 13.0 ms | 0.10 code |
   | Super 35 | 13.6 ms | 13.6 ms | identical |
   | Super 35, 3840×2160 | 80.6 ms | 51.1 ms | — |
   | Super 8, 3840×2160 | 299 ms | 59.7 ms | — |

   Measured on AC power, on a dark frame with light spots up to 4.0 linear. The
   `metal_bridge` test requires less than one 10-bit code away from an 8 px
   border. At the border the reduced grid mirrors the image about its first
   pixel's centre, and a light touching the corner reaches 1.1 codes.

Also: the GPU bridge reuses the renderer's scratch buffers between frames, the
CPU path keeps its staging memory per worker thread, and After Effects may
render frames concurrently (multi-frame rendering) on macOS and Windows. On
Windows the concurrent renderers share one Vulkan device and its transient
memory budget.

## Tried and rejected

Measured on the M2 Pro and slower or no faster:

- grouping the three halation bounce passes;
- a blocked X blur, and an X blur with SIMD shuffles;
- a single-pass scatter with threadgroup-memory tiles;
- fusing the point-wise raw, develop and final kernels, which are
  compute-bound rather than bandwidth-bound;
- a blocked Y blur in the scatter core;
- a tent filter instead of a box for the reduced halation: the remaining
  difference comes from the border, not from where the lights fall.

## Reproduce

```sh
SPEKTRAFILM_RESOURCE_DIR="$PWD/build/resources" \
  build/metal_benchmark 1920 1080 40 bridge halation
```

`metal_benchmark WIDTH HEIGHT FRAMES cpu|gpu|bridge [base|grain|halation|diffusion|all]
[OUTPUT.f32] [INPUT.f32]` takes these environment variables:

- `SPEKTRAFILM_BENCH_FORMAT=0..7`: film format, 0 = 8mm, 4 = 35mm (default);
- `SPEKTRAFILM_BENCH_STATIC_GRAIN=1`: still grain instead of animated;
- `SPEKTRAFILM_BENCH_SCRUB=1`: change a control every frame, as when a slider
  is dragged;
- `SPEKTRAFILM_PASS_TIMING=split` (with `cpu` or `gpu`): time each pass
  separately. This rebuilds constants and LUTs every frame, so use it only to
  compare passes with each other.

Check the power source first: on battery the GPU runs at lower clocks.
