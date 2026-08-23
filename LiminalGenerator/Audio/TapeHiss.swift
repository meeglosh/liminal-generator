//
//  TapeHiss.swift
//  LiminalGenerator
//
//  Filtered-noise tape hiss, level driven by `age`. Also hosts the gentle
//  age-driven lowpass applied to the whole mix bus (both described in the
//  spec as part of the "age" character alongside wow/flutter).
//

import Foundation

final class TapeHiss {
    private var rng: XorshiftRNG
    private var lp1 = OnePoleLowpass()
    private var hp = OnePoleHighpass()
    private let lp1Coeff: Float
    private let hpCoeff: Float

    init(sampleRate: Double, seed: UInt64) {
        rng = XorshiftRNG(seed: seed)
        lp1Coeff = OnePoleLowpass.coefficient(cutoffHz: 8500, sampleRate: sampleRate)
        hpCoeff = OnePoleLowpass.coefficient(cutoffHz: 1800, sampleRate: sampleRate)
    }

    /// - Parameter level: 0...1 (age-driven hiss amount).
    @inline(__always)
    func next(level: Float) -> Float {
        guard level > 0.001 else { return 0 }
        let n = rng.nextBipolar()
        let shaped = hp.process(lp1.process(n, coeff: lp1Coeff), coeff: hpCoeff)
        return shaped * level * 0.035
    }
}

/// Gentle age-driven lowpass over the whole mix. Coefficient is recomputed
/// at most once per render() call (buffer-rate, not sample-rate) from a
/// smoothed `age` snapshot -- inaudibly coarse and avoids an `exp()` call
/// every sample.
struct AgeLowpass {
    var filter = OnePoleLowpass()

    static func coefficient(age: Float, sampleRate: Double) -> Float {
        let cutoff = lerp(18_000, 5_500, clamp(age, 0, 1))
        return OnePoleLowpass.coefficient(cutoffHz: cutoff, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func process(_ x: Float, coeff: Float) -> Float {
        filter.process(x, coeff: coeff)
    }
}
