//
//  AudioEngineController.swift
//  LiminalGenerator
//
//  Pinned contract (do not rename): see SPEC.md "Pinned API contract".
//  Wraps AVAudioEngine: AVAudioSourceNode(LiminalDSPCore) -> AVAudioUnitReverb
//  -> mainMixer. All DSP is shared verbatim with offline rendering via
//  `LiminalDSPCore`.
//

import AVFoundation
import Combine

/// Preallocated interleaved-stereo scratch buffer bridging `LiminalDSPCore`
/// (which renders interleaved Float32, per its pinned entry point) to
/// AVAudioEngine's non-interleaved node format. Allocated once; the
/// render/deinterleave path performs no allocation.
private final class InterleavedScratch: @unchecked Sendable {
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

    func renderAndDeinterleave(dsp: LiminalDSPCore, frameCount: Int, into abl: UnsafeMutableAudioBufferListPointer) {
        let frames = min(frameCount, capacityFrames)
        dsp.render(into: buffer, frames: frames)
        guard abl.count >= 2, let leftRaw = abl[0].mData, let rightRaw = abl[1].mData else { return }
        let left = leftRaw.assumingMemoryBound(to: Float.self)
        let right = rightRaw.assumingMemoryBound(to: Float.self)
        for i in 0..<frames {
            left[i] = buffer[i * 2]
            right[i] = buffer[i * 2 + 1]
        }
    }
}

enum RenderOfflineError: Error {
    case engineFailure
}

@MainActor
final class AudioEngineController: ObservableObject {
    nonisolated static let sampleRate: Double = 44_100
    private static let maxFrameCapacity = 8_192

    @Published var isPlaying: Bool = false // set via play()/pause(), not directly by UI

    // Note: these setters intentionally do NOT reassign `self.<property>`
    // to clamp out-of-range input -- doing so inside a property's own
    // didSet re-triggers didSet on every call (didSet fires unconditionally
    // on assignment, even when the new value doesn't change), which would
    // recurse forever. Out-of-range input is clamped downstream instead
    // (`LiminalDSPCore`'s setters and `reverbWetDry` both clamp).

    @Published var space: Float = 0.55 { // 0...1, didSet pushes to DSP/reverb
        didSet {
            dsp.setSpace(space)
            reverb.wetDryMix = Self.reverbWetDry(forSpace: space)
        }
    }

    @Published var age: Float = 0.4 { // 0...1
        didSet { dsp.setAge(age) }
    }

    @Published var drumsEnabled: Bool = false {
        didSet {
            dsp.setDrumsEnabled(drumsEnabled)
            recomputeEffectiveBPM()
        }
    }

    @Published var drumLevel: Float = 0.65 { // 0...1 (maps -inf...+6dB)
        didSet { dsp.setDrumLevel(drumLevel) }
    }

    /// Tape-style playback-rate control: 0...1, default 0.5 == exactly
    /// 1.0x (see `speedMultiplier` in DSPMath.swift for the 0.70x...1.30x
    /// curve). Scales both the shared tick clock (arp + loop timing) and
    /// the drum loop's own playback rate -- see SPEC.md "Musical style".
    @Published var speed: Float = 0.5 {
        didSet {
            dsp.setSpeed(speed)
            recomputeEffectiveBPM()
        }
    }

    /// Synth-only filter tone bias: 0...1, default ~0.5, dark(0)...bright(1).
    /// Redefined per SPEC.md addendum 2: now directly sets the BASE cutoff
    /// of a real 24dB/octave lowpass (`synthColorCutoffHz`, DSPMath.swift) --
    /// a dramatic, full-range log sweep, not the old mild multiplier. Never
    /// affects the drum loop bus or the bassline.
    @Published var color: Float = 0.5 {
        didSet { dsp.setColor(color) }
    }

    /// Melody voice oscillator waveform (SPEC.md addendum 2). Default
    /// changed to `.sine` per Addendum 3 -- "fits the [ambient pad] style
    /// best". Never affects the pad layer (fixed sound design), the
    /// bassline, or drums.
    @Published var waveform: LiminalWaveform = .sine {
        didSet { dsp.setWaveform(waveform) }
    }

