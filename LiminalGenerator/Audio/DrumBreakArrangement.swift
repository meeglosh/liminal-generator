import Foundation

/// Export-only arrangement. Uses the same rounded sixteenth-note duration as
/// the DSP clock, so the loop keeps running silently and returns in phase.
struct DrumBreakArrangement {
    let windows: [Range<Int64>]
    let rampFrames: Int64

    init(duration: Double, fadeIn: Double, fadeOut: Double,
         bpm: Int, speed: Float, sampleRate: Double) {
        rampFrames = max(1, Int64((sampleRate * 0.005).rounded()))
        let tickFrames = max(1, Int64(((sampleRate * 60 / (Double(max(1, bpm)) * 4))
                                      / Double(speedMultiplier(speed))).rounded()))
        let barFrames = tickFrames * 16
        let totalFrames = Int64(max(0, duration) * sampleRate)
        let firstAllowed = max(barFrames * 4, Int64(max(0, fadeIn) * sampleRate) + rampFrames)
        let lastAllowed = min(totalFrames - barFrames * 4,
                              totalFrames - Int64(max(0, fadeOut) * sampleRate) - rampFrames)
        var planned: [Range<Int64>] = []
        // Two two-bar breakdowns, roughly one-third and two-thirds through
        // the clip. Return on a four-bar phrase boundary. Short clips may
        // fit only one or none; never crowd the intro, outro or each other.
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            let phrase = Int64((Double(totalFrames) * fraction / Double(barFrames * 4)).rounded())
            let end = phrase * 4 * barFrames
            let start = end - 2 * barFrames
            guard start >= firstAllowed, end <= lastAllowed,
                  start >= (planned.last?.upperBound ?? 0) + 4 * barFrames else { continue }
            planned.append(start..<end)
        }
        windows = planned
    }

    /// Five-millisecond ramps avoid clicks without a long fade swallowing
    /// the returning downbeat. Applied to both the drum and bass buses
    /// (see `LiminalDSPCore.render`) -- melody/pads keep playing through it.
    @inline(__always)
    func gain(at frame: Int64) -> Float {
        for window in windows {
            if frame < window.lowerBound - rampFrames { return 1 }
            if frame < window.lowerBound {
                return Float(window.lowerBound - frame) / Float(rampFrames)
            }
            if frame < window.upperBound { return 0 }
            if frame < window.upperBound + rampFrames {
                return Float(frame - window.upperBound) / Float(rampFrames)
            }
        }
        return 1
    }
}

/// Live-playback counterpart to `DrumBreakArrangement`. Unlike the export
/// arrangement (planned once in sample-frame space for a fixed-duration
/// render), live playback runs indefinitely and its tempo can change at any
/// moment (SPEED slider, loop swaps) -- a frame-based plan would drift out
/// of phase. Instead this is driven entirely by the shared musical clock
/// (`LiminalDSPCore.globalTickIndex` / `ticksPerBar`, see the tick-clock
/// notes there), so it is inherently tempo-independent and deterministic:
/// a repeating 48-bar cycle with two two-bar breaks, returning on four-bar
/// phrase boundaries, at bars [14, 16) and [30, 32) of each cycle -- the
/// same one-third/two-thirds-ish placement and "a couple of times over a
/// couple of minutes" cadence as the export arrangement (at the default
/// 80 BPM loop tempo and 1.0x SPEED that's two breaks roughly every 2.4
/// minutes: 48 bars * 4 beats/bar / 80 bpm = 2.4 min per cycle).
///
/// Stateless and pure -- `LiminalDSPCore` calls `isBreakBar` once per bar
/// boundary (inside `doTick`, gated on `breaksEnabled && drumsEnabled`) and
/// feeds the 0/1 result into `smBreakGain`, a dedicated `SmoothedParam` that
/// gives the same click-free ramp character as the export's 5ms ramp
/// without stacking a second independent ramp on the signal.
enum LiveDrumBreakSchedule {
    static let cycleBars = 48
    // Bar ranges expressed as scalar bounds rather than `Range<Int>`/an
    // array of them -- `isBreakBar` runs on the render thread (from
    // `LiminalDSPCore.doTick`), and a `static let [Range<Int>]` is a
    // lazily-initialized Swift global: its FIRST access anywhere in the
    // process triggers a one-time heap allocation for the array buffer via
    // `swift_once`, which could land on the very first render callback.
    // Plain `Int` constants (like `LiminalDSPCore.ticksPerBar`) never
    // allocate, keeping this in line with the file's "allocation-free,
    // lock-free" render-thread contract; the scalar comparisons below are
    // also cheaper per-bar than `[Range<Int>].contains { $0.contains(_:) }.
    static let break1Start = 14, break1End = 16
    static let break2Start = 30, break2End = 32

    /// - Parameter barIndex: absolute bar count since `globalTickIndex == 0`
    ///   (i.e. `globalTickIndex / ticksPerBar`), monotonically increasing.
    @inline(__always)
    static func isBreakBar(_ barIndex: Int) -> Bool {
        // `%` on a negative `barIndex` (not expected in practice, since
        // `globalTickIndex` only ever counts up from 0, but kept safe/
        // symmetric with `barIndex`'s doc comment) can return a negative
        // remainder in Swift -- the extra `+ cycleBars) % cycleBars` folds
        // that back into 0..<cycleBars.
        let barInCycle = ((barIndex % cycleBars) + cycleBars) % cycleBars
        return (barInCycle >= break1Start && barInCycle < break1End)
            || (barInCycle >= break2Start && barInCycle < break2End)
    }
}
