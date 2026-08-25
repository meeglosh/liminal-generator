# Liminal Generator — Session Handoff

Last updated: 2026-08-25. Status: **v1.0 (7) live on TestFlight** (internal group) — repo `main` and
TestFlight are in sync; every feature below is shipped. Build history (all 2026-08-23/24): (1) initial
app, synthesized 808 drums; (2) CC0 loop drums + square images + SPEED/COLOR v1 + straight arps; (3) real
24dB COLOR filter + waveform chips + BASSLINE + arp clamp; (4) **ambient pad engine** (SPEC.md Addendum 3
— pad-chord composer in the style of "Snowfall" by Øneheart × reidenshi: slow 4-chord minor progressions,
sparse pentatonic melody, sub-bass on chord roots, breathing swell; replaced the arpeggio sequencer);
(5) NOSTALGIA Juno-106 BBD chorus; (6) deliberate slider gestures + smooth carousel + share thumbnail +
watermark + VHS-tape splash icon + intensified VHS look; (7) clean splash + grain −75% + share-preview
thumbnail encoding fix. **Open item:** the build-(7) share-preview fix addressed a real logged
LinkPresentation failure but the original black-preview bug only ever reproduced on a physical device —
awaiting the user's on-device confirmation; if still black, gather device console logs around
LinkPresentation next.

## What this is
Free iOS app that generates liminal-style ambient music (random arpeggios + optional lo-fi drums,
playback of bundled CC0 loops) over swipeable VHS-filtered images of empty spaces, and renders
shareable 2-minute MP4 clips with fade in/out. SwiftUI, iOS 17+, iPhone-only, portrait-locked, zero
third-party dependencies.

`SPEC.md` in the repo root is the architecture source of truth (including the pinned cross-module API
contract used to build it). Design system: `img/stitch_liminal_space_generator/liminal_analog/DESIGN.md`
("Liminal Analog" — CRT green / glitch magenta on deep charcoal, Space Mono, sharp corners, VCR aesthetic).

## Repo layout
- `project.yml` — XcodeGen manifest. Regenerate the project with `/opt/homebrew/bin/xcodegen generate`
  after any change here or when adding files is flaky. The `.xcodeproj` is committed but generated.
- `LiminalGenerator/App` — entry point, Theme (colors/fonts), Info.plist (portrait lock, fonts,
  `ITSAppUsesNonExemptEncryption=false`).
