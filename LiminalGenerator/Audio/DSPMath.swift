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

/// COLOR (0...1) -> the BASE cutoff frequency (Hz) of a real 24dB/octave
/// lowpass (see `Lowpass24dB` below), logarithmically mapped so the whole
/// slider sweeps the full audible range dramatically:
/// color=0 -> ~70Hz (near-total closure, a muffled rumble), color=1 ->
/// ~19kHz (effectively open/unfiltered). Shared by the melody synth
/// (`SynthVoice`) and the bassline voice (`BassVoice`), each with its own
/// independent filter instance and own COLOR value (`color`/`bassColor`).
/// The per-note envelope-driven brightness contour (see `SynthVoice.trigger`)
/// is layered ON TOP of this base cutoff, not a replacement for it.
@inline(__always) func synthColorCutoffHz(_ color: Float) -> Float {
    let c = clamp(color, 0, 1)
    let minHz: Float = 70
    let maxHz: Float = 19_000
    return minHz * pow(maxHz / minHz, c)
}

/// Melody-only oscillator waveform, user-selectable via
/// `AudioEngineController.waveform` (default `.triangle`). Never applied to
/// the bassline or drums -- see SPEC.md addendum 2.
enum LiminalWaveform: String, CaseIterable, Sendable {
    case sine, triangle, square, saw
}

/// Evaluates one sample of the selected waveform from a 0..<1 phase.
/// `square`/`saw` are deliberately naive (non-band-limited) per SPEC.md --
/// the downstream 24dB lowpass and age/wow-flutter processing tame most
/// aliasing harshness, acceptable for this app's lo-fi aesthetic.
@inline(__always) func oscillatorSample(waveform: LiminalWaveform, phase: Float) -> Float {
    switch waveform {
    case .sine:
        return sin(2 * Float.pi * phase)
    case .triangle:
        // Naive (non-bandlimited) triangle -- acceptable here: the signal is
        // always low-passed downstream and sits in a low/mid register, so
        // aliasing is inaudible under the tape/lofi character.
        return 4 * abs(phase - floor(phase + 0.5)) - 1
    case .square:
        // Naive square: sign of sin(2*pi*phase), i.e. high for the first
        // half of the cycle, low for the second.
        return phase < 0.5 ? 1 : -1
    case .saw:
        // Naive ramp: 2*phase - 1 (phase is already wrapped to [0, 1)).
        return 2 * (phase - floor(phase)) - 1
    }
}

/// Shared -inf...+6dB level-to-linear-gain curve used by every "LEVEL"
/// slider in the mix (drumLevel, bassLevel): 0 -> silence, 1 -> +6dB.
@inline(__always) func levelToGainLinear(_ level: Float) -> Float {
    guard level > 0.001 else { return 0 }
    let db = lerp(-40, 6, clamp(level, 0, 1))
    return dBToLinear(db)
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

/// Real 24dB/octave (4th-order) lowpass: 4 cascaded one-pole stages run at
/// the SAME coefficient. Cheap (4 multiply-adds/sample, no transcendental
/// calls in the hot path -- the coefficient is precomputed by the caller
/// exactly like `OnePoleLowpass`), stable for any coefficient in [0, 1),
/// and gives a genuinely steep, dramatic rolloff -- unlike the single
/// one-pole stage (6dB/octave) this replaces for COLOR. Used independently
/// by the melody synth (`SynthVoice`) and the bassline voice (`BassVoice`).
struct Lowpass24dB {
    private var s1 = OnePoleLowpass()
    private var s2 = OnePoleLowpass()
    private var s3 = OnePoleLowpass()
    private var s4 = OnePoleLowpass()

    @inline(__always) mutating func process(_ x: Float, coeff: Float) -> Float {
        let a = s1.process(x, coeff: coeff)
        let b = s2.process(a, coeff: coeff)
        let c = s3.process(b, coeff: coeff)
        return s4.process(c, coeff: coeff)
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