    /// Default false (SPEC.md addendum 2).
    @Published var bassEnabled: Bool = false {
        didSet { dsp.setBassEnabled(bassEnabled) }
    }

    /// 0...1, default ~0.5 -- own independent 24dB lowpass instance, same
    /// log-mapping as the melody's `color`.
    @Published var bassColor: Float = 0.5 {
        didSet { dsp.setBassColor(bassColor) }
    }

    /// 0...1 (maps -inf...+6dB, same curve as `drumLevel`), default ~0.65.
    @Published var bassLevel: Float = 0.65 {
        didSet { dsp.setBassLevel(bassLevel) }
    }

    @Published private(set) var currentPattern: ArpeggioPattern
    @Published private(set) var currentBeat: DrumPattern
    /// Internal only -- no UI-facing readout (per SPEC.md: "No SEQ/BPM
    /// readout row (not requested)" for the BASSLINE card). Kept so
    /// `regenerateBass()` and `renderOffline` can read/reseed it.
    private var currentBassPattern: BasslinePattern
    /// `round(baseTempoSource * speedMultiplier(speed))`, where
    /// `baseTempoSource` is `currentBeat.bpm` while `drumsEnabled`, else the
    /// fixed `baseMelodyBPM` constant. What the SYNTH card's BPM readout
    /// displays. Recomputed whenever `speed`, `drumsEnabled`, or
    /// `currentBeat` change (see `recomputeEffectiveBPM`).
    @Published private(set) var effectiveBPM: Int = 0

    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private let dsp: LiminalDSPCore
    private let scratch = InterleavedScratch(capacityFrames: AudioEngineController.maxFrameCapacity)
    private var sourceNode: AVAudioSourceNode!
    private var interruptionObserver: NSObjectProtocol?

    init() {
        let pattern = PatternGenerator.randomScene()
        let beat = PatternGenerator.randomDrumPattern()
        let bassPattern = BasslineGenerator.randomBasslinePattern()
        currentPattern = pattern
        currentBeat = beat
        currentBassPattern = bassPattern
        dsp = LiminalDSPCore(pattern: pattern, beat: beat,
                              loopBuffer: LoopLoader.buffers[beat.loopIndex],
                              bassPattern: bassPattern,
                              space: 0.55, age: 0.4,
                              drumsEnabled: false, drumLevel: 0.65,
                              speed: 0.5, color: 0.5,
                              waveform: .sine,
                              bassEnabled: false, bassColor: 0.5, bassLevel: 0.65,
                              sampleRate: Self.sampleRate)

        configureAudioSession()
        setupEngineGraph()
        setupInterruptionHandling()
        recomputeEffectiveBPM()
    }

