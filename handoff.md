## Unreleased on branch `codex/ntscrt-vhs-slideshow` (2026-09-17)
- PLAY button attract pulse: until the user first taps PLAY in a session, the control pulses (~1.06x scale)
  and glows (swelling CRT-green shadow) on a ~1.4s autoreversing loop (`VHSImageCard.swift`); the "has tapped"
  flag lives on `VHSImageCard` itself so it survives image paging. Reduce Motion drops the scale, keeps the glow.
- CRT off/switch-on treatment: the image card is a fully black dead CRT (OSD hidden, swipe paging disabled)
  whenever nothing is playing; PLAY runs a ~0.5s switch-on (line snap → vertical bloom → decaying tracking
  wobble with matched horizontal overscan → OSD fade-in), reversed over ~0.35s on pause. Reduce Motion
  substitutes a 0.3s crossfade. While off, all three paged image views stop ticking (shader/TimelineView
  genuinely idle, not just covered).
- Fixed a live-preview rendering bug: `layerEffect`'s `maxSampleOffset` made each paged image's shader output
  overhang its own bounds; since the index+1 page draws last, its left overhang smeared a ~9%-wide band of
  the next image onto the current page's right edge. Fixed by clipping each page's filtered output to its own
  frame (`VHSImageCard.swift`) plus an out-of-bounds transparency guard in `VHSShader.metal`. The Core Image
  export path was never affected — it already crops after every displacing filter.
- New BREAKS toggle (`AudioEngineController.breaksEnabled`, default true; "BREAKS" row in the DRUMS card,
  below LEVEL, above GENERATE BEAT, `accessibilityIdentifier("breaksToggle")`) now governs drum breaks in
  BOTH live playback and export, not export only. Live breaks are driven by a new `LiveDrumBreakSchedule` —
  a tempo-independent 48-bar cycle with two 2-bar breaks at bars [14,16) and [30,32), keyed off the shared
  musical tick clock (~two breaks per 2.4 min at 80 BPM/1.0x SPEED). Export's `DrumBreakArrangement` is now
  only constructed when `drumsEnabled && breaksEnabled`. Both paths gate the drum AND bass buses together;
  melody/pads/breathing/tempo keep running. Break starts stay bar-quantized; toggling BREAKS or DRUMS off
  mid-break now releases the gate immediately (~6ms) instead of waiting for the next bar boundary. See
  `docs/Drum-breaks.md` for full detail.
- New UI test `testCRTPowerToggleAnimationCapture` (`LiminalGeneratorUITests/LiminalGeneratorFlowTests.swift`)
  drives a real play/pause cycle and captures screenshot bursts through both CRT transitions as test attachments.
- Verified on simulator: `python3 tests/run-drum-break-tests.py` passes, including new mid-break toggle-
  release regression coverage; `xcodebuild test` passes all 3 UI tests. Not yet shipped to TestFlight with
  these changes — `CFBundleVersion` has not been bumped for them.
- **Open item**: the committed App Store screenshots in `docs/app-store/screenshots/*.png` still have the old
  right-edge smear artifact baked in (from the `maxSampleOffset` bug above) and need regenerating before any
  store submission.

## Unreleased after build 10 (2026-09-15)
- Refined main CTA feedback with a shared native CTAPressFeedback modifier: 100ms press, 1% compression, 2pt depression, restrained glow, and transitions.dev-style 250ms ease-out return. Generate Melody/Bass/Beat, Render & Share and other deck actions share it. Reduce Motion disables transforms and interpolation. No action delays or new dependencies.
- Simulator build passed under Xcode 27 after downloading its missing Metal Toolchain component. Not uploaded to TestFlight.

## Latest TestFlight upload
Version **1.0 (10)** is available to the **Internal** TestFlight group on 2026-09-14.
Apple reports VALID and IN_BETA_TESTING; Internal group membership verified.
Includes the restored splash, control feedback, share-completion tip button, and recipient-preview improvements.
Signed archive and IPA: `/tmp/liminal-testflight-10/`. Delivery UUID: `23bf6f50-d1b7-4df4-a5ee-480b28d57960`.
Next build number: 11. Device checks: interaction feel and received Messages video presentation.

## Added in build 10
- Deck and render buttons now use subtle press illumination, quick depression and a softer 200ms spring release. Reduce Motion keeps immediate visual feedback without displacement. Actions/haptics remain unchanged.
- Sliders brighten/glow during recognized horizontal drags, with immediate position updates and release/cancel cleanup. Bass/drum toggles use a subtle 250ms spring and green illumination, retaining immediate audio updates/haptics. Reduce Motion disables interpolation and panel movement. Adapted transition-skill ideas natively; no CSS/library added.
- Restored the original two-second splash and VHS tape icon at the user’s request, with a 0.4-second fade into the idle player. Supersedes removal notes below; tip store and SwiftUI debug harness remain wired in.
- Recipient preview improvements: visible watermarked opening (audio fade-in retained), fast-start MP4, shorter attachment filename, explicit video type/activity thumbnail, no supplied subject or local-file link metadata. Exported first frame visually checked; H.264/AAC durations match and moov precedes mdat. Updated full simulator share/tip flow passed. Received Messages appearance still needs a physical-device check.
- Share completion now has a “Buy me a coffee” text button below Done. It opens TipJarSheet, reusing TipJarSection and the app-owned TipStore; dismissing returns to the completed clip.
- Full simulator flow passed including opening/closing the tip options and preserving Re-share/Done. Completion and tip-option screenshots visually checked. Included in build 10.

