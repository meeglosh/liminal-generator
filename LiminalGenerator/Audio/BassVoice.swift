//
//  BassVoice.swift
//  LiminalGenerator
//
//  Monophonic bassline voice: a lightly detuned pair of oscillators fixed
//  to a warm waveform (triangle -- NOT the user-selectable `LiminalWaveform`,
//  per SPEC.md addendum 2), its OWN independent 24dB/octave lowpass driven
//  by `bassColor` (same log-mapping design as the melody's COLOR, see
//  `synthColorCutoffHz` in DSPMath.swift), and a proper attack/SUSTAIN/
//  release envelope (unlike `SynthVoice`'s attack/release-only pluck) so
//  `BasslinePattern`'s held/tied ".hold" steps genuinely sustain the note
//  rather than re-triggering or falling silent.
//
//  Note lifecycle, driven by `LiminalDSPCore`'s `BassSequencer`:
//    - `.note(role)` step -> `noteOn` (retriggers even mid-sustain; the
//      attack ramps from the CURRENT envelope level rather than 0, so a
//      back-to-back retrigger with no intervening rest is click-free).
//    - `.hold` step -> nothing is called; the voice keeps sustaining.
//    - `.rest` step -> `noteOff`, which starts the release tail.
//

import Foundation

private enum BassEnvStage {
    case idle
    case attack
    case sustain
    case release
}

struct BassVoice {
    private var stage: BassEnvStage = .idle
    private var envLevel: Float = 0
    private var attackStart: Float = 0
    private var attackTotalSamples: Int = 1
    private var attackCounter: Int = 0
    private var sustainLevel: Float = 0.9
    private var releaseCoeff: Float = 0.999

    private var phase1: Float = 0
    private var phase2: Float = 0
    private var freq1: Float = 0
    private var freq2: Float = 0
    private var velocityGain: Float = 1

    // Envelope-driven brightness (same design as `SynthVoice`), layered on
    // top of `bassColor`'s base cutoff.
    private var coeffOpen: Float = 0
    private var coeffClosed: Float = 0
    private var filter = Lowpass24dB()

    var isIdle: Bool { stage == .idle }

    /// - Parameters:
    ///   - color: 0...1, the current `bassColor` value (already smoothed by
    ///     the caller at buffer-rate, matching how `SynthVoice.trigger`
    ///     consumes melody COLOR).
    mutating func noteOn(midiNote: Int,
                          velocity: Float,
                          sampleRate: Double,
                          color: Float,
                          rng: inout XorshiftRNG) {
        let baseFreq = midiToFrequency(Float(midiNote))
        // Subtler detune than the melody voice -- bass wants to stay solid
        // and centered, just a touch of warmth/width.
        let detuneCents = rng.nextFloat(in: 2...5)
        let ratio = pow(2.0, detuneCents / 1200.0)
        freq1 = Float(baseFreq / ratio)
        freq2 = Float(baseFreq * ratio)
        if stage == .idle {
            // Fresh note: random phase avoids any phase-alignment artifacts.
            phase1 = rng.nextUnit()
            phase2 = rng.nextUnit()
        }
        // A retrigger while still sounding (no intervening rest) keeps
        // phase continuity -- avoids a click from a fresh random phase jump
        // on an already-live signal path.

        velocityGain = clamp(velocity, 0, 1)
        sustainLevel = rng.nextFloat(in: 0.8...0.95)

        let attackMs = rng.nextFloat(in: 15...45)
        attackTotalSamples = max(1, Int(attackMs / 1000 * Float(sampleRate)))
        attackCounter = 0
        attackStart = envLevel // ramp from wherever we are -- click-free retrigger
        stage = .attack

        let baseCutoff = synthColorCutoffHz(color)
        let openHz = clamp(baseCutoff * rng.nextFloat(in: 1.3...1.8), baseCutoff, 20_000)
        let closedHz = clamp(baseCutoff * rng.nextFloat(in: 0.45...0.65), 40, baseCutoff)
        coeffOpen = OnePoleLowpass.coefficient(cutoffHz: openHz, sampleRate: sampleRate)
        coeffClosed = OnePoleLowpass.coefficient(cutoffHz: closedHz, sampleRate: sampleRate)
    }

    /// Starts the release tail (e.g. a `.rest` step in the bassline
    /// pattern). No-op if already idle or releasing.
    mutating func noteOff(releaseMs: Float, sampleRate: Double) {
        guard stage == .attack || stage == .sustain else { return }
        releaseCoeff = pow(0.0001, 1.0 / Float(max(1, Int(releaseMs / 1000 * Float(sampleRate)))))
        stage = .release
    }

    @inline(__always)
    mutating func nextSample(sampleRate: Double) -> Float {
        switch stage {
        case .idle:
            return 0
        case .attack:
            attackCounter += 1
            let t = min(Float(attackCounter) / Float(attackTotalSamples), 1)
            envLevel = lerp(attackStart, sustainLevel, t)
            if attackCounter >= attackTotalSamples {
                stage = .sustain
                envLevel = sustainLevel
            }
        case .sustain:
            envLevel = sustainLevel
        case .release:
            envLevel *= releaseCoeff
            if envLevel < 0.0005 {
                envLevel = 0
                stage = .idle
                return 0
            }
        }

        phase1 += freq1 / Float(sampleRate)
        if phase1 >= 1 { phase1 -= 1 }
        phase2 += freq2 / Float(sampleRate)
        if phase2 >= 1 { phase2 -= 1 }

        // Fixed warm waveform -- never the user-selectable melody waveform.
        let osc1 = oscillatorSample(waveform: .triangle, phase: phase1)
        let osc2 = oscillatorSample(waveform: .triangle, phase: phase2)
        let raw = (osc1 + osc2) * 0.5

        let envNorm = sustainLevel > 0.0001 ? clamp(envLevel / sustainLevel, 0, 1) : 0
        let filterCoeff = lerp(coeffClosed, coeffOpen, envNorm)
        let filtered = filter.process(raw, coeff: filterCoeff)

        return filtered * envLevel * velocityGain
    }
}
