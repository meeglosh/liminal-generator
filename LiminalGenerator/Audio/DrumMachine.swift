//
//  DrumMachine.swift
//  LiminalGenerator
//
//  808-style synthesized drums: sine kick with an exponential pitch+amp
//  envelope, noise+tone snare, filtered-noise closed hat. A shared lo-fi
//  stage (mild bit reduction + lowpass) sits on the summed drum bus.
//  Step scheduling (swing, pattern hot-swap) lives here; sample-accurate
//  ticking is driven from `LiminalDSPCore`'s shared 16th-note grid.
//

import Foundation

private struct KickVoice {
    var active = false
    var ageSamples: Int = 0
    var velocity: Float = 0

    mutating func trigger(velocity: Float) {
        active = true
        ageSamples = 0
        self.velocity = velocity
    }

    private var phase: Float = 0

    mutating func next(sampleRate: Double, decayScale: Float) -> Float {
        guard active else { return 0 }
        let t = Float(ageSamples) / Float(sampleRate)
        let startFreq: Float = 155, endFreq: Float = 46, pitchDecay: Float = 0.055
        let freq = endFreq + (startFreq - endFreq) * exp(-t / pitchDecay)
        phase += freq / Float(sampleRate)
        if phase >= 1 { phase -= 1 }
        let ampDecay: Float = 0.32 * decayScale
        let amp = exp(-t / ampDecay)
        ageSamples += 1
        if amp < 0.0015 { active = false; return 0 }
        return sin(2 * Float.pi * phase) * amp * velocity
    }
}

private struct SnareVoice {
    var active = false
    var ageSamples: Int = 0
    var velocity: Float = 0
    private var tonePhase: Float = 0
    private var rng = XorshiftRNG(seed: 0xA53F_C001)

    mutating func trigger(velocity: Float) {
        active = true
        ageSamples = 0
        self.velocity = velocity
    }

    mutating func next(sampleRate: Double, decayScale: Float) -> Float {
        guard active else { return 0 }
        let t = Float(ageSamples) / Float(sampleRate)
        let decay: Float = 0.16 * decayScale
        let amp = exp(-t / decay)
        tonePhase += 195.0 / Float(sampleRate)
        if tonePhase >= 1 { tonePhase -= 1 }
        let tone = sin(2 * Float.pi * tonePhase)
        let noise = rng.nextBipolar()
        ageSamples += 1
        if amp < 0.0015 { active = false; return 0 }
        return (noise * 0.72 + tone * 0.28) * amp * velocity
    }
}

private struct HatVoice {
    var active = false
    var ageSamples: Int = 0
    var velocity: Float = 0
    private var rng = XorshiftRNG(seed: 0x0FF1_CE42)
    private var hp = OnePoleHighpass()

    mutating func trigger(velocity: Float) {
        active = true
        ageSamples = 0
        self.velocity = velocity
    }

    mutating func next(sampleRate: Double) -> Float {
        guard active else { return 0 }
        let t = Float(ageSamples) / Float(sampleRate)
        let amp = exp(-t / 0.055)
        let noise = rng.nextBipolar()
        let coeff = OnePoleLowpass.coefficient(cutoffHz: 3500, sampleRate: sampleRate)
        let shaped = hp.process(noise, coeff: coeff)
        ageSamples += 1
        if amp < 0.0015 { active = false; return 0 }
        return shaped * amp * velocity * 0.9
    }
}

final class DrumMachine {
    private(set) var activePattern: DrumPattern
    private var pendingPattern: DrumPattern?
    private var stepIndex: Int = 0

    private var kick = KickVoice()
    private var snare = SnareVoice()
    private var hat = HatVoice()

    // Lo-fi character on the summed drum bus.
    private var lofiFilter = OnePoleLowpass()
    private let lofiCoeff: Float
    private let bitLevels: Float = 40 // mild bit-reduction (quantization steps)

    init(initialPattern: DrumPattern, sampleRate: Double) {
        activePattern = initialPattern
        lofiCoeff = OnePoleLowpass.coefficient(cutoffHz: 6800, sampleRate: sampleRate)
    }

    func queuePatternSwap(_ pattern: DrumPattern) {
        pendingPattern = pattern
    }

    var swing: Float { activePattern.swing }

    /// Called once per global 16th-note tick (drums always run on the full
    /// 16-step grid). Triggers any voices active on this step.
    func advanceTick() {
        if let pending = pendingPattern {
            activePattern = pending
            pendingPattern = nil
            stepIndex = 0
        }
        guard !activePattern.steps.isEmpty else { return }
        let step = activePattern.steps[stepIndex % activePattern.steps.count]
        stepIndex += 1

        if let v = step.kick { kick.trigger(velocity: v) }
        if let v = step.snare { snare.trigger(velocity: v) }
        if let v = step.hat { hat.trigger(velocity: v) }
    }

    /// Renders one sample of the (mono) drum bus with lo-fi character
    /// applied, scaled by `gain` (already includes the drumsEnabled gate
    /// and drumLevel dB mapping, smoothed upstream).
    @inline(__always)
    func nextSample(sampleRate: Double, gain: Float, decayScale: Float) -> Float {
        let k = kick.next(sampleRate: sampleRate, decayScale: decayScale)
        let s = snare.next(sampleRate: sampleRate, decayScale: decayScale)
        let h = hat.next(sampleRate: sampleRate)
        var mixed = (k * 1.0 + s * 0.85 + h * 0.55)

        // Mild bit reduction (quantize), then a gentle lowpass -- lo-fi 808 character.
        mixed = round(mixed * bitLevels) / bitLevels
        mixed = lofiFilter.process(mixed, coeff: lofiCoeff)

        return mixed * gain
    }
}
