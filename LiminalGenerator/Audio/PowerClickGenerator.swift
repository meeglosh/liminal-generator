//
//  PowerClickGenerator.swift
//  LiminalGenerator
//
//  Procedural old-CRT-television power-switch click, fired on play()/pause()
//  (see `AudioEngineController`). Lives on the SAME `AVAudioEngine` as the
//  music graph (`LiminalDSPCore` -> `AVAudioUnitReverb` -> mainMixer) as a
//  second, parallel `AVAudioSourceNode` connected directly to `mainMixer`:
//
//   - DRY: this generator's node connects straight to `mainMixerNode`, never
//     to `AVAudioUnitReverb`, so it can never pick up the reverb send, and it
//     has no knowledge of SPACE/AGE/SPEED/COLOR -- those parameters live
//     entirely inside `LiminalDSPCore`, which this type never touches. It is
//     also never routed through the wow/flutter, tape hiss, or age-lowpass
//     stages, which likewise live only inside `LiminalDSPCore.render`.
//   - Never leaks into exports: `AudioEngineController.performOfflineRender`
//     builds its own throwaway `LiminalDSPCore` + `AVAudioEngine` and never
//     references `PowerClickGenerator` at all -- there is no code path from
//     a click trigger into the offline render graph.
//   - Audible even when the music engine is about to pause: sharing the ONE
//     engine (rather than running a second, permanently-alive engine just
//     for this) means `AudioEngineController` must defer the actual
//     `engine.pause()` call until after an OFF click has finished rendering
//     -- see `AudioEngineController.pauseInternal`. This generator exposes
//     `onClickDurationSeconds`/`offClickDurationSeconds` so that deferral is
//     sized off the real synthesis constants instead of a duplicated magic
//     number.
//
//  Thread model: same lock-free snapshot pattern `LiminalDSPCore` uses (see
//  `ParameterBus.swift`) -- `trigger(_:)` (control/main thread) publishes an
//  immutable `ValueBox<PowerClickRequest>` through a `SnapshotBox`; the
//  render thread reads it at most once per callback and, if it's a new
//  reference, resets its own render-thread-only envelope state. No
//  allocation or locking anywhere reachable from `render`. `trigger(_:)`
//  itself only ever runs on the main (control) thread -- see
//  `AudioEngineController` -- so `engine.start()`/`engine.pause()` calls
//  triggered around it never happen on the audio thread either.
//

import Foundation
import AVFoundation

/// Common interface for anything `InterleavedScratch` can pull interleaved
/// stereo Float32 audio from -- implemented by `LiminalDSPCore` (the music
/// graph, see the `RenderSource` conformance below) and `PowerClickGenerator`
/// (the dry power-click bus, this file), so the scratch converter doesn't
/// need to know which one is driving it. Declared here (rather than
/// `AudioEngineController.swift`, which owns both engines) because this file
/// is included in the standalone `tests/run-drum-break-tests.py` DSP
/// harness and `AudioEngineController.swift` is not (it pulls in
/// Combine/`@MainActor`/`ObservableObject` the headless harness doesn't
/// need) -- both `LiminalDSPCore` and `PowerClickGenerator` must be able to
/// conform wherever the harness compiles them together.
protocol RenderSource: AnyObject {
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int)
}

extension LiminalDSPCore: RenderSource {}

/// Preallocated interleaved-stereo scratch buffer bridging a `RenderSource`
/// (which renders interleaved Float32, per its pinned entry point) to
/// AVAudioEngine's non-interleaved node format. Allocated once; the
/// render/deinterleave path performs no allocation.
final class InterleavedScratch: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Float>
    private let capacityFrames: Int

    init(capacityFrames: Int) {
        self.capacityFrames = capacityFrames
        buffer = .allocate(capacity: capacityFrames * 2)
        buffer.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit {
        buffer.deallocate()
    }

    func renderAndDeinterleave(source: RenderSource, frameCount: Int, into abl: UnsafeMutableAudioBufferListPointer) {
        let frames = min(frameCount, capacityFrames)
        source.render(into: buffer, frames: frames)
        guard abl.count >= 2, let leftRaw = abl[0].mData, let rightRaw = abl[1].mData else { return }
        let left = leftRaw.assumingMemoryBound(to: Float.self)
        let right = rightRaw.assumingMemoryBound(to: Float.self)
        for i in 0..<frames {
            left[i] = buffer[i * 2]
            right[i] = buffer[i * 2 + 1]
        }
    }
}

