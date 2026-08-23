# Liminal Generator — Architecture Spec (source of truth)

Free, simple iOS app that generates liminal-style ambient music (random arpeggios + optional lo-fi drums)
over swipeable VHS-filtered images of empty spaces, and renders shareable 2-minute MP4 clips.

## Platform
- iPhone only, portrait-locked, iOS 17.0 deployment target, SwiftUI, no third-party dependencies.
- Xcode project generated with XcodeGen (`project.yml` at repo root → `LiminalGenerator.xcodeproj`).
- Bundle id: `com.gapco.LiminalGenerator` (GAPCO team XM2SC5YZ8C). App name: "Liminal Generator". Swift 5 language mode.
- Source root: `LiminalGenerator/` with subfolders `App/`, `Audio/`, `UI/`, `Render/`, `Resources/`.

## Design system (follow img/stitch_liminal_space_generator/liminal_analog/DESIGN.md exactly)
- Deep charcoal void background (#131313 surfaces, #0e0e0e lowest), CRT green primary (#33ff33 / #00e61b),
  glitch magenta secondary (#fe00fe), off-white text (#e5e2e1).
- Space Mono (bundled, OFL) for headers/labels/readouts, uppercase; system font for body.
  If font bundling fails, fall back to `.system(.monospaced)` — but prefer bundled Space Mono.
- Sharp corners (0 radius; 2px only on "hardware" buttons). Deck-style buttons with thick bottom border that
  "depress" on press. Blocky rectangular slider thumbs, CRT-green track fill. Thin outlined chips.
- Persistent low-opacity scanline/noise overlay across the whole UI.
- Screens to match mockups:
  - Main: `img/stitch_liminal_space_generator/generator_player/screen.png` (+ code.html for reference)
  - Render: `img/stitch_liminal_space_generator/share_clip/screen.png` ("ENCODING ANALOG SIGNAL")
  - Splash: `img/splash_screen/screen.png` (+ code.html)

## Screens & behavior
1. **Splash** (~2s, in-app after launch screen): black static texture, green camcorder glyph, glitch-styled
   "LIMINAL GENERATOR" wordmark, "ESTABLISHING ANALOG CONNECTION…" / "BUFFERING SIGNAL" readouts, then main.
2. **Main** (single scrollable card stack):
   - Header: dithered glyph + "LIMINAL GENERATOR", settings gear (gear can be non-functional placeholder or
     minimal about sheet).
   - **VHS image card**: shows current library image with live VHS filter (see below). Swipe left/right pages
     through the 24-image library (wraps around, random start index). PLAY ▶ / PAUSE toggle overlaid bottom-left.
     OSD overlay: random retro timestamp (e.g. "OCT 26 1998" + time, random per image swipe, late-80s–90s dates),
     blinking red ● REC while playing, "SP" top-right. OSD uses a VCR-style rendering (Space Mono, slight glow).
   - **SYNTH card** ("SYNTH" tape-spine header): dice button "GENERATE MELODY" → new random arpeggio.
     Readout row: `SEQ: A-C-E-G` (note names of the pattern) and `BPM: 82`.
   - **GLOBAL ENV card**: SPACE slider (label right: REV_DECAY, scale 0–10) and AGE slider (WOW_FLUTTER, 0–10).
     Both affect the entire mix (synth + drums).
   - **DRUMS card**: "ENABLE LOFI BEATS" toggle; when on, reveals LEVEL slider (-INF…+6dB), dice button
     "GENERATE BEAT", and a readout row (`LOOP: <displayName>` / `BPM: <loop bpm>`) below it.
   - **RENDER & SHARE** full-width red bar button at bottom.
3. **Render screen** (modal, matches share_clip mockup): "ENCODING ANALOG SIGNAL▮" header, SRC: VTR_01 /
   DEST: MEMORY row, progress bar as ASCII/segments with `REC \ ///` spinner, terminal log lines appearing as
   phases complete ("> TRACKING... [OK]", "> SYNC PULSE... [LOCKED]", "> BUFFER... NN%", "> AUDIO PASS... ",
   "> VIDEO PASS... ", "> MUX... "). On completion presents the iOS share sheet with the MP4. Cancel supported.

## Audio architecture (`Audio/`)
All DSP is plain-Swift, sample-based, shared verbatim between realtime and offline rendering.

- `LiminalDSPCore`: owns `SynthVoice` bank, `ArpeggioSequencer`, `LoopPlayer`, `WowFlutterProcessor`,
  `TapeHiss`. Single entry `render(into: UnsafeMutablePointer<Float> interleaved stereo, frames: Int)`.
  Sample-accurate step clock inside render (no Timers for audio). Thread-safe parameter setters (atomics or
  lock-free snapshot struct).
- `AudioEngineController: ObservableObject` — wraps AVAudioEngine: `AVAudioSourceNode(LiminalDSPCore)` →
  `AVAudioUnitReverb` → mainMixer. Published: `isPlaying`, `space: Float` (0–1 → reverb wetDry 0–100 and
  slight decay character), `age: Float` (0–1 → wow/flutter depth+rate, tape hiss level, gentle lowpass),
  `drumsEnabled`, `drumLevel: Float` (0–1 mapped -inf…+6dB), `currentPattern: ArpeggioPattern`,
  `currentBeat: DrumPattern`. Methods: `start()`, `stop()`, `regenerateMelody()`, `regenerateBeat()`.
  Configure AVAudioSession `.playback`. Handle interruptions (pause on interrupt).
- **Musical style** ("liminal" per reference): slow, hazy, melancholic. `PatternGenerator`:
  - Random key; scales: natural minor, dorian, or major-7-flavored pentatonic. BPM 68–96.
  - Arpeggio: 8 or 16 step patterns over 1–2 octaves, mostly chord tones (i–VI–III–VII style progressions
    optionally implied), occasional rests and held notes; velocity variation.
  - Synth voice: 2 detuned soft oscillators (triangle/sine mix) + gentle lowpass, slow attack (20–80ms),
    long release (0.5–1.5s), subtle chorus-y detune. Warm, pad-like pluck — never harsh.
  - `DrumPattern` is loop-selection metadata (`loopIndex`, `displayName`, `bpm`), not a synthesized
    pattern: drums are **playback of one of 10 bundled CC0 lo-fi hip-hop loops**
    (`Resources/Loops/*.wav`, mono 44.1kHz s16, bar-exact 4 bars each, manifest in `LoopManifest.swift`)
    rather than synthesized 808 hits. `regenerateBeat()` picks a random loop that is never the currently
    active one (guaranteed change). `LoopPlayer` (in `LoopPlayer.swift`, replacing the old
    `DrumMachine.swift`) decodes the active loop's WAV into a Float32 buffer off the render thread
    (`LoopLoader`, decoded once per process and cached) and plays it back inside `LiminalDSPCore`'s
    render loop with a sample-accurate cursor and seamless wraparound (the loop files are pre-declicked
    at their bar boundary). The loop signal is summed into the same bus the old synthesized drums used,
    so it passes through the shared wow/flutter, tape hiss, age-lowpass, reverb send, and final soft-clip
    exactly like before — SPACE/AGE keep affecting drums the same way. A light fixed ~8.5kHz lowpass sits
    on the loop bus for gentle lo-fi consistency; no bit-reduction or other heavy processing (the loops
    are already lo-fi).
  - **Tempo-sync rule**: the shared 16th-note tick clock (drives both the arp and the loop's start/swap
    timing) normally runs at the arp pattern's own bpm. While drums are enabled, it instead runs at the
    active loop's bpm — so the arpeggio's tempo follows the loop. Enabling/disabling drums, and any loop
    swap (`regenerateBeat()` or a fresh loop picked by `renderOffline`'s seed), is applied only at the
    next **bar boundary** (every 16 ticks — a full cycle of an 8- or 16-step arp pattern, and one of the
    loop's own 4 bars once tempo-locked): the loop's sample cursor resets to 0 there so its downbeat lands
    exactly on the bar, keeping the arp's bar phase and the loop start phase-aligned. When drums are
    disabled, the arpeggio reverts to its own pattern bpm. `regenerateMelody()` while drums are on keeps
    the melody's notes/scale but the effective bpm stays the loop's (the new arp pattern's own random bpm
    field is simply unused while `drumsEnabled`).
- `ArpeggioPattern.displaySeq` → e.g. "A-C-E-G" (first 4 distinct pitch classes) for the UI readout; also `bpm`.
- **Offline render**: `renderOffline(duration: 120s, fadeIn: 3s, fadeOut: 5s, progress: (Double)->Void) async throws -> URL`
  using AVAudioEngine `enableManualRenderingMode(.offline)` with an identical graph + same DSP core seeded
  with the *current* patterns/params, including the *same* decoded `LoopBuffer` instance as the active
  loop (bit-identical drum audio in the rendered MP4 vs. live playback). Output: 44.1kHz stereo CAF/WAV in
  temp dir. Must be cancellable.

## Video/share pipeline (`Render/`)
- `ClipRenderer`: builds 120s portrait MP4, 848×1264 (or 720×1080 if perf requires; keep source aspect 2:3),
  30fps, H.264 + AAC via AVAssetWriter.
  - Audio: from offline render above (apply fades in the audio pass).
  - Video: current image processed per-frame with Core Image VHS pipeline (must visually match the live SwiftUI
    shader): scanlines, animated noise/grain, slight chroma aberration, vignette, occasional horizontal jitter/
    tracking line, and the OSD timestamp + ● REC baked in (timestamp seconds tick during the clip).
    Video fades from/to black matching audio fades. Use a CVPixelBufferPool; render off the main actor;
    report combined progress (audio pass then video pass) and support cancellation.
  - Share: present `UIActivityViewController`/ShareLink with the MP4 URL.

## Live VHS look (`UI/`)
- SwiftUI `layerEffect`/`colorEffect` Metal shader (iOS 17 `Shader` API) applied to the image card:
  scanlines, luma noise, chroma aberration at edges, vignette, subtle vertical jitter; time-driven via
  `TimelineView`. Keep GPU-cheap. OSD text is a SwiftUI overlay (shared component with ClipRenderer's CI text
  generator so the look matches).

## Assets (`Resources/`)
- 24 library images copied from `img/stitch_liminal_space_generator/*/screen.png` (exclude generator_player,
  share_clip, liminal_analog folders and the DO-NOT-USE folder) into asset catalog as `liminal_01`–`liminal_24`,
  with a manifest enum. App icon from `img/App-Icon.png` (single-size 1024 icon). Space Mono Regular/Bold TTFs
  bundled + UIAppFonts. Launch screen: plain #0e0e0e.
- `Resources/Loops/`: 10 bundled CC0 lo-fi hip-hop drum loops (`loop_<bpm>_<slug>.wav`, mono 44.1kHz s16,
  bar-exact 4 bars each), manifest in `LoopManifest.swift` (`LoopLibrary.all: [LoopInfo]` with
  `fileName`/`bpm`/`bars`/`displayName`). Full source/license record per file in `LICENSES-LOOPS.md`.

## Pinned API contract (Phase 2 — all agents conform EXACTLY; do not rename)
Note: the image library shipped with 23 images (`liminal_01`…`liminal_23`), not 24. `ImageLibrary` in
Resources/ImageLibrary.swift is the existing manifest — use it, don't redefine it.

```swift
// Audio/ — owned by the audio agent
struct ArpeggioPattern {            // + whatever internals the generator needs
    var displaySeq: String          // e.g. "A-C-E-G"
    var bpm: Int
}
struct DrumPattern {                 // loop selection, not a synthesized pattern (see Audio architecture)
    let loopIndex: Int
    let displayName: String
    let bpm: Int
}

@MainActor
final class AudioEngineController: ObservableObject {
    @Published var isPlaying: Bool          // set via play()/pause(), not directly by UI
    @Published var space: Float             // 0...1, didSet pushes to DSP/reverb
    @Published var age: Float               // 0...1
    @Published var drumsEnabled: Bool
    @Published var drumLevel: Float         // 0...1 (maps -inf...+6dB)
    @Published private(set) var currentPattern: ArpeggioPattern
    @Published private(set) var currentBeat: DrumPattern
    func play()
    func pause()
    func regenerateMelody()
    func regenerateBeat()
    /// Offline render of the CURRENT patterns/params to a 44.1k stereo audio file (CAF or WAV).
    /// Progress 0...1. Must be cancellable via task cancellation. Live playback keeps working after.
    func renderOffline(duration: TimeInterval,
                       fadeIn: TimeInterval,
                       fadeOut: TimeInterval,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

// UI/ — owned by the UI agent
struct VHSTimestamp {               // random retro date; regenerated on image swipe
    var dateText: String            // "OCT 26 1998"
    var timeText: String            // "11:42:07 PM" (or 24h "23:42:07" — pick one, use everywhere)
    static func random() -> VHSTimestamp
}

// Render/ — owned by the render agent. UI presents this in a .fullScreenCover:
struct RenderScreen: View {
    init(engine: AudioEngineController,
         imageName: String,          // asset name e.g. "liminal_07"
         timestamp: VHSTimestamp)
}
```

File-ownership rules: audio agent writes only in `Audio/`; UI agent only in `UI/` and `App/`
(may replace the stub `MainView.swift`, may extend `Theme.swift`); render agent only in `Render/`.
Nobody edits `project.yml`, `Info.plist`, `Resources/` (sources are globbed — new .swift files are picked
up by `xcodegen generate`). If a dependency from another agent doesn't exist yet at build time, verify what
compiles standalone and report the gap instead of stubbing someone else's types.

## Quality bar
- `xcodebuild -scheme LiminalGenerator -destination 'iPhone 17 Pro simulator' build` must succeed with no
  warnings-as-errors issues; app runs, audio plays immediately on PLAY, no crackles (render callback does no
  allocation/locks), UI at 60fps, render completes ≤ ~60s on simulator.
- Unit tests where cheap (pattern generator determinism with seeded RNG, fade math, timestamp formatting).
