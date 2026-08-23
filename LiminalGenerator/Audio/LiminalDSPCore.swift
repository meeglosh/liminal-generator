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
    private var shadowNostalgia: Float

    // MARK: Render-thread-only state

    private var rng: XorshiftRNG
    /// Sparse floating melody voice pool (SPEC.md Addendum 3). Small pool
    /// is plenty -- melody is 2-5 notes per 2-bar phrase, rarely more than
    /// 2-3 overlapping given the motif generator's minimum note spacing.
    private let voiceBank: SynthVoiceBank
    /// Pad-chord voice pool -- see `PadVoice.swift`.
    private let padBank: PadVoiceBank
    private let sceneSeq: SceneSequencer
    private let bassSeq: BassSequencer
    private var bassVoice = BassVoice()
    private let loopPlayer: LoopPlayer
    private var wowL: WowFlutterProcessor
    private var wowR: WowFlutterProcessor
    private var hissL: TapeHiss
    private var hissR: TapeHiss
    /// SPEC.md Addendum 4: Juno-106-style BBD stereo chorus. Sits on the
    /// SYNTH BUS ONLY (pads + melody, summed here AFTER their own per-voice
    /// filters), strictly BEFORE that bus is added to bass/drums -- see
    /// `render`. Bass and drums never reach this instance at all.
    private var junoChorus: JunoChorus
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
    /// Smoothed NOSTALGIA (0...1). Advanced every sample (like `smSpeed`/
    /// `smAge`/`smDrumGain`/`smBassGain`) rather than read once per buffer,
    /// since it's applied continuously to the chorus wet/dry crossfade
    /// every sample, not just at note-trigger time -- sample-accurate
    /// smoothing keeps slider drags click/zipper-free.
    private var smNostalgia: SmoothedParam

    private var lastSeenArpRef: ValueBox<ArpeggioPattern>?
    private var lastSeenDrumRef: ValueBox<LoopSwapPayload>?
    private var lastSeenBassRef: ValueBox<BasslinePattern>?

    private var elapsedSamples: Int64 = 0
    private var nextTickSample: Int64 = 0
    private var globalTickIndex: Int = 0
    /// `globalTickIndex` value at which the currently-active scene's
    /// progression/melody cycle "began" -- reset to the current
    /// `globalTickIndex` whenever `sceneSeq` applies a queued swap at a bar
    /// boundary, so a freshly-regenerated scene always starts its
    /// progression at chord 0 and its melody motif at phrase 0, rather than
    /// resuming mid-cycle against the old scene's absolute tick position.
    private var sceneStartTick: Int = 0

    // MARK: Breathing (SPEC.md Addendum 3, always on)
    //
    // A gentle, tempo-synced gain swell on the pad+bass bus (never melody).
    // Driven entirely by the shared sample-accurate tick clock -- see
    // `breathingGainLinear` in DSPMath.swift for why this makes the phase
    // inherently deterministic across live/offline renders with no extra
    // seeding. Period is 16 ticks (one bar) normally, or 8 ticks (half a
    // bar) while drums are enabled ("lightly following the beat").
    private var activeBreathingPeriodTicks: Int = 16
    private var breathBarStartSample: Int64 = 0
    private var breathBarLengthSamples: Double = 1
    private static let breathingDepthDB: Float = 3.0

    // Tempo-sync state (render-thread-only). The shared 16th-note tick grid
    // normally runs at the fixed `baseMelodyBPM` constant; while drums are
    // enabled it instead runs at the active loop's bpm. Either way the
    // result is further scaled by SPEED's `speedMultiplier` (0.70x...1.30x,
    // smoothed) -- see `scheduleNextTick`. To keep loop-start and chord/bar
    // boundaries phase-aligned, the loop-vs-fixed-bpm switch (and any
    // queued loop or scene swap) is only ever applied at a "bar" boundary
    // -- every 16 ticks, one chord's worth of the pad progression (see
    // `PatternGenerator.padRootAnchorMIDI` / `ArpeggioPattern.progression`)
    // -- and matches the loop files' own 4-bar structure once tempo-locked.
    // SPEED changes are NOT gated to bar boundaries -- they're smoothed
    // instead (uniform time-scaling, not a content swap, so no
    // phase-alignment concern).
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
    ///     bassColor/bassLevel/nostalgia: initial parameter values.
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
         nostalgia: Float,
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
        shadowNostalgia = nostalgia

        paramBox = SnapshotBox(ParamSnapshot(space: space, age: age, drumsEnabled: drumsEnabled, drumLevel: drumLevel,
                                              speed: speed, color: color, waveform: waveform,
                                              bassEnabled: bassEnabled, bassColor: bassColor, bassLevel: bassLevel,
                                              nostalgia: nostalgia))
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
        voiceBank = SynthVoiceBank(voiceCount: 8, sampleRate: sampleRate)
        padBank = PadVoiceBank(voiceCount: 20, sampleRate: sampleRate)
        sceneSeq = SceneSequencer(initialScene: pattern)
        bassSeq = BassSequencer(initialPattern: bassPattern)
        loopPlayer = LoopPlayer(initialPattern: beat, initialBuffer: loopBuffer)
        wowL = WowFlutterProcessor(sampleRate: sampleRate, phaseOffset: 0)
        wowR = WowFlutterProcessor(sampleRate: sampleRate, phaseOffset: 0.27)
        hissL = TapeHiss(sampleRate: sampleRate, seed: 0x1111_2222_3333_4444)
        hissR = TapeHiss(sampleRate: sampleRate, seed: 0x5555_6666_7777_8888)
        junoChorus = JunoChorus(sampleRate: sampleRate)
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
        smNostalgia = SmoothedParam(initial: nostalgia, timeConstant: 0.02, sampleRate: sampleRate)

        activeTempoUsesLoop = drumsEnabled
        pendingDrumsEnabledForTempo = drumsEnabled

        // Sane default breathing-bar length (one bar at baseMelodyBPM,
        // 1.0x speed) so the very first bar's breathing curve is already
        // correct before the first tick's boundary recompute.
        let initialBpm = drumsEnabled ? Double(max(1, loopBuffer.bpm)) : baseMelodyBPM
        let initialSamplesPerTick = (sampleRate * 60.0 / (initialBpm * 4.0)) / Double(speedMultiplier(speed))
        activeBreathingPeriodTicks = Self.ticksPerBar
        breathBarLengthSamples = initialSamplesPerTick * Double(Self.ticksPerBar)
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

    /// Juno-106-style BBD stereo chorus mix (0...1) -- synth layer only
    /// (pads + melody). Never applied to the bassline or drums. See
    /// `JunoChorus` and SPEC.md Addendum 4.
    func setNostalgia(_ v: Float) {
        shadowNostalgia = clamp(v, 0, 1)
        publishParams()
    }

    /// Queue a new generated scene (key/progression/voicing/melody motif,
    /// see `PatternGenerator.randomScene`). Picked up by the render thread
    /// and applied at the next bar boundary (see `SceneSequencer`).
    func setPattern(_ pattern: ArpeggioPattern) {
        arpBox.publish(ValueBox(pattern))
    }

    /// Queue a new loop selection (pattern metadata + its already-decoded
    /// buffer, decoded off the render thread by the caller). Applied at the
    /// next bar boundary -- see the tempo-sync note above `activeTempoUsesLoop`.
    func setBeat(_ pattern: DrumPattern, buffer: LoopBuffer) {
        drumBox.publish(ValueBox(LoopSwapPayload(pattern: pattern, buffer: buffer)))
    }

    /// Queue a new sub-bass movement variation. Picked up by the render
    /// thread and applied at the next bar boundary (see `BassSequencer`).
    /// Pitches are never stored here -- they're resolved live against
    /// whatever the CURRENT scene's chord root is at trigger time (see
    /// `doTick` below), so the sub is always in the current key with no
    /// separate "refresh" step needed when the scene changes.
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
        smNostalgia.setTarget(snapshot.nostalgia)
        pendingDrumsEnabledForTempo = snapshot.drumsEnabled

        let arpRef = arpBox.read()
        if arpRef !== lastSeenArpRef {
            lastSeenArpRef = arpRef
            sceneSeq.queueSceneSwap(arpRef.value)
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
            let nostalgia = smNostalgia.next()
            _ = smSpace.next()
            _ = smColor.next()
            _ = smBassColor.next()

            let (melL, melR) = voiceBank.nextSample()
            let (padL, padR) = padBank.nextSample()
            let loopRaw: Float = activeTempoUsesLoop ? loopPlayer.nextSample(rate: speedMult) : 0
            let drumMono = loopLowpass.process(loopRaw, coeff: loopLowpassCoeff) * drumGain
            // Bass ticks on the SAME shared clock regardless of `bassEnabled`
            // (see `BassSequencer`/`doTick`) -- only its gain is gated here,
            // so re-enabling it never needs a resync.
            let bassMono = bassVoice.nextSample(sampleRate: sampleRate) * bassGain

            // Breathing (SPEC.md Addendum 3): a smooth, tempo-synced gain
            // swell on pads+bass ONLY -- the melody floats above, un-ducked.
            // See `breathBarStartSample`/`breathBarLengthSamples`, recomputed
            // once per breathing period in `doTick`.
            let breathPhase = Float(clamp(
                (Double(elapsedSamples) - Double(breathBarStartSample)) / max(1, breathBarLengthSamples), 0, 1))
            let breathGain = breathingGainLinear(phase: breathPhase, depthDB: Self.breathingDepthDB)
            let padGainedL = padL * breathGain
            let padGainedR = padR * breathGain
            let bassGained = bassMono * breathGain

            // SYNTH BUS (pads + melody, both already past their own
            // per-voice filters) is summed into its own stereo pair and
            // routed through the Juno-106-style chorus HERE, strictly
            // before it joins bass/drums below (SPEC.md Addendum 4). Bass
            // and drums are summed in completely separately and never touch
            // `junoChorus` -- zero effect on them regardless of `nostalgia`.
            let synthDryL = melL + padGainedL
            let synthDryR = melR + padGainedR
            let (synthWetL, synthWetR) = junoChorus.process(inputL: synthDryL, inputR: synthDryR,
                                                              nostalgia: nostalgia)

            var left = synthWetL + bassGained + drumMono
            var right = synthWetR + bassGained + drumMono

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
        // Bar boundary: every 16 ticks (see `ticksPerBar`). Loop swaps, the
        // drums-enabled tempo switch, and scene (chord/melody) swaps are
        // only ever applied here, so a change mid-bar never yanks the
        // shared tick clock, the loop's sample cursor, or an in-flight
        // chord swell out from under audio already in flight -- the next
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

            // A freshly regenerated scene always restarts its progression
            // at chord 0 / its melody motif at phrase 0 (see `sceneStartTick`
            // doc comment) rather than resuming mid-cycle against the old
            // scene's tick position.
            if sceneSeq.applyPendingSwapAtBarBoundary() {
                sceneStartTick = globalTickIndex
            }

            let scene = sceneSeq.activeScene
            let barCount = max(1, scene.progression.count)
            let barIndexInCycle = ((globalTickIndex - sceneStartTick) / Self.ticksPerBar) % barCount
            let chord = scene.progression[barIndexInCycle]
            // The chord crossfade IS this call: `PadVoiceBank.startChord`
            // releases whatever was sustaining from the previous bar's
            // chord (long release) while triggering fresh voices for this
            // bar's chord (slow attack) -- see `PadVoice.swift`.
            padBank.startChord(tones: chord.tones,
                                velocity: rng.nextFloat(in: 0.55...0.75),
                                color: colorValue,
                                releaseMsRange: 2_000...4_000,
                                rng: &rng)
        }

        // Sparse melody: a precomputed lookup table indexed by tick offset
        // within the scene's melody cycle -- no per-tick music theory, just
        // an array read (see `MelodyMotif.lookup`). Long slow attack/release
        // so notes feel like they're floating rather than plucked.
        let scene = sceneSeq.activeScene
        let cycleTicks = max(1, scene.melodyMotif.cycleTicks)
        let melodyTick = ((globalTickIndex - sceneStartTick) % cycleTicks + cycleTicks) % cycleTicks
        if let event = scene.melodyMotif.lookup[melodyTick] {
            voiceBank.noteOn(midiNote: event.midiNote,
                              velocity: event.velocity,
                              attackRange: 400...1_000,
                              releaseRange: 1_500...3_000,
                              releaseScale: releaseScale,
                              color: colorValue,
                              waveform: waveform,
                              rng: &rng)
        }

        // Sub-bass: always advances on this SAME shared tick clock (never
        // an independent tempo) -- see `BassSequencer`. Pitch is resolved
        // against the CURRENT bar's chord root right here at trigger time
        // (never a cached/stale pitch), so the sub is always in tune with
        // whatever chord is currently sounding, even immediately after a
        // `regenerateMelody()` scene change.
        let barCount = max(1, scene.progression.count)
        let tickInBar = globalTickIndex % Self.ticksPerBar
        let barIndexInCycle = ((globalTickIndex - sceneStartTick) / Self.ticksPerBar) % barCount
        switch bassSeq.advanceTick(barIndexInCycle: barIndexInCycle, tickInBar: tickInBar) {
        case .none:
            break // keep sustaining whatever's currently sounding
        case .note(let semitoneOffset):
            let chordRootMIDI = scene.progression[barIndexInCycle].rootMIDI
            let midi = chordRootMIDI - 12 + semitoneOffset // one octave below the pad root
            bassVoice.noteOn(midiNote: midi,
                              velocity: rng.nextFloat(in: 0.55...0.8),
                              sampleRate: sampleRate,
                              color: bassColorValue,
                              rng: &rng)
        }

        // Breathing period boundary: recomputed at each 16- or 8-tick
        // period edge (see `activeBreathingPeriodTicks`) using the CURRENT
        // tempo, so the swell tracks SPEED/drum-tempo changes smoothly
        // without ever discontinuously jumping mid-swell.
        if globalTickIndex % activeBreathingPeriodTicks == 0 {
            activeBreathingPeriodTicks = activeTempoUsesLoop ? Self.ticksPerBar / 2 : Self.ticksPerBar
            let bpm = activeTempoUsesLoop ? Double(max(1, loopPlayer.bpm)) : baseMelodyBPM
            let samplesPerTick = (sampleRate * 60.0 / (bpm * 4.0)) / Double(speedMult)
            breathBarStartSample = elapsedSamples
            breathBarLengthSamples = samplesPerTick * Double(activeBreathingPeriodTicks)
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
                                        bassLevel: shadowBassLevel, nostalgia: shadowNostalgia))
    }
}
