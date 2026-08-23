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
    private let drumBox: SnapshotBox<ValueBox<LoopSwapPayload>>

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
    private let loopPlayer: LoopPlayer
    private var wowL: WowFlutterProcessor
    private var wowR: WowFlutterProcessor
    private var hissL: TapeHiss
    private var hissR: TapeHiss
    private var ageLPL = AgeLowpass()
    private var ageLPR = AgeLowpass()

    // Light fixed lowpass on the summed loop bus (~8.5kHz) -- gentle lo-fi
    // consistency without over-processing loops that are already lo-fi.
    private var loopLowpass = OnePoleLowpass()
    private let loopLowpassCoeff: Float

    private var smSpace: SmoothedParam
    private var smAge: SmoothedParam
    private var smDrumGain: SmoothedParam

    private var lastSeenArpRef: ValueBox<ArpeggioPattern>?
    private var lastSeenDrumRef: ValueBox<LoopSwapPayload>?

    private var elapsedSamples: Int64 = 0
    private var nextTickSample: Int64 = 0
    private var globalTickIndex: Int = 0

    // Tempo-sync state (render-thread-only). The shared 16th-note tick grid
    // normally runs at the arp pattern's own bpm; while drums are enabled it
    // instead runs at the active loop's bpm. To keep loop-start and
    // arpeggio-pattern-cycle boundaries phase-aligned, the switch (and any
    // queued loop swap) is only ever applied at a "bar" boundary -- every 16
    // ticks, which is exactly one full cycle of an 8- or 16-step arp pattern
    // (see `ArpeggioSequencer.ticksPerStep`) and matches the loop files'
    // own 4-bar structure once tempo-locked.
    private static let ticksPerBar = 16
    private var activeTempoUsesLoop: Bool
    private var pendingDrumsEnabledForTempo: Bool

    /// - Parameters:
    ///   - pattern/beat/loopBuffer: initial patterns + the already-decoded
    ///     loop buffer matching `beat` (also used as the "seed" for a
    ///     freshly constructed offline-render core -- passing the SAME
    ///     `LoopBuffer` instance guarantees bit-identical drum audio).
    ///   - space/age/drumsEnabled/drumLevel: initial parameter values.
    init(pattern: ArpeggioPattern,
         beat: DrumPattern,
         loopBuffer: LoopBuffer,
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
        let drumValueBox = ValueBox(LoopSwapPayload(pattern: beat, buffer: loopBuffer))
        arpBox = SnapshotBox(arpValueBox)
        drumBox = SnapshotBox(drumValueBox)
        lastSeenArpRef = arpValueBox
        lastSeenDrumRef = drumValueBox

        rng = XorshiftRNG(seed: 0xC0FFEE_1234_5678)
        voiceBank = SynthVoiceBank(voiceCount: 10, sampleRate: sampleRate)
        arpSeq = ArpeggioSequencer(initialPattern: pattern)
        loopPlayer = LoopPlayer(initialPattern: beat, initialBuffer: loopBuffer)
        wowL = WowFlutterProcessor(sampleRate: sampleRate, phaseOffset: 0)
        wowR = WowFlutterProcessor(sampleRate: sampleRate, phaseOffset: 0.27)
        hissL = TapeHiss(sampleRate: sampleRate, seed: 0x1111_2222_3333_4444)
        hissR = TapeHiss(sampleRate: sampleRate, seed: 0x5555_6666_7777_8888)
        loopLowpassCoeff = OnePoleLowpass.coefficient(cutoffHz: 8_500, sampleRate: sampleRate)

        smSpace = SmoothedParam(initial: space, timeConstant: 0.02, sampleRate: sampleRate)
        smAge = SmoothedParam(initial: age, timeConstant: 0.02, sampleRate: sampleRate)
        smDrumGain = SmoothedParam(initial: drumsEnabled ? Self.drumGainLinear(drumLevel) : 0,
                                    timeConstant: 0.006, sampleRate: sampleRate)

        activeTempoUsesLoop = drumsEnabled
        pendingDrumsEnabledForTempo = drumsEnabled
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

    /// Queue a new loop selection (pattern metadata + its already-decoded
    /// buffer, decoded off the render thread by the caller). Applied at the
    /// next bar boundary -- see the tempo-sync note above `activeTempoUsesLoop`.
    func setBeat(_ pattern: DrumPattern, buffer: LoopBuffer) {
        drumBox.publish(ValueBox(LoopSwapPayload(pattern: pattern, buffer: buffer)))
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
        pendingDrumsEnabledForTempo = snapshot.drumsEnabled

        let arpRef = arpBox.read()
        if arpRef !== lastSeenArpRef {
            lastSeenArpRef = arpRef
            arpSeq.queuePatternSwap(arpRef.value)
        }
        let drumRef = drumBox.read()
        if drumRef !== lastSeenDrumRef {
            lastSeenDrumRef = drumRef
            loopPlayer.queueSwap(drumRef.value)
        }

        // Buffer-rate derived values (recomputed once per callback --
        // imperceptibly coarse for "gentle" characteristics, avoids
        // per-sample transcendental calls).
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
            let loopRaw: Float = activeTempoUsesLoop ? loopPlayer.nextSample() : 0
            let drumMono = loopLowpass.process(loopRaw, coeff: loopLowpassCoeff) * drumGain

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
        // Bar boundary: every 16 ticks (see `ticksPerBar`). Loop swaps and
        // the drums-enabled tempo switch are only ever applied here, so a
        // change mid-bar never yanks the shared tick clock or the loop's
        // sample cursor out from under audio already in flight -- the next
        // bar always starts clean and phase-aligned.
        if globalTickIndex % Self.ticksPerBar == 0 {
            let wasLoopTempo = activeTempoUsesLoop
            loopPlayer.applyPendingSwapAtBarBoundary()
            activeTempoUsesLoop = pendingDrumsEnabledForTempo
            if activeTempoUsesLoop && !wasLoopTempo {
                // Just turned on (or turned back on): always restart the
                // loop from its downbeat rather than resuming wherever the
                // cursor happened to be left.
                loopPlayer.resetCursor()
            }
        }

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

        globalTickIndex += 1
        scheduleNextTick()
    }

    /// Effective tempo of the shared 16th-note tick clock: the active
    /// loop's bpm while drums are enabled (tempo-synced to the loop, per the
    /// bar-boundary rule above), otherwise the arp pattern's own bpm.
    private func scheduleNextTick() {
        let bpm = Double(max(1, activeTempoUsesLoop ? loopPlayer.bpm : arpSeq.activePattern.bpm))
        let samplesPerTick = sampleRate * 60.0 / (bpm * 4.0)
        nextTickSample = elapsedSamples + Int64(max(1, samplesPerTick.rounded()))
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
