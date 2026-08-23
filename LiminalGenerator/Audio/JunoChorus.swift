//
//  JunoChorus.swift
//  LiminalGenerator
//
//  Stereo modulated-delay chorus modeled on the Roland Juno-106's BBD
//  ("bucket-brigade device") chorus circuit (SPEC.md Addendum 4). Applied
//  to the SYNTH LAYER ONLY (pads + melody voice, summed AFTER their own
//  per-voice filters, BEFORE the synth bus is added to bass/drums -- see
//  `LiminalDSPCore.render`). Bass and drums never pass through this at all.
//
//  Topology: two short delay lines, one per channel, each modulated by a
//  triangle LFO running in ANTIPHASE between L and R (R reads the LFO a
//  half-cycle ahead of L -- exact phase inversion for a triangle wave).
//  This antiphase relationship is what gives the Juno-106 its famously
//  wide stereo image; since this app's synth bus is already stereo (pad
//  voices are already panned), the antiphase modulation adds a further,
//  clearly measurable L/R decorrelation on top of whatever width already
//  existed -- see the DSP harness in the scratchpad for the correlation
//  numbers.
//
//  Mode-I character: LFO rate ~=0.5Hz sweeping a ~1.5-3.5ms base delay by
//  ~1.75ms peak-to-peak. A touch of a faster, mode-II-style LFO (~1.05Hz)
//  is blended in only at high `nostalgia` values, capped low so the result
//  stays lush rather than wobbly/seasick (per SPEC.md Addendum 4's quality
//  bar).
//
//  Wet/dry: the Juno's own chorus circuit runs a fixed 50/50 dry/wet blend
//  when engaged. `nostalgia` (0...1) crossfades linearly from fully dry at
//  0 to that full 50/50 blend at 1 -- never past it, since 50/50 IS "full
//  wet" for this effect.
//
//  Realtime-safe: both delay buffers are preallocated in `init`; `process`
//  performs no allocation, no locking, no Foundation/ObjC bridging in the
//  hot path -- same discipline as `WowFlutterProcessor`.
//

import Foundation

final class JunoChorus {
    private var bufferL: [Float]
    private var bufferR: [Float]
    private let bufferSize: Int
    private var writeIndexL: Int = 0
    private var writeIndexR: Int = 0

    private let sampleRate: Double

    // Mode-I LFO (~0.5Hz), the dominant/primary sweep. A single phase is
    // advanced once per sample; the R channel reads it offset by half a
    // cycle (see `process`) rather than owning a second independent phase
    // -- guarantees perfect antiphase with no drift between channels.
    private var phase1: Float = 0
    private let rate1Hz: Float = 0.5

    // Subtle faster "mode-II"-ish LFO, blended in only at high `nostalgia`
    // (see `modeIIBlend` in `process`). Also read antiphase between
    // channels via the same +0.5-cycle offset trick.
    private var phase2: Float = 0
    private let rate2Hz: Float = 1.05

    // Base delay sits in the Juno-106's ~1.5-3.5ms region; the +-0.875ms
    // sweep (1.75ms peak-to-peak) keeps the swept range (~1.625-3.375ms)
    // comfortably inside that same region at all times.
    private let baseDelayMs: Float = 2.5
    private let sweepMs: Float = 0.875

    init(sampleRate: Double, maxDelayMs: Double = 10) {
        self.sampleRate = sampleRate
        bufferSize = Int(sampleRate * maxDelayMs / 1000) + 8
        bufferL = [Float](repeating: 0, count: bufferSize)
        bufferR = [Float](repeating: 0, count: bufferSize)
    }

    /// - Parameters:
    ///   - inputL/inputR: the dry synth-bus (pads + melody) samples for
    ///     this frame, already past their own per-voice filters.
    ///   - nostalgia: 0...1, already smoothed by the caller. 0 = fully dry
    ///     (bypass), 1 = the full Juno-style 50/50 dry/wet blend.
    /// - Returns: (left, right) processed samples, same scale as the input.
    @inline(__always)
    func process(inputL: Float, inputR: Float, nostalgia: Float) -> (Float, Float) {
        bufferL[writeIndexL] = inputL
        bufferR[writeIndexR] = inputR

        phase1 += rate1Hz / Float(sampleRate)
        if phase1 >= 1 { phase1 -= 1 }
        phase2 += rate2Hz / Float(sampleRate)
        if phase2 >= 1 { phase2 -= 1 }

        // Ramps 0 below nostalgia=0.5 up to a capped 0.25 at nostalgia=1 --
        // mode-I stays the dominant character even at full wet, per the
        // "never wobbly" quality bar.
        let modeIIBlend = clamp((nostalgia - 0.5) / 0.5, 0, 1) * 0.25

        let phaseR1 = phase1 + 0.5 >= 1 ? phase1 - 0.5 : phase1 + 0.5
        let phaseR2 = phase2 + 0.5 >= 1 ? phase2 - 0.5 : phase2 + 0.5

        let modL = modulation(phaseA: phase1, phaseB: phase2, blend: modeIIBlend)
        let modR = modulation(phaseA: phaseR1, phaseB: phaseR2, blend: modeIIBlend)

        let delayMsL = baseDelayMs + sweepMs * modL
        let delayMsR = baseDelayMs + sweepMs * modR

        // Fractional-delay read, linear-interpolated (same technique as
        // `WowFlutterProcessor.process`), inlined per channel to avoid
        // passing the buffer arrays as parameters in the hot path.
        let delaySamplesL = Double(delayMsL) / 1000 * sampleRate
        let readPosL = Double(writeIndexL) - delaySamplesL
        let idx0L = Int(floor(readPosL))
        let fracL = Float(readPosL - Double(idx0L))
        let i0L = ((idx0L % bufferSize) + bufferSize) % bufferSize
        let i1L = (i0L + 1) % bufferSize
        let wetL = bufferL[i0L] + (bufferL[i1L] - bufferL[i0L]) * fracL

        let delaySamplesR = Double(delayMsR) / 1000 * sampleRate
        let readPosR = Double(writeIndexR) - delaySamplesR
        let idx0R = Int(floor(readPosR))
        let fracR = Float(readPosR - Double(idx0R))
        let i0R = ((idx0R % bufferSize) + bufferSize) % bufferSize
        let i1R = (i0R + 1) % bufferSize
        let wetR = bufferR[i0R] + (bufferR[i1R] - bufferR[i0R]) * fracR

        writeIndexL += 1
        if writeIndexL >= bufferSize { writeIndexL = 0 }
        writeIndexR += 1
        if writeIndexR >= bufferSize { writeIndexR = 0 }

        // Juno topology: full engagement is a 50/50 dry/wet blend;
        // `nostalgia` crossfades linearly from fully dry (0) up to that
        // 50/50 point (1) -- see SPEC.md Addendum 4.
        let wetAmount = 0.5 * clamp(nostalgia, 0, 1)
        let outL = inputL * (1 - wetAmount) + wetL * wetAmount
        let outR = inputR * (1 - wetAmount) + wetR * wetAmount
        return (outL, outR)
    }

    @inline(__always)
    private func modulation(phaseA: Float, phaseB: Float, blend: Float) -> Float {
        let triA = oscillatorSample(waveform: .triangle, phase: phaseA)
        let triB = oscillatorSample(waveform: .triangle, phase: phaseB)
        return triA * (1 - blend) + triB * blend
    }
}