    /// `effectiveBPM = round(baseTempoSource * speedMultiplier(speed))`,
    /// where `baseTempoSource` is `currentBeat.bpm` while `drumsEnabled`,
    /// else the fixed `baseMelodyBPM` constant (DSPMath.swift) -- the same
    /// constant `LiminalDSPCore.scheduleNextTick` drives the actual tick
    /// clock from, so this readout always matches the audible tempo.
    private func recomputeEffectiveBPM() {
        let base = drumsEnabled ? Double(currentBeat.bpm) : baseMelodyBPM
        effectiveBPM = Int((base * Double(speedMultiplier(speed))).rounded())
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: Transport

    func play() {
        ensureEngineRunning()
        isPlaying = true
    }

    func pause() {
        isPlaying = false
        if engine.isRunning {
            engine.pause()
        }
    }

    /// Re-rolls the WHOLE ambient scene (key, progression, chord voicings,
    /// melody motif -- see `PatternGenerator.randomScene`, SPEC.md
    /// Addendum 3). The bassline movement pattern is NOT re-rolled here --
    /// it doesn't need to be. The sub-bass never stores a pitch: it's
    /// resolved live against whatever the CURRENT scene's chord root is at
    /// the moment each bass note triggers (see `LiminalDSPCore.doTick`) --
    /// so as soon as `dsp.setPattern` below takes effect (at the next bar
    /// boundary), every subsequent bass note automatically harmonizes with
    /// the new key. This is the same non-negotiable invariant carried
    /// forward from SPEC.md addendum 2 ("must never sound like it's in the
    /// wrong key after a melody regenerate"); verified in the audio agent's
    /// sanity harness by regenerating the scene repeatedly and confirming
    /// bass notes stay valid roots/passing-tones of whatever the new key's
    /// chords are.
    func regenerateMelody() {
        let pattern = PatternGenerator.randomScene()
        currentPattern = pattern
        dsp.setPattern(pattern)
    }

    /// Re-rolls a new sub-bass movement variation (hold/re-articulate/
    /// passing-tone per bar) -- does not touch the key/progression itself.
    func regenerateBass() {
        let pattern = BasslineGenerator.randomBasslinePattern()
        currentBassPattern = pattern
        dsp.setBassPattern(pattern)
    }

    /// Picks a random loop that is NEVER the currently-active one (guaranteed
    /// change).
    func regenerateBeat() {
        let beat = PatternGenerator.randomDrumPattern(excludingLoopIndex: currentBeat.loopIndex)
        currentBeat = beat
        dsp.setBeat(beat, buffer: LoopLoader.buffers[beat.loopIndex])
        recomputeEffectiveBPM()
    }

    // MARK: Offline render

    /// Offline render of the CURRENT patterns/params to a 44.1k stereo audio
    /// file (CAF). Progress 0...1. Cancellable via task cancellation. Uses
    /// a SEPARATE AVAudioEngine + a fresh `LiminalDSPCore` seeded from the
    /// current state -- the live engine/DSP are never touched, so playback
    /// keeps working during and after the render.
    func renderOffline(duration: TimeInterval,
                        fadeIn: TimeInterval,
                        fadeOut: TimeInterval,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let seed = OfflineRenderSeed(pattern: currentPattern, beat: currentBeat,
                                      loopBuffer: LoopLoader.buffers[currentBeat.loopIndex],
                                      bassPattern: currentBassPattern,
                                      space: space, age: age,
                                      drumsEnabled: drumsEnabled, drumLevel: drumLevel,
                                      speed: speed, color: color,
                                      waveform: waveform,
                                      bassEnabled: bassEnabled, bassColor: bassColor, bassLevel: bassLevel)
        return try await Self.performOfflineRender(seed: seed,
                                                     duration: duration,
                                                     fadeIn: fadeIn,
                                                     fadeOut: fadeOut,
                                                     progress: progress)
    }

    /// `nonisolated` + `static` so calling it via `await` from the
    /// MainActor-isolated `renderOffline` above hops execution onto the
    /// background concurrent executor for its entire (synchronous,
    /// CPU-heavy) body, while remaining part of the SAME Task -- so
    /// `Task.checkCancellation()` correctly observes cancellation of the
    /// caller's task.
    private nonisolated static func performOfflineRender(seed: OfflineRenderSeed,
                                                           duration: TimeInterval,
                                                           fadeIn: TimeInterval,
                                                           fadeOut: TimeInterval,
                                                           progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let sampleRate = Self.sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        let dsp = LiminalDSPCore(pattern: seed.pattern, beat: seed.beat,
                                  loopBuffer: seed.loopBuffer,
                                  bassPattern: seed.bassPattern,
                                  space: seed.space, age: seed.age,
                                  drumsEnabled: seed.drumsEnabled, drumLevel: seed.drumLevel,
                                  speed: seed.speed, color: seed.color,
                                  waveform: seed.waveform,
                                  bassEnabled: seed.bassEnabled, bassColor: seed.bassColor, bassLevel: seed.bassLevel,
                                  sampleRate: sampleRate)

        let chunkFrames = 4_096
        let scratch = InterleavedScratch(capacityFrames: chunkFrames)

        let engine = AVAudioEngine()
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.largeHall2)
        reverb.wetDryMix = reverbWetDry(forSpace: seed.space)

        let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            scratch.renderAndDeinterleave(dsp: dsp, frameCount: Int(frameCount), into: abl)
            return noErr
        }

        engine.attach(sourceNode)
        engine.attach(reverb)
        engine.connect(sourceNode, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(chunkFrames))
        try engine.start()
        defer { engine.stop() }

