# Third-party notices

This port is distributed under the GPL-3.0 license in `LICENSE`. It builds on
the following work.

- **spektrafilm** by **Andrea Volpato**: the original Python film simulation,
  its scientific model and the film and paper profiles.
  <https://github.com/andreavolpato/spektrafilm>
- **spektrafilm-ofx** by **Aedan Diez** and contributors: the native
  C++/Metal/Vulkan renderer and the table generator this port compiles,
  GPL-3.0. <https://github.com/chaert-s/spektrafilm-ofx>
- The Hanatos spectral upsampling follows **Johannes Hanika**'s work in
  **vkdt**. <https://github.com/hanatos/vkdt>
- The alternate spectral reconstruction follows **Mallett and Yuksel (2019)**,
  *Spectral Primary Decomposition for Rendering with sRGB Reflectance*.
  <https://diglib.eg.org/items/bbffa865-e99c-4c1f-bd33-70102dc8af78>

`upstream.lock.json` pins the commits used. `tools/bootstrap.py` fetches them
and applies `patches/adobe-port.patch`, which holds every change made here to
the spektrafilm-ofx renderer, shaders and table generator:

- performance work: spectral LUTs, blocked blurs, fused passes, reduced
  resolution blurs for wide halation and diffusion, and reading and writing the
  Adobe host frames in the first and last GPU passes. `docs/PERFORMANCE.md`
  lists the environment variables that restore the exact computation;
- model updates that follow current spektrafilm: CAT16 input adaptation, no xy
  clamp under input gamut compression, and paper density curves evaluated from
  the profile's `density_curves_model`. `docs/PARITY.md` has the comparison.

By default the profiles and the neutral enlarger filters come unchanged from
the spektrafilm checkout at the `reference` commit in `upstream.lock.json`. The
tables compiled into the plugin encode those profiles. The license published by
the spektrafilm project for the profiles and their derivatives is included
unchanged in `SPEKTRAFILM_PROFILES_LICENSE.txt`.

The Adobe After Effects and Premiere Pro SDKs are not part of this repository
or of the plugin; each developer downloads them from Adobe. No resources from
the official spektrafilm-ofx binaries and no non-public SMPTE data are used.

Adobe, After Effects and Premiere Pro are trademarks of Adobe. The spektrafilm
name identifies Andrea Volpato's project. Neither Adobe nor the authors above
endorse this port.