/// Which switch action is being sounded.
enum PowerClickKind: Sendable {
    case on
    case off
}

/// One publish = one click. `generation` guarantees the render thread can
/// tell two consecutive triggers of the SAME kind apart (`ValueBox` change
/// detection in `render` is by reference identity, not value equality, so
/// two `.off` triggers in a row would otherwise look like "nothing changed").
private struct PowerClickRequest: Sendable {
    let kind: PowerClickKind
    let generation: UInt64
}

/// Renders a short, dry, procedural CRT power-switch click: a sharp
/// broadband mechanical transient with a low-mid "body" on both ON and OFF,
/// plus a brief electrostatic "energize" bloom on ON only. OFF's body decays
/// faster and has no bloom, so it reads as shorter and deader -- the way a
/// real set's degauss/flyback charge-up sound (only present when switching
/// ON) makes power-on and power-off audibly distinct.
final class PowerClickGenerator: @unchecked Sendable, RenderSource {
    private let sampleRate: Double
    private let requestBox: SnapshotBox<ValueBox<PowerClickRequest>>

    // Control-thread-only.
    private var nextGeneration: UInt64 = 0

    // Render-thread-only sequencing state.
    private var lastSeenRequest: ValueBox<PowerClickRequest>?
    private var rng = XorshiftRNG(seed: 0xC71C_1357_ABCD_EF01)
    private var activeKind: PowerClickKind?
    private var sampleIndex: Int = 0
    private var totalSamples: Int = 0

    // Render-thread-only envelope state -- recursive multiplicative decay
    // (a running value multiplied by a precomputed per-sample coefficient),
    // the same "compute the coefficient occasionally, apply it every sample"
    // shape as `SmoothedParam`/`OnePoleLowpass` elsewhere in this target,
    // rather than calling `exp()` per sample.
    private var snapEnv: Float = 0
    private var bodyEnv: Float = 0
    private var bloomEnv: Float = 0

    // Render-thread-only filter state, reused across triggers and reset
    // (not reallocated -- these are plain structs) whenever a new click
    // starts, so no per-trigger allocation.
    private var bodyLP = Lowpass24dB()
    private var energizeHP = OnePoleHighpass()
    private var energizeLP = OnePoleLowpass()

    // Fixed, precomputed-once coefficients/sample counts (sampleRate is
    // constant for the lifetime of this instance, so none of this needs to
    // be recomputed per trigger or per sample).
    private let snapDecayCoeff: Float     // ~1.2ms broadband snap decay
    private let bodyDecayCoeffOn: Float   // ~10ms low-mid body decay (ON)
    private let bodyDecayCoeffOff: Float  // ~4ms low-mid body decay (OFF, deader)
    private let bodyLPCoeff: Float        // ~400Hz body lowpass
    private let bloomStartSample: Int     // energize bloom onset (ON only)
    private let bloomAttackSamples: Int   // energize bloom attack length
    private let bloomDecayCoeff: Float    // energize bloom decay
    private let energizeHPCoeff: Float    // ~2.2kHz highpass (strips the body's low end)
    private let energizeLPCoeff: Float    // ~6.5kHz lowpass (tames raw noise to a shimmer)

    /// Total duration of each click kind, in samples. Both are tens of
    /// milliseconds by design -- a UI click, not a sound effect (SPEC
    /// product ask: "restraint matters more than realism here").
    private let onDurationSamples: Int
    private let offDurationSamples: Int

    /// Exposed so `AudioEngineController` can size how long it keeps the
    /// shared engine alive after an OFF-click trigger before actually
    /// calling `engine.pause()` -- see the architecture note atop this file.
    var onClickDurationSeconds: Double { Double(onDurationSamples) / sampleRate }
    var offClickDurationSeconds: Double { Double(offDurationSamples) / sampleRate }

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        requestBox = SnapshotBox(ValueBox(PowerClickRequest(kind: .off, generation: 0)))

        func decayCoeff(tau: Double) -> Float {
            Float(exp(-1.0 / (tau * sampleRate)))
        }

        snapDecayCoeff = decayCoeff(tau: 0.0012)
        bodyDecayCoeffOn = decayCoeff(tau: 0.010)
        bodyDecayCoeffOff = decayCoeff(tau: 0.004)
        bodyLPCoeff = OnePoleLowpass.coefficient(cutoffHz: 400, sampleRate: sampleRate)