- `LiminalGenerator/Audio` — all DSP, plain Swift, shared verbatim between live playback and offline
  render: `LiminalDSPCore` (render loop, zero alloc/locks on audio thread), `SynthVoice` (10-voice
  detuned pad-pluck; oscillator shape follows `AudioEngineController.waveform` — sine/triangle/square/saw,
  default triangle; `Lowpass24dB` (4 cascaded one-pole stages, 24dB/oct) with base cutoff set by `color`
  via `synthColorCutoffHz` — logarithmic 70Hz (closed) to 19kHz (open) — envelope-driven brightness still
  layers on top per-note; synth-only, never touches drums or bass), `ArpeggioSequencer` (sample-accurate
  step clock, pattern hot-swap at tick boundaries), `LoopPlayer` (drums — plays back one of 10 bundled
  CC0 lo-fi loops instead of synthesizing 808 hits; `LoopLoader` decodes every loop WAV into a Float32
  buffer once per process, off the render thread, and `LoopPlayer` advances a fractional-sample cursor
  with seamless wraparound, summed into the same bus the old `DrumMachine` used so SPACE/AGE keep
  affecting it identically — replaced `DrumMachine.swift`), `PadVoice`/`SceneSequencer` + `BassVoice`/
  `BasslinePattern`/`BassSequencer` (the ambient composer — see "Ambient pad engine" below),
  `PatternGenerator` (generates the pad "scene"), `WowFlutterProcessor` (modulated fractional delay),
  `TapeHiss`, `DSPMath.swift` (`baseMelodyBPM`, `speedMultiplier(_:)`, `synthColorCutoffHz(_:)`,
  `oscillatorSample(waveform:phase:)`, `levelToGainLinear(_:)` shared by `drumLevel`/`bassLevel`,
  `Lowpass24dB`), `AudioEngineController` (AVAudioEngine graph: source node → largeHall2 reverb → mixer;
  offline render via second engine in manual rendering mode, seeded with the same decoded `LoopBuffer`
  AND all live params — speed/color/waveform/bass*/scene/breathing phase — as active playback). Final
  tanh soft-clip guards against clipping at extreme params.
  - **Ambient pad engine (SPEC.md Addendum 3 — supersedes the old arpeggio sequencer)**: emulates popular
    liminal/dreamcore tracks ("Snowfall" — Øneheart × reidenshi). `regenerateMelody()` rolls a "scene"
    (kept in the pinned `ArpeggioPattern` type name): a random MINOR key, a 4-chord/4-bar looping
    progression from a curated nostalgic pool (i–VI–III–VII etc.), warm 4–5-voice open voicings with
    add9/sus2 substitutions, and a sparse melody motif. Pads: fixed sound (3 detuned saw+triangle osc per
    voice), slow 0.5–1.5s attacks, 2–4s releases, click-free crossfades at bar-boundary chord changes.
    Melody: 2–5 soft long minor-pentatonic notes per 2-bar phrase, motif-repeated with variation,
    sometimes resting a whole phrase; uses the user-selected `waveform` (default now `.sine`). Sub-bass:
    fixed sine an octave below the pad roots following the current bar's chord root; `regenerateBass()`
    re-rolls a subtle movement variation only. Breathing: always-on tempo-synced ~3dB swell per bar on
    pads+bass (melody floats un-ducked). `displaySeq` returns chord names (e.g. "Em-C-G-D"); UI label is
    "PROG:". Verified by harness: 100 scenes fully diatonic, chord changes bar-exact with no transition
    clicks, sub-bass fundamental tracks chord roots ≤0.1Hz error, onset rate 0.93/sec drums-off (vs old
    arp's 4+/sec).
  - **COLOR is a real filter**: 24dB/octave lowpass (log-mapped ~70Hz–19kHz) governing the whole synth
    layer (pads + melody); dramatic full-range sweep (~1200x high-frequency energy delta end-to-end).
    Bass has its own independent instance driven by `bassColor`.
  - **Tempo-sync rule (with SPEED)**: `effectiveBPM = round(baseTempoSource * speedMultiplier(speed))`,
    `baseTempoSource` = active loop's bpm while drums enabled, else `baseMelodyBPM` (now 72 for the
    ambient style). `speedMultiplier(speed) = 0.70 + speed*0.60` (0.70x–1.30x, 1.0x at default 0.5,
    smoothed). Chord changes, loop swap/enable at 16-tick bar boundaries. The drum `LoopPlayer`'s cursor
    is ALSO scaled by the speed multiplier (tape-varispeed: loop pitch shifts with tempo); synth pitches
    are NOT affected by speed, only timing. Breathing swell is tick-synced so it scales with SPEED too.
- `LiminalGenerator/UI` — SplashView, MainView, VHSImageCard (swipe paging w/ wraparound),
  `VHSShader.metal` (scanlines/grain/chroma aberration/vignette/tracking jitter via SwiftUI
  layerEffect), VHSTimestamp (random late-80s–90s OSD date), deck-style Components, AboutSheet.
- `LiminalGenerator/Render` — RenderScreen ("ENCODING ANALOG SIGNAL" terminal UI), ClipRenderer
  (AVAssetWriter H.264 848×1264@30fps + AAC), VHSFrameCompositor (Core Image pipeline matching the
  live shader, OSD with ticking clock baked in, fades synced to audio), ShareSheet,
  AutoRenderDebugHarness (DEBUG-only, see env vars below).
- `LiminalGeneratorUITests` — one end-to-end flow test (play, regenerate, sliders, drums, render,
  share sheet) with screenshot capture.
