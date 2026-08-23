//
//  LoopPlayer.swift
//  LiminalGenerator
//
//  Plays back one of the bundled CC0 lo-fi drum loops (Resources/Loops/,
//  manifest in LoopManifest.swift) instead of synthesizing 808 drums.
//
//  `LoopLoader` decodes every bundled WAV into a Float32 buffer exactly
//  once per process (off the render thread -- called from the control/main
//  actor), producing an immutable `LoopBuffer` per loop that is safe to
//  share (read-only) across the live controller and any number of offline
//  render `LiminalDSPCore` instances.
//
//  `LoopPlayer` is the render-thread-only object that owns the active
//  buffer + a sample cursor and advances it with seamless wraparound. It
//  never allocates, reads files, or locks -- swapping to a new buffer only
//  ever *reads* an already-decoded `LoopBuffer` handed to it via
//  `LiminalDSPCore`'s existing lock-free snapshot mechanism (see
//  `ParameterBus.swift`), applied at the next bar boundary by the caller.
//

import AVFoundation

/// Immutable, fully-decoded loop: mono Float32 PCM at the engine's sample
/// rate (44.1kHz), plus the metadata needed for tempo-sync and the UI
/// readout. `@unchecked Sendable`: `samples` is a `let` array assigned once
/// in `init` and never mutated afterwards, so concurrent reads from
/// multiple `LiminalDSPCore` render threads (live + offline) are safe.
final class LoopBuffer: @unchecked Sendable {
    let samples: [Float]
    let loopIndex: Int
    let displayName: String
    let bpm: Int

    init(samples: [Float], loopIndex: Int, displayName: String, bpm: Int) {
        self.samples = samples
        self.loopIndex = loopIndex
        self.displayName = displayName
        self.bpm = bpm
    }
}

/// Bundles a `DrumPattern` (the pinned-contract loop-selection metadata)
/// with its matching decoded `LoopBuffer` so both are published/applied as
/// one atomic unit through `LiminalDSPCore`'s snapshot box -- the render
/// thread can never observe a pattern/buffer mismatch.
struct LoopSwapPayload: Sendable {
    let pattern: DrumPattern
    let buffer: LoopBuffer
}

/// Decodes every bundled loop WAV into a `LoopBuffer` once per process.
/// Called from the control (main) thread only -- file IO and decoding never
/// happen on the audio render thread.
enum LoopLoader {
    /// Eagerly decoded on first access and cached for the lifetime of the
    /// process. Indexed identically to `LoopLibrary.all`.
    static let buffers: [LoopBuffer] = LoopLibrary.all.enumerated().map { index, info in
        decode(index: index, info: info)
    }

    private static func decode(index: Int, info: LoopInfo) -> LoopBuffer {
        let resourceName = (info.fileName as NSString).deletingPathExtension
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url) else {
            assertionFailure("Missing bundled loop resource: \(info.fileName)")
            return LoopBuffer(samples: [0], loopIndex: index, displayName: info.displayName, bpm: info.bpm)
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount),
              (try? file.read(into: pcmBuffer)) != nil,
              let channelData = pcmBuffer.floatChannelData else {
            assertionFailure("Failed to decode bundled loop resource: \(info.fileName)")
            return LoopBuffer(samples: [0], loopIndex: index, displayName: info.displayName, bpm: info.bpm)
        }

        let n = Int(pcmBuffer.frameLength)
        let samples = [Float](UnsafeBufferPointer(start: channelData[0], count: n))
        return LoopBuffer(samples: samples, loopIndex: index, displayName: info.displayName, bpm: info.bpm)
    }
}

/// Render-thread-only loop playback: owns the active buffer + pattern and a
/// sample cursor, advanced once per rendered sample with seamless
/// wraparound (the bundled loops are pre-declicked at the bar boundary, see
/// `LICENSES-LOOPS.md`, so wrapping the cursor never produces a seam
/// click). Pattern/buffer swaps are queued from the render thread (after
/// reading a new snapshot) and only actually applied by the caller at a
/// tick-grid bar boundary via `applyPendingSwapAtBarBoundary()`, which also
/// resets the cursor to 0 so the new loop's downbeat lands exactly on the
/// bar.
/// SPEED implementation note: playback advances a fractional (`Double`)
/// sample cursor by `rate` (== `speedMultiplier(speed)`, see DSPMath.swift)
/// per output sample rather than a fixed 1-sample step, with linear
/// interpolation between the two neighboring samples. This is a deliberate
/// tape-varispeed effect -- the loop's pitch shifts with playback rate,
/// same as a tape deck's speed knob -- per SPEC.md.
final class LoopPlayer {
    private(set) var activePattern: DrumPattern
    private(set) var activeBuffer: LoopBuffer
    private var pendingSwap: LoopSwapPayload?
    private var cursor: Double = 0

    init(initialPattern: DrumPattern, initialBuffer: LoopBuffer) {
        activePattern = initialPattern
        activeBuffer = initialBuffer
    }

    var bpm: Int { activeBuffer.bpm }

    /// Called from the render thread once it has observed a new published
    /// snapshot. Does NOT apply immediately -- see `applyPendingSwapAtBarBoundary()`.
    func queueSwap(_ payload: LoopSwapPayload) {
        pendingSwap = payload
    }

    /// Called by `LiminalDSPCore` exactly at a bar boundary. Applies any
    /// queued swap and resets the sample cursor to 0.
    func applyPendingSwapAtBarBoundary() {
        guard let pending = pendingSwap else { return }
        activePattern = pending.pattern
        activeBuffer = pending.buffer
        pendingSwap = nil
        cursor = 0
    }

    /// Restarts playback from the loop's downbeat (sample 0). Called when
    /// drums transition from disabled -> enabled at a bar boundary, so
    /// re-enabling never resumes mid-loop.
    func resetCursor() {
        cursor = 0
    }

    /// - Parameter rate: playback-rate multiplier (`speedMultiplier(speed)`).
    ///   1.0 = normal speed (the pre-SPEED behavior). Advances the
    ///   fractional cursor by `rate` samples and linearly interpolates
    ///   between the two neighboring samples -- with `rate` always in
    ///   0.70...1.30 (see `speedMultiplier`), the cursor never advances
    ///   more than ~1.3 samples per call, so a 2-tap interpolation is
    ///   always sufficient.
    @inline(__always)
    func nextSample(rate: Float) -> Float {
        let samples = activeBuffer.samples
        let n = samples.count
        guard n > 0 else { return 0 }
        let i0 = Int(cursor)
        let i1 = (i0 + 1) % n
        let frac = Float(cursor - Double(i0))
        let s = samples[i0] + (samples[i1] - samples[i0]) * frac

        cursor += Double(rate)
        if cursor >= Double(n) { cursor -= Double(n) }
        return s
    }
}