        bloomStartSample = Int(sampleRate * 0.006)
        bloomAttackSamples = max(1, Int(sampleRate * 0.004))
        bloomDecayCoeff = decayCoeff(tau: 0.010)
        energizeHPCoeff = OnePoleLowpass.coefficient(cutoffHz: 2_200, sampleRate: sampleRate)
        energizeLPCoeff = OnePoleLowpass.coefficient(cutoffHz: 6_500, sampleRate: sampleRate)

        onDurationSamples = Int(sampleRate * 0.065)   // ~65ms: transient + body + energize bloom
        offDurationSamples = Int(sampleRate * 0.022)  // ~22ms: transient + shorter, deader body only
    }

    // MARK: Control thread

    /// Queues a click. Safe to call from the main thread only.
    func trigger(_ kind: PowerClickKind) {
        nextGeneration += 1
        requestBox.publish(ValueBox(PowerClickRequest(kind: kind, generation: nextGeneration)))
    }

    // MARK: Render thread

    /// Renders `frames` of interleaved stereo Float32 into `buffer`
    /// (mono click, duplicated to both channels), overwriting it with
    /// silence outside an active click. No allocation, no locking -- safe
    /// to call from an audio render callback.
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        let ref = requestBox.read()
        if ref !== lastSeenRequest {
            lastSeenRequest = ref
            let kind = ref.value.kind
            activeKind = kind
            sampleIndex = 0
            totalSamples = kind == .on ? onDurationSamples : offDurationSamples
            snapEnv = 1
            bodyEnv = 1
            bloomEnv = 0
            bodyLP = Lowpass24dB()
            energizeHP = OnePoleHighpass()
            energizeLP = OnePoleLowpass()
        }

        for i in 0..<frames {
            var sample: Float = 0
            if let kind = activeKind, sampleIndex < totalSamples {
                sample = renderSample(kind: kind, t: sampleIndex)
                sampleIndex += 1
                if sampleIndex >= totalSamples { activeKind = nil }
            }
            buffer[i * 2] = sample
            buffer[i * 2 + 1] = sample
        }
    }

    /// One sample of the active click at sample offset `t`.
    private func renderSample(kind: PowerClickKind, t: Int) -> Float {
        // Sharp broadband transient -- the mechanical "snap" shared by both
        // kinds: raw noise decaying very fast, giving the click its
        // percussive edge before the low-mid body takes over.
        let snapNoise = rng.nextBipolar()
        var out = snapNoise * snapEnv * 0.9
        snapEnv *= snapDecayCoeff

        // Low-mid mechanical "body" (a real switch's plastic/metal thunk):
        // a separate noise tap run through a ~400Hz lowpass so it reads as
        // a body rather than hiss. Decays noticeably faster on OFF than ON
        // -- the "shorter, deader decay" the product ask calls for.
        let bodyNoise = rng.nextBipolar()
        let bodyFiltered = bodyLP.process(bodyNoise, coeff: bodyLPCoeff)
        out += bodyFiltered * bodyEnv * 0.75
        bodyEnv *= (kind == .on ? bodyDecayCoeffOn : bodyDecayCoeffOff)

        if kind == .on {
            // Brief electrostatic "energize" bloom, ON only: a quiet,
            // brighter noise swell that rises in just as the snap/body die
            // away and fades out over the rest of the click -- the CRT's
            // flyback/degauss character. Absent on power-OFF by design,
            // which is a big part of what makes ON/OFF distinguishable.
            if t >= bloomStartSample && t < bloomStartSample + bloomAttackSamples {
                bloomEnv = Float(t - bloomStartSample) / Float(bloomAttackSamples)
            } else if t >= bloomStartSample + bloomAttackSamples {
                bloomEnv *= bloomDecayCoeff
            }
            let bloomNoise = rng.nextBipolar()
            let shaped = energizeLP.process(energizeHP.process(bloomNoise, coeff: energizeHPCoeff),
                                             coeff: energizeLPCoeff)
            out += shaped * bloomEnv * 0.22
        }

        // Local soft-clip safety stage (this bus never reaches
        // `LiminalDSPCore`'s own tanh() stage -- it is summed at the mixer
        // via its own parallel node, see `AudioEngineController.setupEngineGraph`),
        // same "gentle tape-style saturation instead of hard digital
        // clipping" rationale as there.
        return tanh(out)
    }
}
