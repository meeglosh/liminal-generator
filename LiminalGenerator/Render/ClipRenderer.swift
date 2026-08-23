//
//  ClipRenderer.swift
//  LiminalGenerator
//
//  Builds the 120s portrait shareable MP4: 848x1264 @30fps H.264 video +
//  AAC audio, muxed via AVAssetWriter. Audio comes from
//  `AudioEngineController.renderOffline` (pinned contract); video is the
//  still library image run through a Core Image pipeline that visually
//  matches the live Metal VHS shader (UI/VHSShader.metal), with the VCR
//  OSD (timestamp/REC/SP) baked in via Core Graphics/Core Text.
//
//  Progress split: audio synthesis ("BUFFER... NN%") is the first ~40% of
//  overall progress, video encoding ("VIDEO PASS... NN%") is the remaining
//  ~55%, with small fixed slices for the tracking/sync-pulse/mux beats the
//  render screen's terminal log expects. See `RenderProgress`.
//
//  Cancellable at every await point via `Task.checkCancellation()`; on
//  cancellation (or any failure), the writer is cancelled and any partial
//  output/intermediate CAF is removed.
//

import AVFoundation
import CoreImage
import CoreVideo
import UIKit

// MARK: - Errors

enum ClipRenderError: LocalizedError {
    case imageNotFound(String)
    case writerInitFailed(String)
    case writerFailed(String)
    case pixelBufferPoolFailed
    case audioReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .imageNotFound(let name):
            return "Could not load source image \u{201C}\(name)\u{201D}."
        case .writerInitFailed(let reason):
            return "Could not start the video encoder: \(reason)"
        case .writerFailed(let reason):
            return "Video encoding failed: \(reason)"
        case .pixelBufferPoolFailed:
            return "Could not allocate a video frame buffer."
        case .audioReadFailed(let reason):
            return "Could not read the rendered audio track: \(reason)"
        }
    }
}

// MARK: - Progress

/// Sendable progress event stream emitted during `ClipRenderer.render`.
/// The render screen maps each phase onto a fixed terminal-log line plus
/// an overall progress fraction.
struct RenderProgress: Sendable {
    enum Phase: Sendable {
        case tracking
        case syncPulse
        case buffering(Double)   // 0...1, audio synthesis
        case audioComplete
        case video(Double)       // 0...1, frame encode
        case muxing
    }
    let phase: Phase
}

// MARK: - ClipRenderer

enum ClipRenderer {
    struct Config: Sendable {
        var width: Int
        var height: Int
        var fps: Int32
        var duration: TimeInterval
        var fadeIn: TimeInterval
        var fadeOut: TimeInterval

        init(width: Int = 848, height: Int = 1264, fps: Int32 = 30,
             duration: TimeInterval = 120, fadeIn: TimeInterval = 3, fadeOut: TimeInterval = 5) {
            self.width = width
            self.height = height
            self.fps = fps
            self.duration = duration
            self.fadeIn = fadeIn
            self.fadeOut = fadeOut
        }
    }

    /// `nonisolated` so that calling it via `await` from the MainActor-isolated
    /// render view model hops execution onto the background concurrent
    /// executor for its entire body (same technique as
    /// `AudioEngineController.performOfflineRender`), while remaining part of
    /// the same `Task` so `Task.checkCancellation()` observes the caller's
    /// cancellation. `engine` is a `@MainActor` type (implicitly `Sendable`);
    /// its one call here (`renderOffline`) is `await`-ed, which hops onto the
    /// main actor for that call only.
    nonisolated static func render(engine: AudioEngineController,
                                    imageName: String,
                                    timestamp: VHSTimestamp,
                                    config: Config = Config(),
                                    progress: @escaping @Sendable (RenderProgress) -> Void) async throws -> URL {
        progress(RenderProgress(phase: .tracking))
        try Task.checkCancellation()

        guard let uiImage = UIImage(named: imageName), let cgImage = uiImage.cgImage else {
            throw ClipRenderError.imageNotFound(imageName)
        }

        progress(RenderProgress(phase: .syncPulse))
        try Task.checkCancellation()

        let audioURL = try await engine.renderOffline(duration: config.duration,
                                                        fadeIn: config.fadeIn,
                                                        fadeOut: config.fadeOut) { fraction in
            progress(RenderProgress(phase: .buffering(fraction)))
        }

        do {
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            throw error
        }
        progress(RenderProgress(phase: .audioComplete))

        do {
            let outputURL = try await renderVideo(cgImage: cgImage,
                                                    timestamp: timestamp,
                                                    audioURL: audioURL,
                                                    config: config,
                                                    progress: progress)
            try? FileManager.default.removeItem(at: audioURL)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            throw error
        }
    }

    // MARK: Video pass

