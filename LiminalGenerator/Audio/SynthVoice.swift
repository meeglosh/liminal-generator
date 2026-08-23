//
//  SynthVoice.swift
//  LiminalGenerator
//
//  Polyphonic pad-pluck synth: 2 detuned oscillators (triangle+sine blend)
//  per voice, a one-pole lowpass whose brightness follows the amplitude
//  envelope, slow attack / long release. All state is plain structs/arrays
//  owned by `SynthVoiceBank` -- no allocation after `init`.
//
//  COLOR (synth-only, never applied to the drum loop bus) is layered on
//  top of that envelope-driven brightness contour as a trigger-time bias
//  on the open/dark cutoff endpoints -- see `synthColorFactor` (DSPMath.swift)
//  and the comment in `SynthVoice.trigger`.
//

import Foundation

private enum EnvStage {
    case idle
    case attack
    case release
}

struct SynthVoice {
    private var stage: EnvStage = .idle
    private var envLevel: Float = 0
    private var attackStart: Float = 0
    private var attackTotalSamples: Int = 1
    private var attackCounter: Int = 0
    private var releaseCoeff: Float = 0.999

    private var phase1: Float = 0
    private var phase2: Float = 0
    private var freq1: Float = 0
    private var freq2: Float = 0
    private var velocityGain: Float = 1

    // Filter "envelope" approximated as a coefficient blend (no per-sample
    // exp() calls): bright at attack peak, darker as the note releases.
    private var coeffOpen: Float = 0
    private var coeffClosed: Float = 0
    private var filter = OnePoleLowpass()

    // Simple deterministic-ish equal-power pan derived from the note at
    // trigger time; gains are precomputed once (not per sample).
    private(set) var panLeftGain: Float = 0.7071
    private(set) var panRightGain: Float = 0.7071

    var isFree: Bool { stage == .idle }

    /// Current envelope level, used by the voice bank for voice-stealing
    /// (steal the quietest currently-releasing voice).
    var currentLevel: Float { envLevel }

    mutating func trigger(midiNote: Int,
                           velocity: Float,
                           sampleRate: Double,
                           attackRange: ClosedRange<Float>,
                           releaseRange: ClosedRange<Float>,
                           releaseScale: Float,
                           colorFactor: Float,
                           rng: inout XorshiftRNG) {
        let baseFreq = midiToFrequency(Float(midiNote))
        let detuneCents = rng.nextFloat(in: 4...11)
        let ratio = pow(2.0, detuneCents / 1200.0)
        freq1 = Float(baseFreq / ratio)
        freq2 = Float(baseFreq * ratio)
        // Keep phase continuity off (new note = new phase) to avoid clicks
        // from stolen voices carrying stale phase into an unrelated pitch.
        phase1 = rng.nextUnit()
        phase2 = rng.nextUnit()

        velocityGain = clamp(velocity, 0, 1)

        let attackMs = rng.nextFloat(in: attackRange)
        let releaseMs = rng.nextFloat(in: releaseRange) * releaseScale
        attackTotalSamples = max(1, Int(attackMs / 1000 * Float(sampleRate)))
        attackCounter = 0
        attackStart = envLevel // ramp from wherever we are (smooth voice steal)
        releaseCoeff = pow(0.0001, 1.0 / Float(max(1, Int(releaseMs / 1000 * Float(sampleRate)))))
        stage = .attack

        // COLOR is layered here, ADDITIVELY on top of the existing
        // envelope-driven brightness contour: it biases the note's own
        // open/dark cutoff endpoints (via `colorFactor`, see
        // `synthColorFactor`), captured once at trigger time -- the
        // envelope (attack->release, `filterCoeff = lerp(coeffClosed,
        // coeffOpen, envLevel)` in `nextSample`) still sweeps between them
        // exactly as before. Applying at trigger time (rather than
        // continuously per-sample) is inherently click-free: it only ever
        // affects notes that haven't started yet, never an
        // already-sounding voice. Hard-clamped so even color=1 stays warm.
        let brightHz = clamp(rng.nextFloat(in: 2200...3600) * colorFactor, 150, 7_000)
        let darkHz = clamp(rng.nextFloat(in: 500...900) * colorFactor, 80, 4_000)
        coeffOpen = OnePoleLowpass.coefficient(cutoffHz: brightHz, sampleRate: sampleRate)
        coeffClosed = OnePoleLowpass.coefficient(cutoffHz: darkHz, sampleRate: sampleRate)

        // Spread voices gently across the stereo field based on pitch.
        let pan = clamp((Float(midiNote % 7) / 6 - 0.5) * 0.6, -0.5, 0.5)
        let theta = (pan + 0.5) * (Float.pi / 2) // 0...pi/2
        panLeftGain = cos(theta)
        panRightGain = sin(theta)
    }

