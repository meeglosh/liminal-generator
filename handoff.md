# Liminal Generator — Session Handoff

Last updated: 2026-08-23. Status: **v1.0 (2) live on TestFlight** (internal group); build (2) shipped loop
drums + square images + SPEED/COLOR (v1) + straight-rhythm arps. Since that upload, in the same session,
COLOR was rebuilt as a real 24dB/octave filter (the v1 COLOR effect was too subtle to notice), a 4-way
waveform selector (sine/triangle/square/saw) and a new BASSLINE section were added, and the arp's 2-octave
range got a hard clamp — **none of this newest round is in build (2) yet**, see "State / known items".

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
  affecting it identically — replaced `DrumMachine.swift`), `BassVoice`/`BasslinePattern`/`BassSequencer`
  (see "Bassline" below), `PatternGenerator` (rewritten: see "Arpeggio generator rewrite" below),
  `WowFlutterProcessor` (modulated fractional delay), `TapeHiss`, `DSPMath.swift` (`baseMelodyBPM`=82,
  `speedMultiplier(_:)`, `synthColorCutoffHz(_:)`, `oscillatorSample(waveform:phase:)`,
  `levelToGainLinear(_:)` shared by `drumLevel`/`bassLevel`), `AudioEngineController` (AVAudioEngine
  graph: source node → largeHall2 reverb → mixer; offline render via second engine in manual rendering
  mode, seeded with the same decoded `LoopBuffer` AND all live params — speed/color/waveform/bass* — as
  active playback). Final tanh soft-clip guards against clipping at extreme params.
  - **COLOR is a real filter** (fixed from an earlier, too-subtle version): dragging it end-to-end is a
    dramatic, obviously audible sweep from a muffled rumble to fully open — verified ~1200x more
    high-frequency energy at color=1 vs color=0 in a controlled test.
  - **Bassline**: `bassEnabled`/`bassColor`/`bassLevel` published on `AudioEngineController`,
    `regenerateBass()` re-rolls the rhythm/notes. Rides the SAME shared tick clock as melody/drums (no
    independent tempo — always in sync with SPEED). Notes are scale-degree-based (root/fifth/third/octave)
    resolved LIVE against the current melody's root+scale each tick — never cached absolute pitches — so
    it can never go out of key, even right after `regenerateMelody()` picks a new key, with no extra
    "refresh" call needed. Rhythm is deliberately irregular (rests, held/sustained notes, syncopation) —
    unlike the melody's straight steps. Own independent `Lowpass24dB` instance driven by `bassColor`;
    fixed triangle waveform (not user-selectable, unlike melody).
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
    Notes are hard-clamped (with an assert invariant check) to never exceed ±24 semitones from root —
    verified over 150 generated patterns / 2400 notes, max deviation observed was exactly 24, never more.
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
- Build 1.0 (2): uploaded + VALID 2026-08-23. Internal testers received it. Contains loop drums, square
  images, SPEED/COLOR (v1, subtle), arp rewrite. **Does NOT contain** the real COLOR filter, waveform
  chips, BASSLINE section, or the arp range hard-clamp (all landed after that upload, same session) —
  bump `CFBundleVersion` to 3 and re-ship when ready (see "Release / TestFlight" above).
- Drums are now playback of 10 bundled CC0 lo-fi hip-hop loops (Freesound.org, uploader "holizna"),
  not synthesized 808 hits — see `LiminalGenerator/Resources/Loops/LICENSES-LOOPS.md` for full
  per-file source/license records.
- Library images are 1:1 square (848×848); video render output (`ClipRenderer`) is also 848×848.
- Card order top to bottom: VHS image → SYNTH → BASSLINE → GLOBAL ENV → DRUMS → RENDER & SHARE.
- SPEED (GLOBAL ENV card): tape-style tempo/rate, also pitch-shifts the drum loop like a tape deck.
  COLOR (SYNTH card): real 24dB/oct lowpass on the synth voice, dark↔bright, dramatic full-range sweep.
  Below COLOR: 4 waveform chips (SINE/TRIANGLE/SQUARE/SAW) selecting the melody oscillator shape.
  SYNTH card's BPM readout shows `effectiveBPM` (computed from base/loop tempo × speed).
- BASSLINE card (new): ENABLE BASS toggle, own COLOR/FILTER slider (independent 24dB lowpass), LEVEL
  slider, GENERATE BASS button. Always in key with the melody, always in tempo sync — see Audio section.
- Arpeggio generator: straight rhythm only (no rests/swing), pattern shape restricted to up/down/up-down,
  regenerate re-rolls only key/scale/shape, hard-clamped to ±24 semitones from root. Scale pool: minor
  pentatonic, dorian, mixolydian, lydian (90%) + major pentatonic (10% sprinkle).
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