        let totalFrames = max(1, Int((duration * sampleRate).rounded()))
        let fadeInFrames = max(0, Int((fadeIn * sampleRate).rounded()))
        let fadeOutFrames = max(0, Int((fadeOut * sampleRate).rounded()))

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("liminal-render-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: fileSettings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                frameCapacity: AVAudioFrameCount(chunkFrames)) else {
            throw RenderOfflineError.engineFailure
        }

        var framesRendered = 0
        while framesRendered < totalFrames {
            try Task.checkCancellation()

            let framesToRender = min(chunkFrames, totalFrames - framesRendered)
            pcmBuffer.frameLength = AVAudioFrameCount(framesToRender)

            let status = try engine.renderOffline(AVAudioFrameCount(framesToRender), to: pcmBuffer)
            switch status {
            case .success:
                applyFades(to: pcmBuffer, framesInBuffer: framesToRender,
                           globalStart: framesRendered, totalFrames: totalFrames,
                           fadeInFrames: fadeInFrames, fadeOutFrames: fadeOutFrames)
                try outputFile.write(from: pcmBuffer)
                framesRendered += framesToRender
                progress(Double(framesRendered) / Double(totalFrames))
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw RenderOfflineError.engineFailure
            @unknown default:
                throw RenderOfflineError.engineFailure
            }
        }

        return outputURL
    }

    private nonisolated static func applyFades(to buffer: AVAudioPCMBuffer,
                                                 framesInBuffer: Int,
                                                 globalStart: Int,
                                                 totalFrames: Int,
                                                 fadeInFrames: Int,
                                                 fadeOutFrames: Int) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let fadeOutStart = totalFrames - fadeOutFrames

        for i in 0..<framesInBuffer {
            let globalIndex = globalStart + i
            var gain: Float = 1
            if fadeInFrames > 0 && globalIndex < fadeInFrames {
                gain = min(gain, Float(globalIndex) / Float(fadeInFrames))
            }
            if fadeOutFrames > 0 && globalIndex >= fadeOutStart {
                let remaining = totalFrames - globalIndex
                gain = min(gain, Float(max(0, remaining)) / Float(fadeOutFrames))
            }
            if gain >= 1 { continue }
            for ch in 0..<channelCount {
                channels[ch][i] *= gain
            }
        }
    }

    // MARK: Engine setup

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            // Audio simply won't play; nothing else productive to do here
            // (no console-only dependency assumptions -- this keeps the
            // controller usable even if the session/engine fails to start
            // in a constrained environment, e.g. a simulator with no audio
            // device).
        }
    }

    private func configureAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
        } catch {
            // Non-fatal.
        }
        #endif
    }

    private func setupEngineGraph() {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!
        let dsp = self.dsp
        let scratch = self.scratch

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            scratch.renderAndDeinterleave(dsp: dsp, frameCount: Int(frameCount), into: abl)
            return noErr
        }
        sourceNode = node

        engine.attach(node)
        engine.attach(reverb)
        reverb.loadFactoryPreset(.largeHall2)
        reverb.wetDryMix = Self.reverbWetDry(forSpace: space)

        engine.connect(node, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
    }

    #if os(iOS)
    private func setupInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                  type == .began else { return }
            Task { @MainActor in
                self?.pause()
            }
        }
    }
    #else
    private func setupInterruptionHandling() {}
    #endif

    /// Reverb wetDryMix mapping shared by the live and offline graphs:
    /// `space` 0...1 -> 0...~70% wet (never fully drowns the dry signal).
    private nonisolated static func reverbWetDry(forSpace space: Float) -> Float {
        clamp(space, 0, 1) * 70
    }
}

/// Sendable value bundle capturing everything the offline render needs,
/// read from the live controller's @MainActor state before hopping off
/// the main actor.
private struct OfflineRenderSeed: Sendable {
    let pattern: ArpeggioPattern
    let beat: DrumPattern
    let loopBuffer: LoopBuffer
    let bassPattern: BasslinePattern
    let space: Float
    let age: Float
    let drumsEnabled: Bool
    let drumLevel: Float
    let speed: Float
    let color: Float
    let waveform: LiminalWaveform
    let bassEnabled: Bool
    let bassColor: Float
    let bassLevel: Float
}