    @inline(__always)
    mutating func nextSample(sampleRate: Double) -> Float {
        guard stage != .idle else { return 0 }

        switch stage {
        case .attack:
            attackCounter += 1
            let t = Float(attackCounter) / Float(attackTotalSamples)
            envLevel = lerp(attackStart, 1.0, min(t, 1))
            if attackCounter >= attackTotalSamples {
                stage = .release
            }
        case .release:
            envLevel *= releaseCoeff
            if envLevel < 0.0005 {
                envLevel = 0
                stage = .idle
                return 0
            }
        case .idle:
            return 0
        }

        phase1 += freq1 / Float(sampleRate)
        if phase1 >= 1 { phase1 -= 1 }
        phase2 += freq2 / Float(sampleRate)
        if phase2 >= 1 { phase2 -= 1 }

        let osc1 = triSine(phase: phase1)
        let osc2 = triSine(phase: phase2)
        let raw = (osc1 + osc2) * 0.5

        let filterCoeff = lerp(coeffClosed, coeffOpen, envLevel)
        let filtered = filter.process(raw, coeff: filterCoeff)

        return filtered * envLevel * velocityGain
    }
}

/// Fixed-size voice pool. `noteOn` steals the quietest releasing voice if
/// none are idle -- with >=8 voices for a mostly-monophonic arpeggio with
/// long releases this only happens under heavy overlap.
final class SynthVoiceBank {
    private var voices: [SynthVoice]
    private let sampleRate: Double

    init(voiceCount: Int = 10, sampleRate: Double) {
        self.sampleRate = sampleRate
        voices = (0..<voiceCount).map { _ in SynthVoice() }
    }

    func noteOn(midiNote: Int,
                velocity: Float,
                attackRange: ClosedRange<Float>,
                releaseRange: ClosedRange<Float>,
                releaseScale: Float,
                colorFactor: Float,
                rng: inout XorshiftRNG) {
        var targetIndex = 0
        var quietestLevel: Float = .greatestFiniteMagnitude
        var foundIdle = false

        for i in voices.indices {
            if voices[i].isFree {
                targetIndex = i
                foundIdle = true
                break
            }
            if voices[i].currentLevel < quietestLevel {
                quietestLevel = voices[i].currentLevel
                targetIndex = i
            }
        }
        _ = foundIdle

        voices[targetIndex].trigger(midiNote: midiNote,
                                     velocity: velocity,
                                     sampleRate: sampleRate,
                                     attackRange: attackRange,
                                     releaseRange: releaseRange,
                                     releaseScale: releaseScale,
                                     colorFactor: colorFactor,
                                     rng: &rng)
    }

    /// Renders one sample frame, returning an equal-power-panned stereo pair.
    @inline(__always)
    func nextSample() -> (left: Float, right: Float) {
        var left: Float = 0
        var right: Float = 0
        for i in voices.indices {
            let s = voices[i].nextSample(sampleRate: sampleRate)
            if s == 0 { continue }
            left += s * voices[i].panLeftGain
            right += s * voices[i].panRightGain
        }
        return (left, right)
    }
}
