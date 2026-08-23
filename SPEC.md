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
   - **VHS image card**: shows current library image (1:1 square, all 23 bundled images cropped square) with
     live VHS filter (see below). Swipe left/right pages through the library (wraps around, random start
     index). PLAY ▶ / PAUSE toggle overlaid bottom-left. OSD overlay: random retro timestamp (e.g. "OCT 26 1998"
     + time, random per image swipe, late-80s–90s dates), blinking red ● REC while playing, "SP" top-right.
     OSD uses a VCR-style rendering (Space Mono, slight glow).
   - **SYNTH card** ("SYNTH" tape-spine header): dice button "GENERATE MELODY" → new random arpeggio.
     Readout row: `SEQ: A-C-E-G` (note names of the pattern) and `BPM: <effectiveBPM>` (the actual playback
     tempo — loop bpm or base melody bpm, times the SPEED multiplier; see "Musical style"). Below that, a
     COLOR slider (endpoints "DARK"/"BRIGHT") controlling the synth voice's tone/timbre only (not drums).
   - **GLOBAL ENV card**: SPACE slider (label right: REV_DECAY, scale 0–10), AGE slider (WOW_FLUTTER, 0–10),
     and SPEED slider (label right: TEMPO, scale 0–10) — a tape-style playback-rate control. All three affect
     the entire mix (synth + drums together, including the drum loop's playback rate/pitch, like a tape deck's
     speed control).
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
  `speed: Float` (0–1, default 0.5 → tempo/playback-rate multiplier 0.70x…1.30x, 0.5 = 1.0x/normal — see
  "Musical style"), `color: Float` (0–1, default ~0.5 → synth-only filter tone, dark…bright — see below),
  `drumsEnabled`, `drumLevel: Float` (0–1 mapped -inf…+6dB), `currentPattern: ArpeggioPattern`,
  `currentBeat: DrumPattern`, `effectiveBPM: Int` (read-only, computed: `round(baseTempoSource * speedMultiplier)`
  where `baseTempoSource` is the active loop's bpm when `drumsEnabled`, else a fixed `baseMelodyBPM` constant
  — this is what the SYNTH card's BPM readout displays). Methods: `start()`, `stop()`, `regenerateMelody()`,
  `regenerateBeat()`. Configure AVAudioSession `.playback`. Handle interruptions (pause on interrupt).
- **Musical style** ("liminal" per reference): slow, hazy, melancholic, always straight/even rhythm (no
  swing, no rests, no held notes — every step plays a note). `PatternGenerator`:
  - **Randomized by `regenerateMelody()` — ONLY these three:** root key (0–11), scale, and pattern shape.
    Nothing else is re-rolled per regenerate (step count, octave span, and the fixed base tempo are program
    constants; per-note velocity may still carry small humanization jitter, which is not "randomizing a
    parameter", just accenting).
  - **Scale** (weighted): 90% picked uniformly from {minor pentatonic (0,3,5,7,10), dorian (0,2,3,5,7,9,10),
    mixolydian (0,2,4,5,7,9,10), lydian (0,2,4,6,7,9,11)}; 10% major pentatonic (0,2,4,7,9) as an occasional
    sprinkle. (Natural-minor/major-7-pentatonic from the old generator are retired.)
  - **Pattern shape** (exactly one of three, chosen at random each regenerate): `up` (ascend through the
    scale across the fixed octave span), `down` (descend), or `up-down` (ascend to the top then back down,
    classic zigzag arpeggio — no repeated note at the turnaround). Straight, even step timing throughout —
    no rests, no held/tied notes, no swing.
  - Tempo is **decoupled from pattern generation** — see the SPEED control above; `ArpeggioPattern` no longer
    carries a randomized bpm used for playback (the tick clock's rate comes from `effectiveBPM`, not from the
    pattern).
  - Synth voice: 2 detuned soft oscillators (triangle/sine mix) + gentle lowpass, slow attack (20–80ms),
    long release (0.5–1.5s), subtle chorus-y detune. Warm, pad-like pluck — never harsh. **COLOR** (0–1)
    shifts the voice's filter brightness dark→bright (layered on top of, not replacing, the existing
    envelope-driven brightness contour); affects only the synth, never the drum loop.
  - **SPEED** (0–1, multiplier 0.70x–1.30x): a global tape-style playback-rate control, applied like a
    turntable/tape-deck speed knob — it scales both the tick clock (arp + loop timing) *and* the drum loop's
    sample playback rate together, so tempo and the loop's pitch shift together (authentic tape-speed
    character; the synth's own note pitches are NOT altered by SPEED, only their timing/tempo).
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
  - **Tempo-sync rule** (updated for SPEED): the shared 16th-note tick clock (drives both the arp and the
    loop's start/swap timing) runs at `effectiveBPM` = `round(baseTempoSource * speedMultiplier(speed))`,
    where `baseTempoSource` is the active loop's bpm while drums are enabled, else the fixed `baseMelodyBPM`
    constant. Enabling/disabling drums, any loop swap (`regenerateBeat()` or a fresh loop picked by
    `renderOffline`'s seed), and any `speed` change are all applied at tick-clock recompute points; the loop
    swap/enable specifically still applies only at the next **bar boundary** (every 16 ticks) with the loop's
    sample cursor reset to 0 there, keeping the arp's bar phase and the loop start phase-aligned. `speed`
    changes may apply immediately (smoothed to avoid zipper/clicks) since they scale time uniformly rather
    than swapping content. `regenerateMelody()` while drums are on keeps the melody's key/scale/pattern but
    the effective tempo stays governed by the loop + speed as above.
- `ArpeggioPattern.displaySeq` → e.g. "A-C-E-G" (first 4 distinct pitch classes) for the UI readout.
- **Offline render**: `renderOffline(duration: 120s, fadeIn: 3s, fadeOut: 5s, progress: (Double)->Void) async throws -> URL`
  using AVAudioEngine `enableManualRenderingMode(.offline)` with an identical graph + same DSP core seeded
  with the *current* patterns/params — including the live `speed` and `color` values and the *same* decoded
  `LoopBuffer` instance as the active loop (bit-identical audio, including tape-speed character, in the
  rendered MP4 vs. live playback). Output: 44.1kHz stereo CAF/WAV in temp dir. Must be cancellable.

## Video/share pipeline (`Render/`)
- `ClipRenderer`: builds 120s **square** MP4, 848×848, 30fps, H.264 + AAC via AVAssetWriter (matches the
  1:1 image library; previously 848×1264 portrait — updated for the square image aspect ratio).
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

### Addendum (square images + SPEED/COLOR + arp rewrite, 2026-08-23)
`ArpeggioPattern` and `AudioEngineController` are updated (superseding the shapes above — this is the
current pinned contract for these types; other structs unchanged):
```swift
struct ArpeggioPattern {
    var displaySeq: String          // e.g. "A-C-E-G" (unchanged)
    // no randomized `bpm` used for playback anymore — tempo comes from AudioEngineController.effectiveBPM
}

@MainActor
final class AudioEngineController: ObservableObject {
    // ...existing published properties unchanged, PLUS:
    @Published var speed: Float             // 0...1, default 0.5, tempo/rate multiplier 0.70x...1.30x
    @Published var color: Float             // 0...1, default ~0.5, synth-only tone dark(0)...bright(1)
    @Published private(set) var effectiveBPM: Int   // round(baseTempoSource * speedMultiplier(speed))
}
```
Image library images are now 1:1 square (848×848, center-cropped from the original 848×1264 sources, no
upscaling). `ClipRenderer` output is 848×848 (see Video/share pipeline above). `VHSImageCard`'s aspect ratio
constraint changes from `848/1264` to `1.0`.

### Addendum 2 (real COLOR filter, waveform chips, arp range fix, bassline, 2026-08-23)
Feedback from testing build 1.0 (2): COLOR's effect was too subtle to notice (it was a mild ±multiplier on
an already-narrow hardcoded cutoff range) — this is now a REAL, dramatic, full-range filter control.

- **COLOR redefined**: `color: Float` (0...1, same published property, same UI slider) now directly sets
  the cutoff frequency of a genuine **24dB/octave (4th-order) lowpass filter** on the synth voice: `color=0`
  → fully closed (cutoff ~60–80Hz, the tone is essentially just a muffled low rumble), `color=1` → fully open
  (cutoff ~18–20kHz, effectively unfiltered/bright). Logarithmic mapping between those endpoints. The
  existing per-note envelope-driven brightness contour still layers on top of (opens further from) this base
  cutoff — don't remove the pluck articulation, just make the base cutoff dramatically audible across the
  slider's range. Parameter must be smoothed (no zipper/clicks on drag).
- **Waveform chips**: below the COLOR slider in the SYNTH card, a row of `LiminalChip`-style single-select
  chips: SINE, TRIANGLE, SQUARE, SAW. Selecting one sets `AudioEngineController.waveform: LiminalWaveform`
  (new enum, published, default `.triangle`) — the melody voice's oscillator shape (replacing the old
  hardcoded triangle/sine blend). The two detuned oscillators per voice keep their chorus-y detune, just
  both now render the selected waveform. Square/saw may use simple naive (non-band-limited) waveshaping —
  the 24dB lowpass and existing age/wow-flutter processing will tame most aliasing harshness, acceptable for
  this app's lo-fi aesthetic. Waveform selection is melody-only (does not affect the bassline voice or drums).
- **Arpeggio range fix**: generated arp notes must NEVER deviate from the pattern's root by more than 24
  semitones (2 octaves) in either direction — a hard invariant, verify it holds across many generated
  patterns (this was previously loosely bounded and needs an explicit fix + regression check).
- **New BASSLINE section**, positioned between the SYNTH (melody) card and the GLOBAL ENV card (card order
  becomes: VHS image card → SYNTH → **BASSLINE** → GLOBAL ENV → DRUMS → RENDER & SHARE). Mirrors the DRUMS
  card's shape: "ENABLE BASS" toggle, "GENERATE BASS" dice button, a COLOR slider (own independent 24dB
  lowpass instance, DARK/BRIGHT endpoints, same log-mapping design as melody's COLOR) and a LEVEL slider
  (-INF…+6dB, same curve as `drumLevel`). No SEQ/BPM readout row (not requested).
  - Bassline is a simple, low-register, single-oscillator (or lightly detuned pair) voice — NOT the
    selectable waveform (fixed to something warm/clean, e.g. sine or triangle, agent's call) — pitched
    roughly 1–2 octaves below the melody's root.
  - Bass notes are **scale-degree-based against the melody's CURRENT root+scale** (mostly root/fifth/octave,
    occasional third for a "simple/melodic" walking feel) so it always harmonizes — never an independently
    random key. Whenever `regenerateMelody()` picks a new key/scale, the bassline must be refreshed to match
    (either regenerate a fresh pattern or re-resolve degrees against the new root/scale — implementer's
    choice, but it must never sound like it's in the wrong key after a melody regenerate).
  - Rhythm is deliberately **irregular** (unlike the melody's strict straight/even steps): rests, held/tied
    notes, syncopated placement — "simple/melodic", not a run through the scale. `regenerateBass()` re-rolls
    a new rhythmic/note pattern (still against the current key/scale).
  - Bass timing rides the SAME shared tick clock as melody/drums (driven by `effectiveBPM`, which already
    incorporates SPEED) — never an independent tempo, always in sync regardless of drums on/off or the
    SPEED slider position.

Pinned contract additions to `AudioEngineController`:
```swift
enum LiminalWaveform: String, CaseIterable { case sine, triangle, square, saw }

@MainActor
final class AudioEngineController: ObservableObject {
    // ...existing properties unchanged (color's semantics change per above, property itself doesn't), PLUS:
    @Published var waveform: LiminalWaveform        // default .triangle; melody-only
    @Published var bassEnabled: Bool                // default false
    @Published var bassColor: Float                 // 0...1, default ~0.5, own 24dB lowpass
    @Published var bassLevel: Float                 // 0...1 (maps -inf...+6dB), default ~0.65
    func regenerateBass()                           // re-rolls bass rhythm/notes against current key/scale
}
```
`renderOffline` must seed the offline core with the live `waveform`, `bassEnabled`, `bassColor`, `bassLevel`,
and current bass pattern, same as every other live parameter.

### Addendum 3 (ambient-pad pivot — "Snowfall" style, 2026-08-23) — SUPERSEDES the arpeggio engine
Product direction change: the rigid arpeggio rules from Addendum 1/2 are retired. The generator must emulate
the style of popular liminal/dreamcore ambient tracks (reference: "Snowfall" — Øneheart × reidenshi): slow,
washed-out, relaxing, nostalgic. That style is NOT arpeggio-driven; its DNA is:

**1. Pad chords (the core layer, replaces the arpeggio):**
- Random minor key per generate (always minor tonality; a dorian color chord is allowed inside progressions).
- A 4-chord progression looping forever, ONE CHORD PER BAR (16 ticks), drawn from a curated pool of proven
  nostalgic minor progressions (degrees relative to the minor key): i–VI–III–VII, i–VII–VI–VII, i–iv–VI–v,
  i–VI–iv–v, VI–VII–i–i, i–v–VI–III, i–III–VII–VI. Chords are voiced warmly: 4–5 voices spread over ~2
  octaves, root low, with add9 or sus2 extensions frequently substituted for plain triads (genre staple —
  gives the "nostalgic shimmer"); avoid tight semitone clusters.
- Pad voice: FIXED sound design (not user-selectable): per chord voice, 3 detuned oscillators (saw+triangle
  blend, ±5–12 cents) → the existing 24dB lowpass. Slow attack 0.5–1.5s, high sustain, long release 2–4s.
  Chord transitions must crossfade (old chord releases while new one swells — no gaps, no clicks).
- The SYNTH card's COLOR slider (24dB filter) now governs the whole synth layer's base cutoff (pads AND
  melody voice; each may have its own filter instance but tracking the same `color` value). Bass keeps its
  independent `bassColor` filter.
- `ArpeggioPattern` is repurposed as the generated "scene": key, progression, voicing seed, melody motif.
  `displaySeq` now returns the chord progression as chord names, e.g. "Am–F–C–G" (readable, user-facing);
  the UI's readout label changes from "SEQ:" to "PROG:".

**2. Sparse floating melody (on top, quiet):**
- 2–5 soft notes per 2-bar phrase from the key's minor pentatonic, 1–2 octaves above the pads, long slow
  attacks, occasionally resting for an entire phrase (space is part of the style). Motif repeats across
  phrases with slight variation (octave shift or neighbor tone), so it feels composed, not random.
- The waveform chips (SINE/TRIANGLE/SQUARE/SAW) select THIS voice's oscillator only. Default changes to
  `.sine` (fits the style best). Melody rides through the same COLOR filter and shared FX chain.

**3. Sub-bass (the BASSLINE section, repurposed):**
- A deep, soft sub (fixed sine, one octave below the pad roots) following the CURRENT BAR'S CHORD ROOT —
  no more walking/melodic bassline. Slow attack swells. `regenerateBass()` re-rolls a subtle movement
  variation (whole-bar holds vs. gentle re-articulations vs. an occasional octave-up or fifth passing tone
  at bar transitions). Existing UI (toggle/COLOR/LEVEL/GENERATE) unchanged.

**4. Breathing (always on, no UI):**
- A gentle tempo-synced volume swell (sidechain-pump feel) on pads + bass: smooth dip of ~2–4dB per bar
  (or per half-bar when drums are enabled, lightly following the beat), with a soft curve — subtle,
  "inhale/exhale", never choppy. Melody is NOT ducked (it floats above).

**5. Unchanged:** drums (loop playback, tempo-master when enabled), SPACE/AGE/SPEED semantics, effectiveBPM
(base tempo may drop to ~72 for the style — implementer's call within 68–80), tick-clock architecture,
offline-render parity (seed everything: scene, motif, bass variation, breathing phase).

**Regeneration semantics:** GENERATE MELODY re-rolls the whole scene (key, progression, voicing seed, melody
motif). GENERATE BASS re-rolls only the bass movement variation. GENERATE BEAT unchanged (loop pick).

**Quality bar for this addendum:** chord tones always diatonic to the rolled key (with the allowed
add9/sus2 substitutions), melody strictly in the key's minor pentatonic, chord changes exactly on bar
boundaries, crossfades click-free, breathing measurable as periodic RMS modulation at the bar rate,
no clipping at full COLOR/space/age extremes. The result must FEEL slow, warm, and melancholic —
when in doubt, choose fewer notes, slower envelopes, and darker defaults.

## Quality bar
- `xcodebuild -scheme LiminalGenerator -destination 'iPhone 17 Pro simulator' build` must succeed with no
  warnings-as-errors issues; app runs, audio plays immediately on PLAY, no crackles (render callback does no
  allocation/locks), UI at 60fps, render completes ≤ ~60s on simulator.
- Unit tests where cheap (pattern generator determinism with seeded RNG, fade math, timestamp formatting).
