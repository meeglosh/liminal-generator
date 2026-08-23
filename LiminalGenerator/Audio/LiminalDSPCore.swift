//
//  LiminalDSPCore.swift
//  LiminalGenerator
//
//  Owns the whole DSP graph and exposes a single realtime entry point,
//  `render(into:frames:)`, shared verbatim between the live AVAudioEngine
//  graph and offline rendering. Everything reachable from `render` is
//  allocation-free, lock-free, and Timer-free -- the step sequencer is
//  clocked sample-accurately inside the render loop itself.
//
//  Thread model: parameters and patterns are set from the control (main)
//  thread via `setSpace`/`setPattern`/etc, which publish immutable
//  snapshots through `SnapshotBox` (see ParameterBus.swift). The render
//  thread only ever *reads* those boxes, at most once per `render()` call,
//  and applies pattern swaps at the next sequencer step boundary.
//

import Foundation

/// `@unchecked Sendable`: instances are handed to an `AVAudioSourceNode`
/// render closure that runs on the realtime audio thread while control
/// methods (`setSpace`, `setPattern`, ...) are called from the main actor.
/// This is safe by construction -- see the thread-model note above: the
/// render thread only touches its own private ivars plus reads through the
/// lock-free snapshot boxes; the control thread only touches the shadow
/// copies and publishes new snapshots. Neither side mutates shared state
/// without going through a snapshot publish/read.
final class LiminalDSPCore: @unchecked Sendable {
    let sampleRate: Double

    // MARK: Control-thread-facing snapshot buses

    private let paramBox: SnapshotBox<ParamSnapshot>
    private let arpBox: SnapshotBox<ValueBox<ArpeggioPattern>>
    private let drumBox: SnapshotBox<ValueBox<DrumPattern>>

    // Control-thread-only shadow copies, used to build the next published
    // ParamSnapshot incrementally. Never touched by the render thread.
    private var shadowSpace: Float
    private var shadowAge: Float
    private var shadowDrumsEnabled: Bool
    private var shadowDrumLevel: Float

    // MARK: Render-thread-only state

    private var rng: XorshiftRNG
    private let voiceBank: SynthVoiceBank
    private let arpSeq: ArpeggioSequencer
    private let drums: DrumMachine
    private var wowL: WowFlutterProcessor
    private var wowR: WowFlutterProcessor
    private var hissL: TapeHiss
    private var hissR: TapeHiss
    private var ageLPL = AgeLowpass()
    private var ageLPR = AgeLowpass()

    private var smSpace: SmoothedParam
    private var smAge: SmoothedParam
    private var smDrumGain: SmoothedParam

    private var lastSeenArpRef: ValueBox<ArpeggioPattern>?
    private var lastSeenDrumRef: ValueBox<DrumPattern>?

    private var elapsedSamples: Int64 = 0
    private var nextTickSample: Int64 = 0
    private var globalTickIndex: Int = 0

    /// - Parameters:
    ///   - pattern/beat: initial patterns (also used as the "seed" for a
    ///     freshly constructed offline-render core).
    ///   - space/age/drumsEnabled/drumLevel: initial parameter values.
    init(pattern: ArpeggioPattern,
         beat: DrumPattern,
         space: Float,
         age: Float,
         drumsEnabled: Bool,
         drumLevel: Float,
         sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate

        shadowSpace = space
        shadowAge = age
        shadowDrumsEnabled = drumsEnabled
        shadowDrumLevel = drumLevel

        paramBox = SnapshotBox(ParamSnapshot(space: space, age: age, drumsEnabled: drumsEnabled, drumLevel: drumLevel))
        let arpValueBox = ValueBox(pattern)
        let drumValueBox = ValueBox(beat)
        arpBox = SnapshotBox(arpValueBox)
        drumBox = SnapshotBox(drumValueBox)
        lastSeenArpRef = arpValueBox
        lastSeenDrumRef = drumValueBox

        rng = XorshiftRNG(seed: 0xC0FFEE_1234_5678)
        voiceBank = SynthVoiceBank(voiceCount: 10, sampleRate: sampleRate)
        arpSeq = ArpeggioSequencer(initialPattern: pattern)
        drums = DrumMachine(initialPattern: beat, sampleRate: sampleRate)
        wowL = WowFlutterProcessor(sampleRate: sampleRate, phaseOffset: 0)
        wowR = WowFlutterProcessor(sampleRate: sampleRate, phaseOffset: 0.27)
        hissL = TapeHiss(sampleRate: sampleRate, seed: 0x1111_2222_3333_4444)
        hissR = TapeHiss(sampleRate: sampleRate, seed: 0x5555_6666_7777_8888)

        smSpace = SmoothedParam(initial: space, timeConstant: 0.02, sampleRate: sampleRate)
        smAge = SmoothedParam(initial: age, timeConstant: 0.02, sampleRate: sampleRate)
        smDrumGain = SmoothedParam(initial: drumsEnabled ? Self.drumGainLinear(drumLevel) : 0,
                                    timeConstant: 0.006, sampleRate: sampleRate)
    }

    // MARK: Control-thread API

    func setSpace(_ v: Float) {
        shadowSpace = clamp(v, 0, 1)
        publishParams()
    }