- `LiminalGenerator/Resources` — asset catalog with **23** library images (`liminal_01`–`liminal_23`;
  the spec said 24 but sources contained 23), each **848×848 square** (center-cropped from the original
  848×1264 portrait sources, no upscaling — vertical crop offset 208px), AppIcon, bundled Space Mono
  (OFL license included). `ImageLibrary.swift` is the manifest — append new imagesets there to grow the
  library (keep new images square too, or update `VHSImageCard`'s aspect ratio if that ever changes).
  `Resources/Loops/` has the 10 bundled CC0 lo-fi drum loop WAVs + `LoopManifest.swift`
  (`LoopLibrary.all`) + `LICENSES-LOOPS.md` (full per-file source/license record).

## Build / run / test
```sh
xcodegen generate    # if project.yml changed
xcodebuild -project LiminalGenerator.xcodeproj -scheme "Liminal Generator" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' build   # or: test
```
Debug env hooks (compiled out of Release):
- `LG_AUTORENDER=1` — auto-renders a clip at launch, prints path+size to console.
- `LG_RENDER_SECONDS=N` — shortens the clip (both harness and RenderScreen honor it).
- `LG_AUTORENDER_DRUMS=1` — (harness only) enables drums before rendering, for audio verification.
- Pass env to simulator via `SIMCTL_CHILD_<VAR>` on the `simctl launch` invocation (trailing
  `KEY=value` args are argv, not env — known gotcha).

## Release / TestFlight (proven 2026-08-23)
Identity: team `XM2SC5YZ8C` (GAPCO Limited Liability Company), bundle `com.gapco.LiminalGenerator`,
App Store Connect app id `6804471660`, app name "Liminal Generator".
1. Bump `CFBundleVersion` in `LiminalGenerator/App/Info.plist` (marketing version as appropriate).
2. `xcodegen generate`, then `xcodebuild archive` (Release, generic/platform=iOS).
3. Export with **manual signing**: cert "Apple Distribution: GAPCO Limited Liability Company"
   (private key lives in the Mac's login keychain — created via Xcode → Settings → Accounts →
   Manage Certificates; cloud signing is NOT available with the current API key), provisioning
   profile "com.gapco.LiminalGenerator AppStore" (recreate with `fastlane sigh` if expired).
4. Upload with `xcrun altool --upload-app -t ios` using the GAPCO App Store Connect API key.
   Credentials are NOT in this repo: the `.p8` keys live in `~/.appstoreconnect/private_keys/` on the
   dev Mac, and the key/issuer IDs are recorded in the local Claude session memory for this project.
   fastlane gotcha: its api-key JSON wants the key content inline under `"key"`, not `key_filepath`.
5. Processing takes ~5–15 min; the internal TestFlight group ("Internal", has access to all builds)
   picks builds up automatically. Poll `/v1/builds?filter[app]=6804471660` — processingState can flap,
   require ~3 consecutive `VALID` reads.

## State / known items
- Build 1.0 (7): uploaded + VALID 2026-08-24, current on TestFlight, matches repo `main` exactly. For the
  next release, bump `CFBundleVersion` to 8 and follow "Release / TestFlight" above (the whole pipeline —
  archive → export → altool upload → poll — is proven and takes ~5 min plus Apple's processing).
- OPEN: share-sheet preview thumbnail fix (build 7) needs on-device confirmation — the bug (black
  preview) never reproduced in the simulator. If the user reports it still black, capture device console
  logs filtered on "LinkPresentation" while opening the share sheet.
- Drums are now playback of 10 bundled CC0 lo-fi hip-hop loops (Freesound.org, uploader "holizna"),
  not synthesized 808 hits — see `LiminalGenerator/Resources/Loops/LICENSES-LOOPS.md` for full
  per-file source/license records.
- Library images are 1:1 square (848×848); video render output (`ClipRenderer`) is also 848×848.
- Card order top to bottom: VHS image → SYNTH → BASSLINE → GLOBAL ENV → DRUMS → RENDER & SHARE.
- GLOBAL ENV card slider order: SPACE, AGE, NOSTALGIA, SPEED.
- NOSTALGIA (GLOBAL ENV card, sub-label BBD_CHORUS): Juno-106-style BBD stereo chorus on the SYNTH layer
  only (pads + melody; `JunoChorus.swift` — 2.5ms base delay, 0.5Hz antiphase triangle LFOs ±0.875ms,
  slight mode-II blend above 0.5) — zero effect on bass/drums (verified: max sample delta 0.0). Published
  `nostalgia: Float` 0–1, default 0.4; slider crossfades dry → Juno's native 50/50 wet blend.
- SPEED (GLOBAL ENV card): tape-style tempo/rate, also pitch-shifts the drum loop like a tape deck.
  COLOR (SYNTH card): real 24dB/oct lowpass on the whole synth layer (pads+melody), dark↔bright.
  Below COLOR: 4 waveform chips (SINE/TRIANGLE/SQUARE/SAW) selecting the MELODY oscillator shape only
  (pads are fixed sound design; default chip is SINE).
  SYNTH card readout: `PROG: <chord names>` (e.g. "Em-C-G-D") + `BPM: <effectiveBPM>`.
- BASSLINE card: ENABLE BASS toggle, own COLOR/FILTER slider (independent 24dB lowpass), LEVEL slider,
  GENERATE BASS button. Now a sub-bass following the pad progression's chord roots (see Audio section).
- **Music engine is the ambient pad composer** (SPEC.md Addendum 3) — the old straight-rhythm arpeggio
  engine is retired. GENERATE MELODY rolls key + chord progression + melody motif as one "scene".
- Interaction/branding polish (Addendum 5, in build 1.0 (6)): sliders use a custom
  `DirectionalPanGestureRecognizer` (UIKit-level) that fails itself on vertical touches so page scrolling
  never edits values — a plain SwiftUI DragGesture CANNOT do this (once recognized it blocks the
  ScrollView; don't regress to it); carousel swipes track the finger and spring-settle (smooth, wrapping);
  splash shows the VHS-tape app icon (SplashIcon imageset) not an SF Symbol; rendered clips carry a
  "LIMINAL GENERATOR" watermark bottom-right (baked pre-fade so black lead-in/out stays pure); share
  sheet shows a mid-clip thumbnail via UIActivityItemSource + LPLinkMetadata (pre-generated and cached
  after render); VHS look intensified live + rendered to matching pinned values (scanlines 0.18,
  grain 0.019 — was 0.075, reduced 75% on user feedback, keep live/render matched; tracking glitch every
  4–9s, +50% edge chroma, chroma bleed). Splash is deliberately CLEAN of VHS texture (no ScanlineOverlay,
  static at 0.03) — only the image card carries the heavy look. Share-sheet thumbnail: LPLinkMetadata
  must be fed PRE-ENCODED JPEG data via NSItemProvider(item:typeIdentifier:) on BOTH imageProvider and
  iconProvider — a lazy NSItemProvider(object: UIImage) gets dropped by LinkPresentation's low-fidelity
  encoder ("can't encode without computation" in console) and the preview falls back to black.
  120s render measured at
  ~56s — inside the ~60s budget with slim margin; the glitch band's full-frame materialize is the lever
  if more headroom is needed.
- App starts idle at "PLAY ▶" (deliberate; an early build auto-played on launch — don't regress).
- App record, cert, and bundle id already exist in ASC/portal — never recreate them.
- Untested on physical hardware: real speaker audio character, shader perf, haptics.
- Possible next steps: background-audio (screen-lock playback), App Store listing assets/screenshots,
  more library images, physical-device pass.

## How this was built (context for future sessions)
Orchestrated 2026-08-23 by Claude (Fable) as senior engineer spawning Sonnet subagents per phase
(scaffold → audio/UI in parallel → render pipeline → verification), all coding against the pinned
contract in SPEC.md; orchestrator verified with real builds, simulator screenshots, an XCUITest flow,
and ffprobe checks on rendered MP4s. The user prefers this working model: orchestrator does not write
app code itself.
