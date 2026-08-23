//
//  PadVoice.swift
//  LiminalGenerator
//
//  The pad-chord layer (SPEC.md Addendum 3): a warm, FIXED-sound-design
//  voice (not user-selectable) -- 3 detuned oscillators per voice (saw +
//  triangle blend, +-5..12 cents), through the shared 24dB lowpass driven
//  by COLOR, with a slow attack (0.5-1.5s), high sustain, and a long
//  release (2-4s). `PadVoiceBank.startChord` triggers a whole chord's
//  worth of voices at once and releases whatever was sustaining from the
//  previous chord -- with a big enough voice pool (20, see `PadVoiceBank
//  .init`) the old chord's long release and the new chord's slow attack
//  naturally overlap into a click-free crossfade, no explicit fade-mixing
//  logic required.
//

import Foundation

private enum PadEnvStage {
    case idle
    case attack
    case sustain
    case release
}

struct PadVoice {
    private var stage: PadEnvStage = .idle
    private var envLevel: Float = 0
    private var attackStart: Float = 0
    private var attackTotalSamples: Int = 1
    private var attackCounter: Int = 0
    private var sustainLevel: Float = 0.85
    private var releaseCoeff: Float = 0.9998

    private var phase1: Float = 0
    private var phase2: Float = 0
    private var phase3: Float = 0
    private var freq1: Float = 0
    private var freq2: Float = 0
    private var freq3: Float = 0
    private var velocityGain: Float = 1

    // Same envelope-driven-brightness-on-top-of-COLOR's-base-cutoff design
    // as `SynthVoice`/`BassVoice`, captured once at trigger time.
    private var coeffOpen: Float = 0
    private var coeffClosed: Float = 0
    private var filter = Lowpass24dB()

    private(set) var panLeftGain: Float = 0.7071
    private(set) var panRightGain: Float = 0.7071

    var isFree: Bool { stage == .idle }
    /// True while attacking or sustaining -- i.e. this voice belongs to the
    /// currently "held" chord and should be released when the next chord
    /// swells in (see `PadVoiceBank.startChord`).
    var isSustaining: Bool { stage == .attack || stage == .sustain }
    var currentLevel: Float { envLevel }

    mutating func trigger(midiNote: Int, velocity: Float, sampleRate: Double, color: Float,
                           rng: inout XorshiftRNG) {
        let baseFreq = midiToFrequency(Float(midiNote))
        let detuneDownCents = rng.nextFloat(in: 5...12)
        let detuneUpCents = rng.nextFloat(in: 5...12)
        freq1 = Float(Double(baseFreq) * pow(2.0, -Double(detuneDownCents) / 1200.0))
        freq2 = baseFreq
        freq3 = Float(Double(baseFreq) * pow(2.0, Double(detuneUpCents) / 1200.0))

        if stage == .idle {
            phase1 = rng.nextUnit()
            phase2 = rng.nextUnit()
            phase3 = rng.nextUnit()
        }
        // A retrigger of an already-sounding voice index (e.g. voice
        // stealing under heavy overlap) keeps phase continuity -- avoids a
        // click from a fresh random phase jump on an already-live signal.

        velocityGain = clamp(velocity, 0, 1)
        sustainLevel = rng.nextFloat(in: 0.75...0.92)

        let attackMs = rng.nextFloat(in: 500...1500) // slow attack, 0.5-1.5s
        attackTotalSamples = max(1, Int(attackMs / 1000 * Float(sampleRate)))
        attackCounter = 0
        attackStart = envLevel // ramp from wherever we are -- click-free even under voice stealing
        stage = .attack

        let baseCutoff = synthColorCutoffHz(color)
        let openHz = clamp(baseCutoff * rng.nextFloat(in: 1.2...1.6), baseCutoff, 20_000)
        let closedHz = clamp(baseCutoff * rng.nextFloat(in: 0.5...0.7), 40, baseCutoff)
        coeffOpen = OnePoleLowpass.coefficient(cutoffHz: openHz, sampleRate: sampleRate)
        coeffClosed = OnePoleLowpass.coefficient(cutoffHz: closedHz, sampleRate: sampleRate)

        // Spread voices gently across the stereo field based on pitch.
        let pan = clamp((Float(midiNote % 7) / 6 - 0.5) * 0.7, -0.6, 0.6)
        let theta = (pan + 0.5) * (Float.pi / 2)
        panLeftGain = cos(theta)
        panRightGain = sin(theta)
    }

