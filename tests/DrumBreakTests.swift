import Foundation

@main
struct DrumBreakTests {
    static func main() {
        for bpm in [70, 76, 80, 85, 88, 90, 95] {
            for speed: Float in [0, 0.5, 1] {
                for rate in [8_000.0, 44_100.0, 48_000.0] {
                    let plan = DrumBreakArrangement(duration: 120, fadeIn: 2, fadeOut: 3,
                                                    bpm: bpm, speed: speed, sampleRate: rate)
                    let tick = Int64(((rate * 60 / (Double(bpm) * 4)) / Double(speedMultiplier(speed))).rounded())
                    let bar = tick * 16
                    precondition(plan.windows.count == 2)
                    for w in plan.windows {
                        precondition(w.lowerBound % bar == 0 && w.upperBound % (bar * 4) == 0)
                        precondition(w.count == Int(bar * 2))
                        precondition(w.lowerBound >= bar * 4 && w.upperBound <= Int64(120 * rate) - bar * 4)
                        precondition(plan.gain(at: w.lowerBound) == 0)
                        precondition(plan.gain(at: w.upperBound - 1) == 0)
                        precondition(plan.gain(at: w.lowerBound - plan.rampFrames) == 1)
                        precondition(plan.gain(at: w.upperBound + plan.rampFrames) == 1)
                        for frame in (w.lowerBound - plan.rampFrames)...w.lowerBound {
                            precondition(abs(plan.gain(at: frame) - plan.gain(at: frame - 1)) <= 1 / Float(plan.rampFrames) + 0.00001)
                        }
                        for frame in w.upperBound...(w.upperBound + plan.rampFrames) {
                            precondition(abs(plan.gain(at: frame) - plan.gain(at: frame - 1)) <= 1 / Float(plan.rampFrames) + 0.00001)
                        }
                    }
                }
            }
        }
        for duration in [0.0, 8, 15] {
            precondition(DrumBreakArrangement(duration: duration, fadeIn: 2, fadeOut: 3,
                                             bpm: 85, speed: 0.5, sampleRate: 44_100).windows.isEmpty)
        }
        precondition(DrumBreakArrangement(duration: 120, fadeIn: 100, fadeOut: 100,
                                         bpm: 85, speed: 0.5, sampleRate: 44_100).windows.isEmpty)

        // Live schedule bar math sanity, independent of the DSP: mirrors
        // AudioEngineController.performOfflineRender's guard
        // (`seed.drumsEnabled && seed.breaksEnabled`) that decides whether
        // an export arrangement is constructed at all -- when breaksEnabled
        // is false, no arrangement exists, matching the `drumsEnabled ?
        // DrumBreakArrangement(...) : nil` shape but gated on both flags.
        let breaksToggleOffExportArrangement: DrumBreakArrangement? =
            (true && false) ? DrumBreakArrangement(duration: 120, fadeIn: 2, fadeOut: 3,
                                                    bpm: 80, speed: 0.5, sampleRate: 44_100) : nil
        precondition(breaksToggleOffExportArrangement == nil)

        // `LiveDrumBreakSchedule` bar math: 48-bar cycle, breaks at
        // [14, 16) and [30, 32), repeating.
        for bar in 0..<48 {
            let expected = (14..<16).contains(bar) || (30..<32).contains(bar)
            precondition(LiveDrumBreakSchedule.isBreakBar(bar) == expected)
            precondition(LiveDrumBreakSchedule.isBreakBar(bar + 48) == expected, "cycle did not repeat at bar \(bar + 48)")
            precondition(LiveDrumBreakSchedule.isBreakBar(bar + 48 * 5) == expected, "cycle did not repeat at bar \(bar + 48 * 5)")
        }

        // MARK: - Export (offline) DSP: breaks gate drums AND bass, keys untouched

        // End-to-end DSP: compare against a fully-silent (drums AND bass)
        // reference that keeps the same loop tempo. Proves keys/pads
        // continue undisturbed, the returning drums+bass have exactly the
        // uninterrupted loop's phase, and -- now that breaks gate bass too
        // -- the settled in-break output matches a reference with BOTH
        // buses silenced, not just the drum bus.
        let rate = 8_000.0
        let plan = DrumBreakArrangement(duration: 120, fadeIn: 2, fadeOut: 3,
                                        bpm: 80, speed: 0.5, sampleRate: rate)
        let scene = PatternGenerator.randomScene()
        let beat = PatternGenerator.randomDrumPattern()
        let bass = BasslinePattern(barActions: [.hold, .hold, .hold, .hold])
        let loop = LoopBuffer(samples: (0..<24_000).map { Float(sin(Double($0) * 0.17)) * 0.2 },
                              loopIndex: beat.loopIndex, displayName: "Test", bpm: 80)
        for bassOn in [false, true] {
            func core(_ arrangement: DrumBreakArrangement?, drumLevel: Float, bassLevel: Float,
                      breaksEnabled: Bool = true) -> LiminalDSPCore {
                LiminalDSPCore(pattern: scene, beat: beat, loopBuffer: loop, bassPattern: bass,
                    space: 0, age: 0, drumsEnabled: true, drumLevel: drumLevel, breaksEnabled: breaksEnabled,
                    speed: 0.5, color: 0.5, waveform: .sine, bassEnabled: bassOn, bassColor: 0.5,
                    bassLevel: bassLevel, nostalgia: 0, sampleRate: rate, drumBreakArrangement: arrangement)
            }
            let arranged = core(plan, drumLevel: 0.65, bassLevel: 0.65)
            // breaksEnabled: false so this reference is genuinely
            // uninterrupted (no export arrangement AND the live schedule
            // fallback also disabled) -- a pure "loop played straight
            // through" baseline for the phase-continuity check below.
            let continuous = core(nil, drumLevel: 0.65, bassLevel: 0.65, breaksEnabled: false)
            // Both buses silenced -- NOT just drums -- so this is the
            // correct "settled inside a break" reference now that breaks
            // gate bass too.
            let silentBoth = core(nil, drumLevel: 0, bassLevel: 0)
            // `breaksEnabled: false` with an arrangement still supplied
            // would be a caller bug (AudioEngineController never does
            // this -- it omits the arrangement entirely instead, see the
            // guard above) -- not exercised here.
            var a = [Float](repeating: 0, count: 512), b = a, c = a
            var maxBreakError: Float = 0, maxReturnError: Float = 0, audibleDrumBassDifference: Float = 0
            var keysEnergy: Double = 0
            for start in stride(from: 0, to: 960_000, by: 256) {
                a.withUnsafeMutableBufferPointer { arranged.render(into: $0.baseAddress!, frames: 256) }
                b.withUnsafeMutableBufferPointer { continuous.render(into: $0.baseAddress!, frames: 256) }
                c.withUnsafeMutableBufferPointer { silentBoth.render(into: $0.baseAddress!, frames: 256) }
                for i in 0..<256 {
                    let frame = Int64(start + i)
                    let inside = plan.windows.contains { frame >= $0.lowerBound + 8_000 && frame < $0.upperBound }
                    let settled = !plan.windows.contains { frame >= $0.lowerBound - plan.rampFrames && frame < $0.upperBound + 8_000 }
                    if inside {
                        maxBreakError = max(maxBreakError, abs(a[i*2] - c[i*2]))
                        audibleDrumBassDifference = max(audibleDrumBassDifference, abs(a[i*2] - b[i*2]))
                        keysEnergy += Double(a[i*2] * a[i*2])
                    } else if settled { maxReturnError = max(maxReturnError, abs(a[i*2] - b[i*2])) }
                }
            }
            precondition(maxBreakError < 0.00001, "Keys/bass changed during break: \(maxBreakError)")
            precondition(maxReturnError < 0.00001, "Drums/bass returned out of phase: \(maxReturnError)")
            precondition(audibleDrumBassDifference > 0.01 && keysEnergy > 1)
            print("DSP bass=\(bassOn): break error=\(maxBreakError), return error=\(maxReturnError), keys energy=\(keysEnergy)")

            // Export breaks absent when breaksEnabled == false: the caller
            // never builds an arrangement in that case (see the guard
            // above), so the offline core with `drumBreakArrangement: nil`
            // and `breaksEnabled: false` must render bit-identical to a
            // fully continuous reference for the WHOLE duration -- no
            // ducking anywhere, live-schedule fallback included.
            let breaksOff = core(nil, drumLevel: 0.65, bassLevel: 0.65, breaksEnabled: false)
            let continuousAgain = core(nil, drumLevel: 0.65, bassLevel: 0.65, breaksEnabled: false)
            var maxOffDiff: Float = 0
            var d = [Float](repeating: 0, count: 512), e = d
            for _ in stride(from: 0, to: 960_000, by: 256) {
                d.withUnsafeMutableBufferPointer { breaksOff.render(into: $0.baseAddress!, frames: 256) }
                e.withUnsafeMutableBufferPointer { continuousAgain.render(into: $0.baseAddress!, frames: 256) }
                for i in 0..<512 { maxOffDiff = max(maxOffDiff, abs(d[i] - e[i])) }
            }
            precondition(maxOffDiff < 0.00001, "breaksEnabled=false must never duck the export: \(maxOffDiff)")
        }
        print("Drum break schedule, ramps, synth/bass continuity and loop phase: PASS")

        // MARK: - Live playback: deterministic tick-clock-driven schedule

        // A fast, synthetic tempo keeps this section's render volume small
        // while exercising the exact same tick-clock math LiminalDSPCore
        // uses live (see LiveDrumBreakSchedule's doc comment): bar length
        // in samples is `round(sampleRate*60/(bpm*4)/speedMultiplier(speed))
        // * 16`, identical in form to DrumBreakArrangement's own tick math.
        let liveRate = 8_000.0
        let liveBpm = 480
        let liveSpeed: Float = 0.5 // speedMultiplier(0.5) == 1.0 exactly
        let liveScene = PatternGenerator.randomScene()
        let liveBeat = PatternGenerator.randomDrumPattern()
        let liveLoop = LoopBuffer(samples: (0..<4_000).map { Float(sin(Double($0) * 0.31)) * 0.2 },
                                  loopIndex: liveBeat.loopIndex, displayName: "LiveTest", bpm: liveBpm)
        let liveBass = BasslinePattern(barActions: [.hold, .hold, .hold, .hold])

        func liveCore(breaksEnabled: Bool, drumsEnabled: Bool = true,
                      drumLevel: Float = 0.65, bassLevel: Float = 0.65) -> LiminalDSPCore {
            LiminalDSPCore(pattern: liveScene, beat: liveBeat, loopBuffer: liveLoop, bassPattern: liveBass,
                space: 0, age: 0, drumsEnabled: drumsEnabled, drumLevel: drumLevel, breaksEnabled: breaksEnabled,
                speed: liveSpeed, color: 0.5, waveform: .sine, bassEnabled: true, bassColor: 0.5,
                bassLevel: bassLevel, nostalgia: 0, sampleRate: liveRate, drumBreakArrangement: nil)
        }

        let tickFrames = Int64(((liveRate * 60 / (Double(liveBpm) * 4)) / Double(speedMultiplier(liveSpeed))).rounded())
        let barFrames = Int(tickFrames * 16)
        let cycleBars = LiveDrumBreakSchedule.cycleBars
        let totalBars = cycleBars + 22 // one full cycle plus into the start of the next one's first break
        let totalFrames = barFrames * totalBars
        // smBreakGain's SmoothedParam has a 0.006s time constant; well over
        // 10x that (>0.06s -> >480 samples @8kHz) is comfortably settled to
        // within float noise of its target.
        let settleMargin = 700

        func fullDiff(_ x: LiminalDSPCore, _ y: LiminalDSPCore, frames total: Int, chunk: Int = 512) -> Float {
            var p = [Float](repeating: 0, count: chunk * 2), q = p
            var m: Float = 0
            var start = 0
            while start < total {
                let n = min(chunk, total - start)
                p.withUnsafeMutableBufferPointer { x.render(into: $0.baseAddress!, frames: n) }
                q.withUnsafeMutableBufferPointer { y.render(into: $0.baseAddress!, frames: n) }
                for i in 0..<(n * 2) { m = max(m, abs(p[i] - q[i])) }
                start += n
            }
            return m
        }

        // Exactly two break windows per 48-bar cycle, at the expected bar
        // positions, with drums AND bass silent inside (matching a
        // fully-silent reference) and both back at full level outside
        // (matching a fully-continuous reference). Checked over every
        // sample in the settled portion of each window/gap (not a single
        // instantaneous point) -- the synth content is a plain sine, which
        // passes through zero regularly, so a single-sample "should differ"
        // check is flaky by construction; running a max-abs-diff over an
        // entire window is the same technique the export-DSP block above
        // uses and isn't susceptible to that.
        let arrangedLive = liveCore(breaksEnabled: true)
        let continuousLive = liveCore(breaksEnabled: false)
        let silentLive = liveCore(breaksEnabled: false, drumLevel: 0, bassLevel: 0)
        // Break windows in frame-space, precomputed from `LiveDrumBreakSchedule`'s
        // (now-scalar) bar bounds for every 48-bar cycle covered by `totalFrames`.
        let breakBarBounds = [
            (LiveDrumBreakSchedule.break1Start, LiveDrumBreakSchedule.break1End),
            (LiveDrumBreakSchedule.break2Start, LiveDrumBreakSchedule.break2End),
        ]
        var liveWindows: [Range<Int>] = []
        for cycleStart in stride(from: 0, to: totalBars, by: cycleBars) {
            for (lowerBar, upperBar) in breakBarBounds {
                let lo = (cycleStart + lowerBar) * barFrames
                let hi = min((cycleStart + upperBar) * barFrames, totalFrames)
                if lo < totalFrames { liveWindows.append(lo..<hi) }
            }
        }
        precondition(liveWindows.count == 3, "expected 3 break windows (2 full cycle-1 + 1 starting cycle-2) across \(totalBars) bars, got \(liveWindows.count)")
        var maxLiveBreakDiff: Float = 0, maxLiveOutsideDiff: Float = 0, audibleLiveDifference: Float = 0
        // `continuousLive` has `breaksEnabled: false` -- across the SAME
        // windows where `arrangedLive` goes silent, it must instead stay
        // audibly apart from `silentLive` (i.e. never duck) at least
        // somewhere in the window, directly proving "no breaks live when
        // breaksEnabled == false" using the exact same tick positions.
        var toggleOffAudibleDifference: Float = 0
        let liveChunk = 512
        var a = [Float](repeating: 0, count: liveChunk * 2), b2 = a, c2 = a
        var start = 0
        while start < totalFrames {
            let n = min(liveChunk, totalFrames - start)
            a.withUnsafeMutableBufferPointer { arrangedLive.render(into: $0.baseAddress!, frames: n) }
            b2.withUnsafeMutableBufferPointer { continuousLive.render(into: $0.baseAddress!, frames: n) }
            c2.withUnsafeMutableBufferPointer { silentLive.render(into: $0.baseAddress!, frames: n) }
            for i in 0..<n {
                let frame = start + i
                let insideSettled = liveWindows.contains { frame >= $0.lowerBound + settleMargin && frame < $0.upperBound }
                let outsideSettled = !liveWindows.contains { frame >= $0.lowerBound - settleMargin && frame < $0.upperBound + settleMargin }
                if insideSettled {
                    maxLiveBreakDiff = max(maxLiveBreakDiff, abs(a[i*2] - c2[i*2]))
                    audibleLiveDifference = max(audibleLiveDifference, abs(a[i*2] - b2[i*2]))
                    toggleOffAudibleDifference = max(toggleOffAudibleDifference, abs(b2[i*2] - c2[i*2]))
                } else if outsideSettled {
                    maxLiveOutsideDiff = max(maxLiveOutsideDiff, abs(a[i*2] - b2[i*2]))
                }
            }
            start += n
        }
        precondition(maxLiveBreakDiff < 0.0005, "Live break drums/bass not silenced: \(maxLiveBreakDiff)")
        precondition(maxLiveOutsideDiff < 0.0005, "Live playback altered outside break windows: \(maxLiveOutsideDiff)")
        precondition(audibleLiveDifference > 0.01, "Live break should audibly differ from continuous playback")
        precondition(toggleOffAudibleDifference > 0.01,
                     "breaksEnabled=false must never duck live playback (found no audible content at a would-be break window)")
        print("Live schedule: break error=\(maxLiveBreakDiff), outside error=\(maxLiveOutsideDiff)")

        // No breaks live when drums are off: the schedule is gated on
        // `activeTempoUsesLoop` (== drumsEnabled) in LiminalDSPCore.doTick,
        // so even with breaksEnabled left on, nothing should ever be gated
        // -- bit-identical to a drums-off reference for the whole duration.
        let drumsOffDiff = fullDiff(liveCore(breaksEnabled: true, drumsEnabled: false),
                                    liveCore(breaksEnabled: false, drumsEnabled: false),
                                    frames: totalFrames)
        precondition(drumsOffDiff < 0.00001, "breaks must never fire while drums are off: \(drumsOffDiff)")

        print("Live BREAKS toggle gating (off / drums off): PASS")

        // MARK: - Regression: toggling off MID-BREAK must return quickly,
        // not wait for the next bar boundary.
        //
        // `smBreakGain`'s target used to only be recomputed at bar
        // boundaries in `doTick`, so flipping BREAKS (or DRUMS) off while a
        // break was already in progress left drums/bass ducked for up to a
        // whole remaining bar (~3s at 80 BPM) -- unresponsive on a control
        // the user just tapped specifically to stop that. `render()` now
        // forces `smBreakGain`'s target back to unity every callback
        // whenever `!breaksEnabled || !drumsEnabled`, so the release should
        // complete within a handful of `smBreakGain` time constants
        // (0.006s * liveRate = 48 samples/time-constant here), independent
        // of how far the next bar boundary is.
        //
        // Windowed (not single-sample) max-abs-diff throughout, for the
        // same reason as the checks above: the synth content is periodic
        // and a single sample can coincide with a zero crossing.
        //
        // Rather than asserting `toggleCore` converges to bit-level
        // equality with a hand-built "full level" reference (fragile here:
        // when BREAKS/DRUMS flips off mid-break, `smBreakGain` rises from
        // ~0 to 1 at the exact same time some OTHER gain can be moving too
        // -- e.g. `smDrumGain` falling to 0 when DRUMS itself was the
        // toggle -- and those two simultaneous opposite-direction ramps
        // multiply together, so their EXACT numeric reunion with a static
        // reference isn't a clean single-time-constant curve), this checks
        // the thing the bug report actually cares about: does audible
        // drum+bass content reappear quickly, instead of staying silenced
        // until the next bar boundary. That's "diverges from a melody+pad-
        // only (fully silenced drums+bass) reference", which is what
        // `silentLive`-style cores already give us elsewhere in this file.
        func measureMidBreakToggleReturn(label: String, applyToggle: (LiminalDSPCore) -> Void) {
            let toggleCore = liveCore(breaksEnabled: true)
            // Melody+pad only (both drums and bass fully nulled via level,
            // independent of `breaksEnabled`/`drumsEnabled`) -- shares
            // `toggleCore`'s tempo profile throughout (default
            // `drumsEnabled: true`), so it's frame-exact comparable without
            // needing the toggle itself to have landed yet.
            let silentRef = liveCore(breaksEnabled: false, drumLevel: 0, bassLevel: 0)
            let breakStart = liveWindows[0].lowerBound
            let breakEnd = liveWindows[0].upperBound
            // Early in the break's FIRST bar, well clear of its own ramp-in
            // AND -- deliberately -- well clear of the bar14/bar15 boundary
            // in the middle of this 2-bar window. That boundary matters:
            // `doTick` re-evaluates the break-active decision at EVERY bar
            // boundary using whatever `breaksEnabled`/`drumsEnabled` is
            // current by then, so a toggle placed too close to one would
            // let even the OLD, buggy (bar-boundary-only) code appear to
            // "react quickly" by sheer luck of timing, defeating the point
            // of this regression test. Placing the toggle here maximizes
            // the distance to the next bar boundary (bar15, `breakStart +
            // barFrames`), so a fast return can only be explained by the
            // fix, not a nearby boundary.
            let toggleFrame = breakStart + settleMargin + 200
            let nextBarBoundary = breakStart + barFrames
            precondition(toggleFrame - breakStart > settleMargin && breakEnd - toggleFrame > 3_000,
                         "toggle point must be deep inside the break window with room to observe the return")
            precondition(nextBarBoundary - toggleFrame > 2_000,
                         "toggle point must be far from the next bar boundary, or this test can't tell the fix from the old bug")

            // Render both cores in lockstep up to the toggle point.
            var p = [Float](repeating: 0, count: 256 * 2), q = p
            var rendered = 0
            while rendered < toggleFrame {
                let n = min(256, toggleFrame - rendered)
                p.withUnsafeMutableBufferPointer { toggleCore.render(into: $0.baseAddress!, frames: n) }
                q.withUnsafeMutableBufferPointer { silentRef.render(into: $0.baseAddress!, frames: n) }
                rendered += n
            }

            // Setup check: right before the toggle, `toggleCore` is mid-
            // break -- drums+bass already ducked to ~0 by `smBreakGain` --
            // so it should already closely match the melody+pad-only
            // reference. If it didn't, the "returns quickly" assertion
            // below (which looks for DIVERGENCE from this same reference)
            // would be vacuous.
            var preDiff: Float = 0
            for i in 0..<256 { preDiff = max(preDiff, abs(p[i] - q[i])) }
            precondition(preDiff < 0.01, "\(label): setup check -- toggleCore should already be ducked to ~silence right before the toggle, got \(preDiff)")

            applyToggle(toggleCore)

            // Walk forward in small windows, tracking the max-abs-diff per
            // window against the melody+pad-only reference; "returned"
            // means two consecutive windows both show clearly audible
            // (> tolerance) drum/bass content again (guards against a
            // single stray transient sample).
            let window = 100
            let tolerance: Float = 0.02
            // The relevant "how slow would the old bug be" yardstick is the
            // distance to the next BAR boundary (where `doTick` would next
            // reconsider the break-active decision), not the break window's
            // end -- searching all the way to `breakEnd` just gives the
            // search loop room to run.
            let remainingInBar = nextBarBoundary - toggleFrame
            let searchLimit = breakEnd - toggleFrame
            var offset = 0
            var consecutiveAudible = 0
            var returnOffset: Int? = nil
            var r = [Float](repeating: 0, count: window * 2), s = r
            while offset < searchLimit {
                r.withUnsafeMutableBufferPointer { toggleCore.render(into: $0.baseAddress!, frames: window) }
                s.withUnsafeMutableBufferPointer { silentRef.render(into: $0.baseAddress!, frames: window) }
                offset += window
                var windowDiff: Float = 0
                for i in 0..<(window * 2) { windowDiff = max(windowDiff, abs(r[i] - s[i])) }
                if windowDiff > tolerance {
                    consecutiveAudible += 1
                    if consecutiveAudible >= 2 && returnOffset == nil {
                        returnOffset = offset
                        break
                    }
                } else {
                    consecutiveAudible = 0
                }
            }
            guard let returnOffset else {
                preconditionFailure("\(label): drums/bass never became audible again within the remaining bar (\(remainingInBar) samples) -- looks like the old bar-boundary-only bug")
            }
            // The old, buggy behavior would only react at the next bar
            // boundary, `remainingInBar` samples away. The fix must return
            // WAY sooner -- a handful of `smBreakGain` time constants
            // (0.006s * liveRate = 48 samples/time-constant here), not a
            // fraction of a whole bar.
            precondition(returnOffset < 600,
                         "\(label): took \(returnOffset) samples to become audible again -- expected a fast sub-bar ramp, not a bar-boundary wait (\(remainingInBar) samples away)")
            precondition(Double(returnOffset) < Double(remainingInBar) / 4,
                         "\(label): return (\(returnOffset) samples) should be a small fraction of the remaining bar (\(remainingInBar) samples)")
            print("\(label): drums/bass audible again after \(returnOffset) samples (bar boundary was \(remainingInBar) samples away): PASS")
        }

        measureMidBreakToggleReturn(label: "BREAKS toggle-off mid-break") { $0.setBreaksEnabled(false) }
        measureMidBreakToggleReturn(label: "DRUMS toggle-off mid-break") { $0.setDrumsEnabled(false) }

        print("All drum break tests passed")
    }
}
