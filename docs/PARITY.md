# Parity with the Python spektrafilm

The plugin's renderer is compared with Andrea Volpato's Python spektrafilm
using the spektrafilm-ofx parity harness (`tools/run_parity_harness.py`). The
harness renders test patterns on both sides and compares every stage:
`film_log_raw`, `film_density_cmy`, `print_log_raw`, `print_density_cmy` and
the final linear output, with spektrafilm-ofx's tolerances.

The Metal executable (`spektra_parity_harness`) is built against this port's
renderer, with the patch and the optimizations, so the result holds for the
engine the plugin runs. The Adobe layer (parameters, frame layouts, alpha) is
covered by the `metal_bridge` and `adobe_effect_abi` tests, which require the
same output as the renderer.

## Result

Quick mode, 33 cases, on 2026-11-07. Each build model against the Python
version it follows, with the plugin's tables and RGB-to-spectrum conversion
(`hanatos2026`).

| Build | Python | Non-spatial stages | Final output | Failures |
| --- | --- | --- | --- | --- |
| `SPEKTRAFILM_MODEL=reference` (default) | `3bb2c2d` (2026-06-07), input compression, clipped output | up to 3e-6 | up to 0.00039 | 0 |
| `SPEKTRAFILM_MODEL=ofx` | `c4f2d23` (2026-05-13) | up to 3e-6 | up to 0.00037 | 0 |
| `ofx`, archived profiles, `hanatos2025` | `26eabba` (2026-04-26) | up to 3e-6 | up to 0.00039 | 0 |

The two models differ in the plugin's output by about 0.01 linear on average and
up to 0.1 in the most saturated colors (Portra 400 on Endura).

1. **The default model follows spektrafilm `3bb2c2d`.** The build uses that
   version's refitted profiles and neutral filters, CAT16 input adaptation,
   input gamut compression (present but off in spektrafilm-ofx), and paper
   curves evaluated from `density_curves_model`, as the Python prints since
   `a7f0f9a`.
2. **The output still clips.** Current spektrafilm compresses the output in
   CAM16-UCS, with lightness compression, instead of clipping. The comparison
   above clips on both sides. spektrafilm-ofx's oklch compression is no
   substitute: on grays it differs from the Python oklch by up to 0.11.
3. **The `ofx` model is spektrafilm `c4f2d23`.** The renderer's `hanatos2026`
   method is the Python `hanatos2025` with the per-film adaptation window.
4. **Grain defaults differ.** The harness fixes the grain parameters on both
   sides. The plugin's defaults come from spektrafilm-ofx (area 0.1 µm², scale
   1.2/1.0/2.5); Python `3bb2c2d` uses 0.2 µm² and 1.6/1.6/3.2.
5. **The optimizations do not change parity.** The metrics are identical with
   and without `SPEKTRAFILM_SPECTRAL_LUT=off`, `SPEKTRAFILM_PRECISE_MATH=1` and
   `SPEKTRAFILM_HALATION_GROUPED_TAIL=0`.

## Reproduce

Requires Python 3.13 or later. The commands use a temporary directory.

```sh
W=/tmp/spektrafilm-parity
git clone https://github.com/andreavolpato/spektrafilm "$W/spektrafilm"
git -C "$W/spektrafilm" checkout 3bb2c2d
python3.14 -m venv "$W/venv"
"$W/venv/bin/pip" install "numpy~=2.4" "scipy~=1.17" "colour-science~=0.4.6" \
  "scikit-image~=0.26" "opt-einsum~=3.4.0" "numba~=0.64" "matplotlib~=3.10" \
  "OpenImageIO~=3.1.11" "exiv2~=0.18.1" "rawpy~=0.26.1" "lensfunpy~=1.18.0" "pyfftw~=0.15.0"
cmake --build build --target spektra_parity_harness
PYTHONPATH="$W/spektrafilm/src" MPLCONFIGDIR="$W/mpl" "$W/venv/bin/python" \
  third_party/spektrafilm-ofx/tools/run_parity_harness.py \
  --output "$W/report" --harness build/spektra_parity_harness \
  --build-dir build/resources --mode quick \
  --python-package-data --input-gamut-compress
```

The report is `$W/report/summary.csv`, with one image per case.

For the `ofx` model, configure with `-DSPEKTRAFILM_MODEL=ofx`, check out Python
`c4f2d23`, and replace the last two options with
`--python-profile-dir third_party/spektrafilm-ofx/Resources/data/profiles`.

Harness options added by this port's patch:

- `--rgb-to-raw-method` selects the RGB-to-spectrum conversion. The default,
  `hanatos2026`, needs Python `c4f2d23` or later; older versions use
  `hanatos2025` with the archived bandpass.
- `--python-package-data` makes the Python read its own package data instead of
  the prepared data directory. Use it for the `reference` model, whose data is
  the package's at the `reference` commit.
- `--input-gamut-compress` enables input gamut compression on both sides, and
  `--output-gamut-compress oklch` enables oklch output compression (the default
  is `clip`). Both need Python `eac6b85` or later.

Without `--python-profile-dir` the harness uses `profiles/archive`. To compare
in that setup, build the harness with curves generated from `profiles/archive`
(pass `SPEKTRAFILM_PROFILE_DIR` and `SPEKTRAFILM_ARCHIVE_PROFILE_DIR` to
`generate_profile_curves.py`, as spektrafilm-ofx's CMake does) and run it
against `26eabba` with `--rgb-to-raw-method hanatos2025`.
