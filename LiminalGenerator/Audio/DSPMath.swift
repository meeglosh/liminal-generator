//
//  DSPMath.swift
//  LiminalGenerator
//
//  Small, allocation-free math helpers shared by the DSP graph. Everything
//  here is safe to call from the realtime render callback: no allocation,
//  no locking, no Foundation/ObjC bridging in the hot path.
//

import Foundation

// MARK: - Fast realtime-safe RNG

/// A tiny xorshift PRNG used for in-render-thread randomization (voice
/// detune/attack humanization, hiss noise, etc). `SystemRandomNumberGenerator`
/// is not guaranteed allocation/lock free, so it must never be called from
/// the audio render callback. `PatternGenerator` (which runs on the
/// control/main thread) uses `SystemRandomNumberGenerator`/a seedable RNG
/// instead -- this type is strictly for the realtime side.
struct XorshiftRNG {
    private var state: UInt64

    init(seed: UInt64) {
        // xorshift64 requires a non-zero seed.
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// Uniform float in [0, 1).
    mutating func nextUnit() -> Float {
        Float(nextUInt64() >> 40) * (1.0 / Float(1 << 24))
    }

    /// Uniform float in [-1, 1).
    mutating func nextBipolar() -> Float {
        nextUnit() * 2 - 1
    }

    /// Uniform float in [range.lowerBound, range.upperBound].
    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + nextUnit() * (range.upperBound - range.lowerBound)
    }
}

// MARK: - Generic helpers

@inline(__always) func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    min(max(v, lo), hi)
}

@inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}

@inline(__always) func midiToFrequency(_ note: Float) -> Float {
    440.0 * pow(2.0, (note - 69.0) / 12.0)
}

@inline(__always) func dBToLinear(_ db: Float) -> Float {
    pow(10.0, db / 20.0)
}

// MARK: - Tempo / SPEED

/// Fixed base tempo (bpm) for the shared 16th-note tick clock when drums
/// are disabled -- picked to sit at the rough center of the old randomized
/// 68...96 bpm generation range (retired; tempo no longer comes from
/// `ArpeggioPattern`). Single source of truth shared by `LiminalDSPCore`
/// (tick-clock scheduling) and `AudioEngineController` (the `effectiveBPM`
/// readout), so the two can never drift apart.
let baseMelodyBPM: Double = 82

/// SPEED (0...1) -> tempo/playback-rate multiplier, per SPEC.md: 0.70x at
/// speed=0, exactly 1.0x at the default speed=0.5, 1.30x at speed=1 -- a
/// tape-deck-style linear ramp.
@inline(__always) func speedMultiplier(_ speed: Float) -> Float {
    0.70 + clamp(speed, 0, 1) * 0.60
}

// MARK: - COLOR

/// COLOR (0...1) -> multiplier applied to the synth voice's filter
/// open/dark cutoff frequencies at note-trigger time (see `SynthVoice.trigger`):
/// 0.6x at color=0 (duller, warmer), 1.0x at the ~0.5 default (matches the
/// pre-COLOR baseline tone exactly), 1.4x at color=1 (more open/present).
/// Deliberately modest range -- plus a hard Hz clamp downstream -- so the
/// pad-pluck stays warm and never harsh even at the bright extreme.
@inline(__always) func synthColorFactor(_ color: Float) -> Float {
    0.6 + clamp(color, 0, 1) * 0.8
}

/// Cheap triangle+sine blend oscillator shape, evaluated from a 0..<1 phase.
@inline(__always) func triSine(phase: Float) -> Float {
    let sine = sin(2 * Float.pi * phase)
    // Naive (non-bandlimited) triangle -- acceptable here: the signal is
    // always low-passed downstream and sits in a low/mid register, so
    // aliasing is inaudible under the tape/lofi character.
    let triangle = 4 * abs(phase - floor(phase + 0.5)) - 1
    return 0.5 * sine + 0.5 * triangle
}

// MARK: - One-pole filters

/// One-pole lowpass. Coefficient is precomputed by the caller (avoid calling
/// `exp` every sample); `process` itself is a single multiply-add.
struct OnePoleLowpass {
    var state: Float = 0

    @inline(__always) mutating func process(_ x: Float, coeff: Float) -> Float {
        state = state + (1 - coeff) * (x - state)
        return state
    }

    static func coefficient(cutoffHz: Float, sampleRate: Double) -> Float {
        let c = exp(-2 * Float.pi * cutoffHz / Float(sampleRate))
        return clamp(c, 0, 0.9995)
    }
}

/// One-pole highpass (complement of a one-pole lowpass), used to shape hiss.
struct OnePoleHighpass {
    var lp = OnePoleLowpass()

    @inline(__always) mutating func process(_ x: Float, coeff: Float) -> Float {
        x - lp.process(x, coeff: coeff)
    }
}

// MARK: - Parameter smoothing

/// Exponential smoother for control parameters read into the render loop.
/// `setTarget` is called at most once per render() call (from the snapshot),
/// `next()` is called every sample -- both are pure arithmetic, no branches
/// that allocate or block.
struct SmoothedParam {
    private(set) var current: Float
    private var target: Float
    private let coeff: Float

    /// - Parameter timeConstant: approx time to close ~63% of the gap, in seconds.
    init(initial: Float, timeConstant: Double = 0.008, sampleRate: Double = 44_100) {
        current = initial
        target = initial
        coeff = Float(exp(-1.0 / (timeConstant * sampleRate)))
    }

    mutating func setTarget(_ v: Float) {
        target = v
    }

    @inline(__always) @discardableResult
    mutating func next() -> Float {
        current += (target - current) * (1 - coeff)
        return current
    }
}