## Latest simplification (build 9, 2026-09-14)
- Removed the artificial two-second splash, its view/timers and duplicate SplashIcon asset. Launch opens directly to the idle player; prior splash notes below are historical.
- Removed the C pre-main debug bootstrap. The SwiftUI root task invokes the same explicit debug harness flags once per process.
- UI tests retain screenshots in their result bundle; removed duplicate writes to an old agent-session path.
- Kept drum-break timing and StoreKit verification/recovery logic: these enforce requested behavior rather than speculative abstractions.
- Validation: unsigned iOS Release build passed; simulator full generator flow passed (playback, controls, render/share); explicit 8-second debug export passed with thumbnail and share metadata. Included in build 9.

# Liminal Generator — Session Handoff

Last updated: 2026-09-14. Branch: `codex/ntscrt-vhs-slideshow`.

Build **1.0 (9)** is live on TestFlight for the **Internal** group.
Apple reports VALID and IN_BETA_TESTING; Internal group membership verified.
Includes drum breaks, the optional tip jar, and direct launch without an artificial splash delay.
Signed archive/IPA: `/tmp/liminal-testflight-9/`. Delivery UUID: `73878701-c093-4bbc-9ae2-6440c56eb99e`.
Next build number: 10.

Build **1.0 (8)** previously shipped to the **Internal** group.
Signed Release archive, App Store IPA export and upload succeeded on 2026-09-14;
App Store Connect reported VALID and IN_BETA_TESTING.
Includes relative animation timing, horizontal color bleed, highlight glow,
tape weave/head switching, and matching export treatment with corrected scanlines.
Details and verification: `docs/VHS-effect.md`. Both existing simulator UI tests
passed; final export color pass was rebuilt and checked with an eight-second render.
Physical-device performance and artistic tuning are the next checks.

### Added in build 9

- Export drum breaks: two two-bar breaks near one-third/two-thirds of full-length exports; keys/bass continue and drums return in phase. DSP regression harness and 120-second export passed. See `docs/Drum-breaks.md`.
- Optional native tip jar in About: three consumable tips ($1.99/$4.99/$9.99 US base prices); all features remain free. App Store products, localized metadata, prices, territory availability and review screenshots configured, all READY_TO_SUBMIT. See `docs/Tip-jar.md` for product IDs, StoreKit scheme and validation limitations. Included in build 9; real purchase availability still requires App Store setup/approval.

### Previous release (historical)

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
- `LiminalGenerator/UI` — SplashView, MainView, VHSImageCard (swipe paging w/ wraparound; also owns the
  CRT off/on power-state animation and the PLAY button's pre-first-tap attract pulse — see "State / known
  items"), `VHSShader.metal` (scanlines/grain/chroma aberration/vignette/tracking jitter via SwiftUI
  layerEffect; out-of-bounds samples return transparent so paged views don't bleed onto their neighbors),
  VHSTimestamp (random late-80s–90s OSD date), deck-style Components, AboutSheet.
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
- CRT power state / PLAY attract pulse / BREAKS toggle (branch `codex/ntscrt-vhs-slideshow`, see "Unreleased"
  above): verified on simulator only, not yet in a TestFlight build.
- OPEN: App Store screenshots under `docs/app-store/screenshots/*.png` still bake in the pre-fix right-edge
  smear artifact and need regenerating before the next store submission.
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


## App Store preparation — September 15, 2026

Build 1.0 (11) is VALID, selected for the draft App Store version, and IN_BETA_TESTING in Internal. Includes CTA feedback, About privacy/support links, and SF Symbol dice fix. Final full UI flow passed. Metadata, screenshots, free worldwide pricing, manual release, age rating 9+, and published Data Not Collected disclosure are prepared. Business agreements, banking, tax, and DSA are active. All three tips are grouped in the unsubmitted review draft. App version cannot be added until private review contact first/last name and phone are supplied; use hello@thegapco.com for email. Physical-device purchase/full-render/share checks remain. See docs/app-store/README.md for IDs, artifacts, and remaining steps. No review submission or public release performed.


### Review contact completed

User supplied private App Review contact details; saved to App Store Connect with hello@thegapco.com. Version 1.0 was successfully added to draft 2d528b5c-7f5d-40a4-bc64-fc0141989ebb alongside all three tips (four READY_FOR_REVIEW items). No submission made; submittedDate remains null. Only final physical-device TestFlight validation remains before submission.


### Post-build-11 UI polish

Waveform selectable chips now fill equal-width columns inside their background/border. Bass/drum bodies use shared LiminalAccordionBody: fixed natural content height, top-aligned zero-to-natural frame, clipping below the header, 250 ms transitions.dev easing and fade, disabled hidden hit testing/accessibility, Reduced Motion supported. Removed move-from-top transitions. These source changes are not in TestFlight build 11; next candidate must use build 12 and new screenshots.


### TestFlight build 12 — September 15, 2026

Version 1.0 (12), build ID 47ebb704-27d5-4644-8773-cf9b67b6776d, uploaded successfully and confirmed VALID / IN_BETA_TESTING with Internal group membership. Testing notes saved. Includes equal-width waveform chips and clipped bass/drums accordions. Archive and IPA are under /tmp/liminal-testflight-12/. Build 12 is selected for the App Store version in the four-item review draft. The four App Store screenshots were refreshed from the final build 12 UI test, processed COMPLETE, and verified in order. Nothing submitted for App Review.

### App Review submission — September 15, 2026

Submission 2d528b5c-7f5d-40a4-bc64-fc0141989ebb was submitted at 2026-09-15T13:46:50.489Z. App version 1.0 build 12 and all three consumable tips report WAITING_FOR_REVIEW. Release is manual, so approval will not publish the app until manually released.
