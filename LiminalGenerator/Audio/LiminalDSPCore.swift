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
    private let bassBox: SnapshotBox<ValueBox<BasslinePattern>>

    // Control-thread-only shadow copies, used to build the next published
    // ParamSnapshot incrementally. Never touched by the render thread.
    private var shadowSpace: Float
    private var shadowAge: Float
    private var shadowDrumsEnabled: Bool
    private var shadowDrumLevel: Float
    private var shadowSpeed: Float
    private var shadowColor: Float
    private var shadowWaveform: LiminalWaveform
    private var shadowBassEnabled: Bool
    private var shadowBassColor: Float
    private var shadowBassLevel: Float

    // MARK: Render-thread-only state

    private var rng: XorshiftRNG
    private let voiceBank: SynthVoiceBank
    private let arpSeq: ArpeggioSequencer
    private let bassSeq: BassSequencer
    private var bassVoice = BassVoice()
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
    private var smBassGain: SmoothedParam
    /// Smoothed SPEED (0...1, not the multiplier itself -- `speedMultiplier`
    /// is applied where the smoothed value is read) so slider drags ramp
    /// over ~20ms instead of stepping the tick clock/loop rate abruptly.
    /// Advanced every sample (unlike `smSpace`/`smAge`'s buffer-rate reads)
    /// because both the tick-clock scheduling and the loop's per-sample
    /// varispeed cursor need genuinely sample-accurate smoothing.
    private var smSpeed: SmoothedParam
    /// Smoothed COLOR (0...1). Only read once per callback (buffer-rate,
    /// like `releaseScale`/`ageLPCoeff` below) since it's applied at note
    /// trigger time, not continuously per sample -- see `SynthVoice.trigger`.
    private var smColor: SmoothedParam
    /// Smoothed bassColor (0...1) -- same buffer-rate, trigger-time-only
    /// consumption pattern as `smColor`, see `BassVoice.noteOn`.
    private var smBassColor: SmoothedParam

    private var lastSeenArpRef: ValueBox<ArpeggioPattern>?
    private var lastSeenDrumRef: ValueBox<LoopSwapPayload>?
    private var lastSeenBassRef: ValueBox<BasslinePattern>?

    private var elapsedSamples: Int64 = 0
    private var nextTickSample: Int64 = 0
    private var globalTickIndex: Int = 0

    // Tempo-sync state (render-thread-only). The shared 16th-note tick grid
    // normally runs at the fixed `baseMelodyBPM` constant; while drums are
    // enabled it instead runs at the active loop's bpm. Either way the
    // result is further scaled by SPEED's `speedMultiplier` (0.70x...1.30x,
    // smoothed) -- see `scheduleNextTick`. To keep loop-start and
    // arpeggio-pattern-cycle boundaries phase-aligned, the loop-vs-fixed-bpm
    // switch (and any queued loop swap) is only ever applied at a "bar"
    // boundary -- every 16 ticks, which is exactly one full cycle of the
    // fixed 16-step arp pattern (see `ArpeggioSequencer.ticksPerStep`,
    // `PatternGenerator.stepCount`) and matches the loop files' own 4-bar
    // structure once tempo-locked. SPEED changes are NOT gated to bar
    // boundaries -- they're smoothed instead (uniform time-scaling, not a
    // content swap, so no phase-alignment concern).
    private static let ticksPerBar = 16
    private var activeTempoUsesLoop: Bool
    private var pendingDrumsEnabledForTempo: Bool

    /// - Parameters:
    ///   - pattern/beat/loopBuffer: initial patterns + the already-decoded
    ///     loop buffer matching `beat` (also used as the "seed" for a
    ///     freshly constructed offline-render core -- passing the SAME
    ///     `LoopBuffer` instance guarantees bit-identical drum audio).
    ///   - bassPattern: initial bassline pattern (see `BasslinePattern`).
    ///   - space/age/drumsEnabled/drumLevel/speed/color/waveform/bassEnabled/
    ///     bassColor/bassLevel: initial parameter values.
    init(pattern: ArpeggioPattern,
         beat: DrumPattern,
         loopBuffer: LoopBuffer,
         bassPattern: BasslinePattern,
         space: Float,
         age: Float,
         drumsEnabled: Bool,
         drumLevel: Float,
         speed: Float,
         color: Float,
         waveform: LiminalWaveform,
         bassEnabled: Bool,
         bassColor: Float,
         bassLevel: Float,
         sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate

        shadowSpace = space
        shadowAge = age
        shadowDrumsEnabled = drumsEnabled
        shadowDrumLevel = drumLevel
        shadowSpeed = speed
        shadowColor = color
        shadowWaveform = waveform
        shadowBassEnabled = bassEnabled
        shadowBassColor = bassColor
        shadowBassLevel = bassLevel

        paramBox = SnapshotBox(ParamSnapshot(space: space, age: age, drumsEnabled: drumsEnabled, drumLevel: drumLevel,
                                              speed: speed, color: color, waveform: waveform,
                                              bassEnabled: bassEnabled, bassColor: bassColor, bassLevel: bassLevel))
        let arpValueBox = ValueBox(pattern)
        let drumValueBox = ValueBox(LoopSwapPayload(pattern: beat, buffer: loopBuffer))
        let bassValueBox = ValueBox(bassPattern)
        arpBox = SnapshotBox(arpValueBox)
        drumBox = SnapshotBox(drumValueBox)
        bassBox = SnapshotBox(bassValueBox)
        lastSeenArpRef = arpValueBox
        lastSeenDrumRef = drumValueBox
        lastSeenBassRef = bassValueBox

        rng = XorshiftRNG(seed: 0xC0FFEE_1234_5678)
        voiceBank = SynthVoiceBank(voiceCount: 10, sampleRate: sampleRate)
        arpSeq = ArpeggioSequencer(initialPattern: pattern)
        bassSeq = BassSequencer(initialPattern: bassPattern)
        loopPlayer = LoopPlayer(initialPattern: beat, initialBuffer: loopBuffer)
        wowL = WowFlutterProcessor(sampleRate: sampleRate, phaseOffset: 0)
        wowR = WowFlutterProcessor(sampleRate: sampleRate, phaseOffset: 0.27)
        hissL = TapeHiss(sampleRate: sampleRate, seed: 0x1111_2222_3333_4444)
        hissR = TapeHiss(sampleRate: sampleRate, seed: 0x5555_6666_7777_8888)
        loopLowpassCoeff = OnePoleLowpass.coefficient(cutoffHz: 8_500, sampleRate: sampleRate)

        smSpace = SmoothedParam(initial: space, timeConstant: 0.02, sampleRate: sampleRate)
        smAge = SmoothedParam(initial: age, timeConstant: 0.02, sampleRate: sampleRate)
        smDrumGain = SmoothedParam(initial: drumsEnabled ? levelToGainLinear(drumLevel) : 0,
                                    timeConstant: 0.006, sampleRate: sampleRate)
        smBassGain = SmoothedParam(initial: bassEnabled ? levelToGainLinear(bassLevel) : 0,
                                    timeConstant: 0.006, sampleRate: sampleRate)
        smSpeed = SmoothedParam(initial: speed, timeConstant: 0.02, sampleRate: sampleRate)
        smColor = SmoothedParam(initial: color, timeConstant: 0.02, sampleRate: sampleRate)
        smBassColor = SmoothedParam(initial: bassColor, timeConstant: 0.02, sampleRate: sampleRate)

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

    /// Tape-style playback-rate control (0...1, multiplier 0.70x...1.30x
    /// via `speedMultiplier` in DSPMath.swift). Scales the shared tick
    /// clock's step duration and the drum loop's per-sample playback rate
    /// together; synth oscillator pitches are unaffected -- see `render`.
    func setSpeed(_ v: Float) {
        shadowSpeed = clamp(v, 0, 1)
        publishParams()
    }

    /// Synth-only filter tone bias (0...1, dark...bright). Never applied to
    /// the drum loop bus -- see `SynthVoice.trigger`.
    func setColor(_ v: Float) {
        shadowColor = clamp(v, 0, 1)
        publishParams()
    }

    /// Melody-only oscillator waveform. Never affects the bassline or drums.
    func setWaveform(_ v: LiminalWaveform) {
        shadowWaveform = v
        publishParams()
    }

    func setBassEnabled(_ v: Bool) {
        shadowBassEnabled = v
        publishParams()
    }

    /// Bass-only filter tone bias (0...1, dark...bright) -- own independent
    /// 24dB lowpass instance from the melody's COLOR, same log-mapping.
    func setBassColor(_ v: Float) {
        shadowBassColor = clamp(v, 0, 1)
        publishParams()
    }

    func setBassLevel(_ v: Float) {
        shadowBassLevel = clamp(v, 0, 1)
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

    /// Queue a new bassline rhythm/note pattern. Picked up by the render
    /// thread and applied at the next tick (see `BassSequencer`). Note
    /// pitches are scale-degree ROLES resolved against whatever the CURRENT
    /// `ArpeggioPattern`'s root+scale is at trigger time (see
    /// `BasslineGenerator.resolveBassMIDI` and `doTick` below) -- so the
    /// bassline is always in the current key with no separate "refresh"
    /// step needed when the melody's key changes.
    func setBassPattern(_ pattern: BasslinePattern) {
        bassBox.publish(ValueBox(pattern))
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
        let drumGainTarget: Float = snapshot.drumsEnabled ? levelToGainLinear(snapshot.drumLevel) : 0
        smDrumGain.setTarget(drumGainTarget)
        let bassGainTarget: Float = snapshot.bassEnabled ? levelToGainLinear(snapshot.bassLevel) : 0
        smBassGain.setTarget(bassGainTarget)
        smSpeed.setTarget(snapshot.speed)
        smColor.setTarget(snapshot.color)
        smBassColor.setTarget(snapshot.bassColor)
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
        let bassRef = bassBox.read()
        if bassRef !== lastSeenBassRef {
            lastSeenBassRef = bassRef
            bassSeq.queuePatternSwap(bassRef.value)
        }

        // Buffer-rate derived values (recomputed once per callback --
        // imperceptibly coarse for "gentle" characteristics, avoids
        // per-sample transcendental calls).
        let releaseScale = 0.85 + 0.3 * smSpace.current
        let ageLPCoeff = AgeLowpass.coefficient(age: smAge.current, sampleRate: sampleRate)
        // COLOR/bassColor/waveform only ever apply at note-trigger time (see
        // `SynthVoice.trigger`/`BassVoice.noteOn`), so buffer-rate resolution
        // is plenty -- also click-free, since a change only ever affects
        // notes that haven't started yet.
        let colorValue = smColor.current
        let bassColorValue = smBassColor.current
        let waveform = snapshot.waveform

        for i in 0..<frames {
            // SPEED needs genuinely sample-accurate smoothing: it drives
            // both the tick-clock step duration (below) and the drum
            // loop's per-sample varispeed cursor, so it's advanced every
            // sample rather than read once per callback like space/age's
            // buffer-rate derivations above.
            let speedMult = speedMultiplier(smSpeed.next())

            while elapsedSamples >= nextTickSample {
                doTick(releaseScale: releaseScale, colorValue: colorValue, bassColorValue: bassColorValue,
                       waveform: waveform, speedMult: speedMult)
            }
            elapsedSamples += 1

            let age = smAge.next()
            let drumGain = smDrumGain.next()
            let bassGain = smBassGain.next()
            _ = smSpace.next()
            _ = smColor.next()
            _ = smBassColor.next()

            let (synthL, synthR) = voiceBank.nextSample()
            let loopRaw: Float = activeTempoUsesLoop ? loopPlayer.nextSample(rate: speedMult) : 0
            let drumMono = loopLowpass.process(loopRaw, coeff: loopLowpassCoeff) * drumGain
            // Bass ticks on the SAME shared clock regardless of `bassEnabled`
            // (see `BassSequencer`/`doTick`) -- only its gain is gated here,
            // so re-enabling it never needs a resync.
            let bassMono = bassVoice.nextSample(sampleRate: sampleRate) * bassGain

            var left = synthL + drumMono + bassMono
            var right = synthR + drumMono + bassMono

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

    private func doTick(releaseScale: Float, colorValue: Float, bassColorValue: Float,
                         waveform: LiminalWaveform, speedMult: Float) {
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
            // No rests/holds anymore -- every step is its own note-on
            // (see PatternGenerator.swift / the SPEC.md addendum).
            voiceBank.noteOn(midiNote: arpStep.midiNote,
                              velocity: arpStep.velocity,
                              attackRange: 20...80,
                              releaseRange: 500...1500,
                              releaseScale: releaseScale,
                              color: colorValue,
                              waveform: waveform,
                              rng: &rng)
        }

        // Bass always advances on this SAME shared tick clock (never an
        // independent tempo) -- see `BassSequencer`. Note pitches are
        // resolved against `arpSeq.activePattern`'s CURRENT root+scale
        // right here at trigger time, so the bassline is always in tune
        // with whatever key the melody is currently in, even immediately
        // after a `regenerateMelody()` key change (no caching of absolute
        // bass pitches -- see `BasslinePattern.swift`).
        if let bassStep = bassSeq.advanceTick() {
            switch bassStep.kind {
            case .rest:
                bassVoice.noteOff(releaseMs: 220, sampleRate: sampleRate)
            case .hold:
                break // keep sustaining whatever's currently sounding
            case .note(let role):
                let key = arpSeq.activePattern
                let midi = BasslineGenerator.resolveBassMIDI(role: role,
                                                               rootMIDI: key.rootMIDI,
                                                               intervals: key.scale.intervals,
                                                               octaveShift: bassSeq.activePattern.octaveShift)
                bassVoice.noteOn(midiNote: midi,
                                  velocity: bassStep.velocity,
                                  sampleRate: sampleRate,
                                  color: bassColorValue,
                                  rng: &rng)
            }
        }

        globalTickIndex += 1
        scheduleNextTick(speedMult: speedMult)
    }

    /// Effective tempo of the shared 16th-note tick clock:
    /// `baseTempoSource * speedMultiplier`, where `baseTempoSource` is the
    /// active loop's bpm while drums are enabled (tempo-synced to the loop,
    /// per the bar-boundary rule above), otherwise the fixed `baseMelodyBPM`
    /// constant (tempo is decoupled from the arp pattern itself -- see
    /// SPEC.md addendum). `speedMult` (== `speedMultiplier(speed)`, already
    /// smoothed by the caller) scales the step duration by its inverse:
    /// a faster multiplier means shorter steps, i.e. faster tempo.
    private func scheduleNextTick(speedMult: Float) {
        let bpm = activeTempoUsesLoop ? Double(max(1, loopPlayer.bpm)) : baseMelodyBPM
        let samplesPerTick = (sampleRate * 60.0 / (bpm * 4.0)) / Double(speedMult)
        nextTickSample = elapsedSamples + Int64(max(1, samplesPerTick.rounded()))
    }

    private func publishParams() {
        paramBox.publish(ParamSnapshot(space: shadowSpace, age: shadowAge,
                                        drumsEnabled: shadowDrumsEnabled, drumLevel: shadowDrumLevel,
                                        speed: shadowSpeed, color: shadowColor, waveform: shadowWaveform,
                                        bassEnabled: shadowBassEnabled, bassColor: shadowBassColor,
                                        bassLevel: shadowBassLevel))
    }
}
