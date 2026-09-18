# Drum breaks (BREAKS toggle)

A "BREAKS" toggle in the DRUMS card (`AudioEngineController.breaksEnabled`, default `true`) controls a deterministic drum break schedule that now applies to BOTH live playback and exported renders — previously breaks only ever existed in exports. When a break fires (live or render), the drum loop AND the bassline drop out together; melody, pads, chorus, reverb, tape hiss, the loop's tempo/cursor and the breathing clock all continue unaffected. The toggle only has an effect while drums are enabled; with drums off there is nothing to break.

## Export path (unchanged math, now gated by the toggle)

When drums AND breaks are both enabled, a full two-minute export includes two two-bar drum breaks near one-third and two-thirds of its duration. Each return lands on a four-bar phrase boundary. At 80 BPM and normal speed, the breaks are 30–36 seconds and 78–84 seconds (timing follows the DSP's rounded sample clock). With BREAKS off, the export never constructs an arrangement at all — straight, uninterrupted drums and bass for the whole clip.

The intro/outro retain at least four bars of drums; breaks stay outside the export fades and have at least four bars between them. Shortened debug exports may have one break or none when space is limited. The arrangement is deterministic for the selected loop tempo, speed and duration.

Implementation: `DrumBreakArrangement.swift` plans sample ranges using the same rounded sixteenth-note duration as `LiminalDSPCore`. `AudioEngineController.performOfflineRender` only constructs an arrangement when `seed.drumsEnabled && seed.breaksEnabled`, and supplies it to its private offline DSP. The gain is applied after the drum lowpass, and now to the bass voice's output too, before the shared mix/effects.

## Live path: tempo-independent musical-clock schedule

Live playback's tempo isn't fixed — it changes with the SPEED slider and with loop swaps — so a frame-based plan like the export's would drift out of phase over a long session. Instead, live breaks are driven entirely by the shared musical clock already inside `LiminalDSPCore` (`globalTickIndex` / `ticksPerBar`, the same 16-tick bar grid the pad progression and loop-swap logic use).

`LiveDrumBreakSchedule` (in `DrumBreakArrangement.swift`, alongside the export arrangement) defines a repeating 48-bar cycle with two two-bar breaks, returning on four-bar phrase boundaries, at bars `[14, 16)` and `[30, 32)` of each cycle — the same one-third/two-thirds-ish placement as the export. At the default 80 BPM loop tempo and 1.0x SPEED that's two breaks roughly every 2.4 minutes (48 bars × 4 beats/bar ÷ 80 bpm), matching the "a couple of times over a couple of minutes" cadence. The bar bounds are plain `static let Int` constants (`break1Start`/`break1End`/`break2Start`/`break2End`), not a `[Range<Int>]` — `isBreakBar` runs on the audio render thread (from `doTick`), and a `static let` array is a lazily-initialized Swift global whose first access anywhere in the process would trigger a one-time heap allocation, which could land on the very first render callback. `LiminalDSPCore`'s header states everything reachable from `render` is allocation-free and lock-free, so this stays scalar-only, matching the existing `ticksPerBar` idiom.

`LiminalDSPCore.doTick` consults the schedule once per bar boundary (only when `breaksEnabled && drumsEnabled` — using the freshly-updated `activeTempoUsesLoop` flag as the "drums are actually running" check) and sets the target of a dedicated `smBreakGain` `SmoothedParam` (0 during a break bar, 1 otherwise). `render` reads `smBreakGain.next()` once per sample and multiplies it into both the drum and bass buses — the same 6ms-ish smoothing time constant used for `smDrumGain`/`smBassGain`, giving a click-free ramp comparable to the export's 5ms ramp, with no second ramp stacked on top. When an export `DrumBreakArrangement` is supplied (offline rendering), `render` uses the arrangement's own gain instead and the live schedule never runs on that instance, so the two never double-apply.

**Turning BREAKS or DRUMS off mid-break releases immediately, not at the next bar boundary.** Break *starts* stay bar-quantized (only decided in `doTick`'s bar-boundary block, so they always land on a phrase boundary), but a user flipping the toggle off while a break is already in progress shouldn't have to wait out the rest of the bar (up to ~3s of continued silence at 80 BPM) for it to take effect. `render()` — which already reads the latest snapshot once per callback — forces `smBreakGain`'s target back to unity every callback whenever `!breaksEnabled || !drumsEnabled`. This never fights `doTick`'s own bar-boundary target: `doTick` only ever asks for `0` when BOTH flags are true, exactly the case where this forced branch does nothing. The result is a release on the order of `smBreakGain`'s own ramp (tens of milliseconds), independent of how far away the next bar boundary is.

## Verification

`python3 tests/run-drum-break-tests.py` (compiles `LiminalGenerator/Audio/*.swift` with swiftc) checks:
- the export arrangement's math: both breaks across bundled tempo values and speed extremes, sample rates, fade protection, short clips, and ramp continuity;
- `LiveDrumBreakSchedule`'s 48-bar cycle math (bars `[14,16)`/`[30,32)`, repeating across multiple cycles);
- full-duration export DSP comparisons with bass enabled/disabled: inside each break the settled output matches a reference with BOTH the drum and bass buses silenced (not just drums); outside it, the settled output matches continuous drum+bass playback, proving phase continuity; with `breaksEnabled == false` the export is bit-identical to a fully continuous reference for the whole duration;
- live playback (no arrangement): exactly the expected break windows per 48-bar cycle, with drums AND bass silent inside (matching a fully-silent reference) and both back at full level outside (matching a fully-continuous reference), checked as a running max-abs-diff over the settled portion of every window rather than a single instantaneous sample (the synth content crosses zero regularly, so single-sample comparisons are flaky by construction);
- live playback with `breaksEnabled == false`, or with drums off, never ducks anything — bit-identical to a fully continuous/drums-off reference for the whole duration.

Full-pipeline smoke test: 120-second H.264/AAC video rendered successfully with drums enabled; planned breaks were 39.53–45.17s and 73.41–79.06s for the randomly selected 85 BPM loop. Thumbnail and share metadata generation also succeeded.

Released to the Internal TestFlight group in version 1.0 (9) on 2026-09-14 (export-only breaks). The BREAKS toggle and live schedule are a subsequent addition.