    /// Starts the long release tail (2-4s, chosen by the caller). No-op if
    /// already idle or releasing.
    mutating func release(releaseMs: Float, sampleRate: Double) {
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
            if envLevel < 0.0003 {
                envLevel = 0
                stage = .idle
                return 0
            }
        }

        phase1 += freq1 / Float(sampleRate)
        if phase1 >= 1 { phase1 -= 1 }
        phase2 += freq2 / Float(sampleRate)
        if phase2 >= 1 { phase2 -= 1 }
        phase3 += freq3 / Float(sampleRate)
        if phase3 >= 1 { phase3 -= 1 }

        // Fixed sound design (not user-selectable): saw+triangle blend.
        let osc1 = oscillatorSample(waveform: .saw, phase: phase1)
        let osc2 = oscillatorSample(waveform: .triangle, phase: phase2)
        let osc3 = oscillatorSample(waveform: .saw, phase: phase3)
        let raw = (osc1 + osc2 + osc3) * (1.0 / 3.0)

        let envNorm = sustainLevel > 0.0001 ? clamp(envLevel / sustainLevel, 0, 1) : 0
        let filterCoeff = lerp(coeffClosed, coeffOpen, envNorm)
        let filtered = filter.process(raw, coeff: filterCoeff)

        return filtered * envLevel * velocityGain
    }
}

/// Fixed-size voice pool sized generously (20, per SPEC.md Addendum 3's
/// guidance of "16-20") so that up to ~5 releasing voices from the
/// previous chord, ~5 attacking/sustaining voices for the new chord, and
/// headroom for occasional voice overlap during a fast chord cadence never
/// audibly steal from each other.
final class PadVoiceBank {
    private var voices: [PadVoice]
    private let sampleRate: Double

    init(voiceCount: Int = 20, sampleRate: Double) {
        self.sampleRate = sampleRate
        voices = (0..<voiceCount).map { _ in PadVoice() }
    }

    /// Releases every currently-sustaining voice (the previous chord) with
    /// a long, click-free release, then triggers a fresh voice per tone in
    /// the new chord. This IS the chord crossfade -- the voice-pool
    /// architecture gives it "for free" as long as the pool never has to
    /// steal an audibly-loud voice (see `pickVoiceIndex`).
    func startChord(tones: [Int], velocity: Float, color: Float, releaseMsRange: ClosedRange<Float>,
                    rng: inout XorshiftRNG) {
        for i in voices.indices where voices[i].isSustaining {
            voices[i].release(releaseMs: rng.nextFloat(in: releaseMsRange), sampleRate: sampleRate)
        }
        for tone in tones {
            let idx = pickVoiceIndex()
            voices[idx].trigger(midiNote: tone, velocity: velocity, sampleRate: sampleRate, color: color, rng: &rng)
        }
    }

    /// Picks an idle voice if one exists, otherwise steals the quietest
    /// currently-releasing voice (never a sustaining one -- those were just
    /// told to release by `startChord` above, but stealing prefers the
    /// quietest regardless of stage as a defensive fallback).
    private func pickVoiceIndex() -> Int {
        var target = 0
        var quietest: Float = .greatestFiniteMagnitude
        for i in voices.indices {
            if voices[i].isFree { return i }
            if voices[i].currentLevel < quietest {
                quietest = voices[i].currentLevel
                target = i
            }
        }
        return target
    }

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
