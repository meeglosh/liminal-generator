# VHS slideshow treatment

Branch: `codex/ntscrt-vhs-slideshow`.

Inspired by [NTSCRT](https://github.com/finnmckenty/NTSCRT)'s separation of analog signal damage and CRT display effects. This implementation is original and uses the existing Metal/Core Image paths, without importing NTSCRT, ntsc-rs, or RetroArch code/dependencies.

- Live slideshow: sharp luminance with horizontally softened/desaturated color, restrained highlight glow, gentle tape weave, bottom-edge head switching, scanlines, low grain and occasional tracking bands.
- All carousel pages share a relative animation clock. Subtracting the origin before conversion to Float fixes lost animation precision from the old absolute timestamp.
- Animation continues while music is paused at lower distortion strength; inactive neighbors and background scenes pause their timelines. Reduce Motion freezes the shader time while retaining the static treatment.
- Export: comparable color softness, bloom and tape movement, plus resolved scanlines. The previous integer-row `sin(y * pi)` pattern evaluated to uniform brightness.
- Preview and export are visually related approximations, not pixel-identical: Metal uses a few horizontal taps; Core Image uses motion blur/bloom. Export tracking retains its existing randomized schedule. OSD remains legible above the effect.

Validation: simulator Debug build passed; both existing UI tests passed (full generator/render/share flow and vertical slider drag). After the final export color correction, rebuilt and rendered an eight-second H.264/AAC clip, inspected its frame, and confirmed animation by comparing successive paused-slideshow screenshots. Physical-device frame rate/battery and final artistic tuning remain device checks.

## TestFlight release

Version 1.0 (8), uploaded 2026-09-14 from this branch. Release archive/export succeeded; Apple processed the build successfully and it is available to the Internal TestFlight group.