    private nonisolated static func renderVideo(cgImage: CGImage,
                                                  timestamp: VHSTimestamp,
                                                  audioURL: URL,
                                                  config: Config,
                                                  progress: @escaping @Sendable (RenderProgress) -> Void) async throws -> URL {
        let width = config.width
        let height = config.height
        let fps = config.fps
        let totalFrames = max(1, Int((config.duration * Double(fps)).rounded()))
        let fadeInFrames = max(0, Int((config.fadeIn * Double(fps)).rounded()))
        let fadeOutFrames = max(0, Int((config.fadeOut * Double(fps)).rounded()))

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiminalClip-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw ClipRenderError.writerInitFailed(error.localizedDescription)
        }

        let compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: 6_000_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProps,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                             sourcePixelBufferAttributes: pixelAttrs)

        guard writer.canAdd(videoInput) else {
            throw ClipRenderError.writerInitFailed("cannot add video input")
        }
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw ClipRenderError.writerInitFailed("cannot add audio input")
        }
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw ClipRenderError.writerFailed(writer.error?.localizedDescription ?? "unknown startWriting failure")
        }
        writer.startSession(atSourceTime: .zero)

        let asset = AVURLAsset(url: audioURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            writer.cancelWriting()
            throw ClipRenderError.audioReadFailed("no audio track in rendered CAF")
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            writer.cancelWriting()
            throw ClipRenderError.audioReadFailed(error.localizedDescription)
        }
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            writer.cancelWriting()
            throw ClipRenderError.audioReadFailed("cannot add reader output")
        }
        reader.add(readerOutput)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw ClipRenderError.audioReadFailed(reader.error?.localizedDescription ?? "unknown startReading failure")
        }

        let compositor = VHSFrameCompositor(baseImage: cgImage, timestamp: timestamp,
                                             width: width, height: height, fps: fps)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await pumpVideo(adaptor: adaptor, input: videoInput, compositor: compositor,
                                         totalFrames: totalFrames, fps: fps,
                                         fadeInFrames: fadeInFrames, fadeOutFrames: fadeOutFrames,
                                         progress: progress)
                }
                group.addTask {
                    try await pumpAudio(input: audioInput, readerOutput: readerOutput)
                }
                // Structured concurrency guarantees that if either child
                // throws, the group cancels and awaits the remaining child
                // before this call rethrows.
                try await group.waitForAll()
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        progress(RenderProgress(phase: .muxing))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            if writer.status == .cancelled {
                throw CancellationError()
            }
            throw ClipRenderError.writerFailed(writer.error?.localizedDescription ?? "unknown finishWriting failure")
        }
        return outputURL
    }

    private nonisolated static func pumpVideo(adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                                input: AVAssetWriterInput,
                                                compositor: VHSFrameCompositor,
                                                totalFrames: Int,
                                                fps: Int32,
                                                fadeInFrames: Int,
                                                fadeOutFrames: Int,
                                                progress: @escaping @Sendable (RenderProgress) -> Void) async throws {
        var frameIndex = 0
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        var lastReportedPct = -1

        while frameIndex < totalFrames {
            try Task.checkCancellation()

            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(nanoseconds: 2_000_000)
                continue
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw ClipRenderError.pixelBufferPoolFailed
            }
            var pixelBufferOut: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
            guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
                throw ClipRenderError.pixelBufferPoolFailed
            }

            let gain = fadeGain(frameIndex: frameIndex, totalFrames: totalFrames,
                                 fadeInFrames: fadeInFrames, fadeOutFrames: fadeOutFrames)
            compositor.render(frameIndex: frameIndex, gain: gain, into: pixelBuffer)

            let pts = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                throw ClipRenderError.writerFailed("appending video frame \(frameIndex) failed")
            }
            frameIndex += 1

            let pct = Int((Double(frameIndex) / Double(totalFrames)) * 100)
            if pct != lastReportedPct {
                lastReportedPct = pct
                progress(RenderProgress(phase: .video(Double(frameIndex) / Double(totalFrames))))
            }
        }
        input.markAsFinished()
    }

    private nonisolated static func pumpAudio(input: AVAssetWriterInput,
                                                readerOutput: AVAssetReaderTrackOutput) async throws {
        while true {
            try Task.checkCancellation()
            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(nanoseconds: 2_000_000)
                continue
            }
            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                break
            }
            guard input.append(sampleBuffer) else {
                throw ClipRenderError.writerFailed("appending audio sample failed")
            }
        }
        input.markAsFinished()
    }

    private nonisolated static func fadeGain(frameIndex: Int, totalFrames: Int,
                                              fadeInFrames: Int, fadeOutFrames: Int) -> Float {
        var gain: Float = 1
        if fadeInFrames > 0 && frameIndex < fadeInFrames {
            gain = min(gain, Float(frameIndex) / Float(fadeInFrames))
        }
        let fadeOutStart = totalFrames - fadeOutFrames
        if fadeOutFrames > 0 && frameIndex >= fadeOutStart {
            let remaining = totalFrames - frameIndex
            gain = min(gain, Float(max(0, remaining)) / Float(fadeOutFrames))
        }
        return gain
    }
}
