# Liminal Generator — Session Handoff

Last updated: 2026-08-23. Status: **v1.0 (1) live on TestFlight** (internal group); several audio/visual
changes landed after that build in the same session (not yet re-shipped) — see "State / known items":
drums switched from synthesized 808 to bundled CC0 lo-fi loop playback; library images changed from
portrait 2:3 to 1:1 square; added SPEED (tape-style tempo/rate) and COLOR (synth tone) global controls;
arpeggio generator rewritten to straight-rhythm up/down/up-down patterns over a fixed weighted scale pool.

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
  detuned pad-pluck; `colorFactor` biases each note's filter open/dark cutoff, dark↔bright, layered on
  the existing envelope-driven brightness — synth-only, never touches drums), `ArpeggioSequencer`
  (sample-accurate step clock, pattern hot-swap at tick boundaries), `LoopPlayer` (drums — plays back
  one of 10 bundled CC0 lo-fi loops instead of synthesizing 808 hits; `LoopLoader` decodes every loop
  WAV into a Float32 buffer once per process, off the render thread, and `LoopPlayer` advances a
  fractional-sample cursor with seamless wraparound, summed into the same bus the old `DrumMachine`
  used so SPACE/AGE keep affecting it identically — replaced `DrumMachine.swift`), `PatternGenerator`
  (rewritten: see "Arpeggio generator rewrite" below), `WowFlutterProcessor` (modulated fractional
  delay), `TapeHiss`, `DSPMath.swift` (`baseMelodyBPM`=82, `speedMultiplier(_:)`, `synthColorFactor(_:)`),
  `AudioEngineController` (AVAudioEngine graph: source node → largeHall2 reverb → mixer; offline render
  via second engine in manual rendering mode, seeded with the same decoded `LoopBuffer` AND the live
  `speed`/`color` values as active playback). Final tanh soft-clip guards against clipping at extreme
  params.
  - **Tempo-sync rule (with SPEED)**: `effectiveBPM = round(baseTempoSource * speedMultiplier(speed))`,
    `baseTempoSource` = active loop's bpm while drums enabled, else `baseMelodyBPM` (82).
    `speedMultiplier(speed) = 0.70 + speed*0.60` (0.70x–1.30x, 1.0x at default speed=0.5, smoothed
    continuously — no zipper/clicks). The tick clock (arp + loop timing) runs at this rate; loop
    swap/enable still applies only at the next 16-tick bar boundary (cursor reset to 0 there). The drum
    `LoopPlayer`'s sample cursor is ALSO scaled by the speed multiplier — a deliberate tape-varispeed
    effect, so the loop's pitch shifts with tempo (tape-deck character); the synth's note pitches are
    NOT affected by speed, only their timing.
  - **Arpeggio generator rewrite**: `regenerateMelody()` re-rolls ONLY root key, scale, and pattern
    shape — nothing else (step count fixed at 16, octave span fixed at 2 octaves; `ArpeggioPattern.bpm`
    field removed entirely, tempo now comes solely from `effectiveBPM`). Scale pool: 90% uniform from
    {minor pentatonic, dorian, mixolydian, lydian}, 10% major pentatonic. Pattern shape is exactly one
    of `up`/`down`/`up-down` (classic zigzag, no repeated peak note) — always straight, even step
    timing (no rests, no held notes, no swing; small per-note velocity humanization jitter remains).
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
- Build 1.0 (1): uploaded + VALID 2026-08-23, expires 2026-11-21. Internal testers received it.
  **None of the changes below (loop drums, square images, SPEED/COLOR, arp rewrite) are in that build
  yet** — bump `CFBundleVersion` and re-ship when ready (see "Release / TestFlight" above).
- Drums are now playback of 10 bundled CC0 lo-fi hip-hop loops (Freesound.org, uploader "holizna"),
  not synthesized 808 hits — see `LiminalGenerator/Resources/Loops/LICENSES-LOOPS.md` for full
  per-file source/license records.
- Library images are 1:1 square (848×848); video render output (`ClipRenderer`) is also 848×848.
- Two new global engine controls: SPEED (GLOBAL ENV card — tape-style tempo/rate, also pitch-shifts the
  drum loop like a tape deck) and COLOR (SYNTH card — synth-only tone, dark↔bright). SYNTH card's BPM
  readout now shows `effectiveBPM` (computed from base/loop tempo × speed), not a per-pattern random bpm.
- Arpeggio generator rewritten: straight rhythm only (no rests/swing), pattern shape restricted to
  up/down/up-down, regenerate re-rolls only key/scale/shape. Scale pool: minor pentatonic, dorian,
  mixolydian, lydian (90%) + major pentatonic (10% sprinkle).
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