    func setAge(_ v: Float) {
        shadowAge = clamp(v, 0, 1)
        publishParams()
    }

    func setDrumsEnabled(_ v: Bool) {
        shadowDrumsEnabled = v
        publishParams()
    }

    func setDrumLevel(_ v: Float) {
        shadowDrumLevel = clamp(v, 0, 1)
        publishParams()
    }

    /// Queue a new arpeggio pattern. Picked up by the render thread and
    /// applied at the next sequencer step boundary.
    func setPattern(_ pattern: ArpeggioPattern) {
        arpBox.publish(ValueBox(pattern))
    }

    /// Queue a new drum pattern. Applied at the next 16th-note step boundary.
    func setBeat(_ pattern: DrumPattern) {
        drumBox.publish(ValueBox(pattern))
    }

    // MARK: Realtime render entry point

    /// Renders `frames` of interleaved stereo Float32 into `buffer`
    /// (buffer must hold at least `frames * 2` floats). No allocation, no
    /// locking, no Objective-C dispatch -- safe to call from an audio
    /// render callback.
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        // Pick up parameter/pattern changes at most once per callback.
        let snapshot = paramBox.read()
        smSpace.setTarget(snapshot.space)
        smAge.setTarget(snapshot.age)
        let drumGainTarget: Float = snapshot.drumsEnabled ? Self.drumGainLinear(snapshot.drumLevel) : 0
        smDrumGain.setTarget(drumGainTarget)

        let arpRef = arpBox.read()
        if arpRef !== lastSeenArpRef {
            lastSeenArpRef = arpRef
            arpSeq.queuePatternSwap(arpRef.value)
        }
        let drumRef = drumBox.read()
        if drumRef !== lastSeenDrumRef {
            lastSeenDrumRef = drumRef
            drums.queuePatternSwap(drumRef.value)
        }

        // Buffer-rate derived values (recomputed once per callback --
        // imperceptibly coarse for "gentle" characteristics, avoids
        // per-sample transcendental calls).
        let decayScale = 1 + 0.25 * smSpace.current
        let releaseScale = 0.85 + 0.3 * smSpace.current
        let ageLPCoeff = AgeLowpass.coefficient(age: smAge.current, sampleRate: sampleRate)

        for i in 0..<frames {
            while elapsedSamples >= nextTickSample {
                doTick(releaseScale: releaseScale)
            }
            elapsedSamples += 1

            let age = smAge.next()
            let drumGain = smDrumGain.next()
            _ = smSpace.next()

            let (synthL, synthR) = voiceBank.nextSample()
            let drumMono = drums.nextSample(sampleRate: sampleRate, gain: drumGain, decayScale: decayScale)

            var left = synthL + drumMono
            var right = synthR + drumMono

            left = wowL.process(left, depth: age)
            right = wowR.process(right, depth: age)

            left += hissL.next(level: age)
            right += hissR.next(level: age)

            left = ageLPL.process(left, coeff: ageLPCoeff)
            right = ageLPR.process(right, coeff: ageLPCoeff)

            // Final soft-clip safety stage: at extreme parameter combinations
            // (space=1 lengthens/overlaps synth releases, drumLevel=1 adds
            // up to +6dB on the drum bus) the summed bus can exceed unity.
            // tanh() guarantees |output| < 1 for any finite input and reads
            // as gentle tape-style saturation rather than hard digital
            // clipping -- fits the lo-fi aesthetic instead of fighting it.
            buffer[i * 2] = tanh(left)
            buffer[i * 2 + 1] = tanh(right)
        }
    }

    // MARK: Sequencer clock

    private func doTick(releaseScale: Float) {
        if let arpStep = arpSeq.advanceTick(globalTickIndex: globalTickIndex) {
            if let note = arpStep.midiNote, !arpStep.hold {
                voiceBank.noteOn(midiNote: note,
                                  velocity: arpStep.velocity,
                                  attackRange: 20...80,
                                  releaseRange: 500...1500,
                                  releaseScale: releaseScale,
                                  rng: &rng)
            }
        }
        drums.advanceTick()

        globalTickIndex += 1
        scheduleNextTick()
    }

    private func scheduleNextTick() {
        let bpm = Double(max(1, arpSeq.activePattern.bpm))
        let baseSamplesPerTick = sampleRate * 60.0 / (bpm * 4.0)
        let swing = Double(drums.swing)
        let swingOffset = swing * baseSamplesPerTick * 0.33
        let willBeOdd = (globalTickIndex % 2 == 1)
        let delta = baseSamplesPerTick + (willBeOdd ? swingOffset : -swingOffset)
        nextTickSample = elapsedSamples + Int64(max(1, delta.rounded()))
    }

    private func publishParams() {
        paramBox.publish(ParamSnapshot(space: shadowSpace, age: shadowAge,
                                        drumsEnabled: shadowDrumsEnabled, drumLevel: shadowDrumLevel))
    }

    private static func drumGainLinear(_ level: Float) -> Float {
        guard level > 0.001 else { return 0 }
        let db = lerp(-40, 6, clamp(level, 0, 1))
        return dBToLinear(db)
    }
}
