//
//  AutoRenderDebugHarness.swift
//  LiminalGenerator
//
//  DEBUG-only smoke-test hook for the render pipeline, launched via env
//  var "LG_AUTORENDER"="1" (optionally "LG_RENDER_SECONDS"="8" to render a
//  short clip instead of the full 120s, and "LG_AUTORENDER_DRUMS"="1" to
//  enable drums before rendering -- audio verification hook, DEBUG-only).
//  Drives `ClipRenderer` end-to-end with no UI interaction and prints
//  progress/result to stdout so it can be captured via `xcrun simctl launch
//  --console-pty` / `simctl spawn ... log stream`.
//
//  This lives entirely in Render/ (no edits to MainView/App files owned by
//  other agents). Swift disallows overriding the Objective-C `+load`/
//  `+initialize` hooks directly, so the pre-main entry point instead comes
//  from a tiny C constructor (`AutoRenderBootstrap.c`, `__attribute__((
//  constructor))`, run by dyld before `main()`) that calls this file's
//  `@_cdecl`-exported `lg_autorender_bootstrap()`. It never fires unless
//  the env var is explicitly set, so ordinary launches are unaffected.
//

#if DEBUG
import Foundation
import UIKit
import CoreImage
import CoreVideo

@_cdecl("lg_autorender_bootstrap")
func lg_autorender_bootstrap() {
    if ProcessInfo.processInfo.environment["LG_DEBUG_GLITCH_DUMP"] == "1" {
        Task { @MainActor in
            AutoRenderDebugHarness.runGlitchDump()
        }
        return
    }
    guard ProcessInfo.processInfo.environment["LG_AUTORENDER"] == "1" else { return }
    let seconds = ProcessInfo.processInfo.environment["LG_RENDER_SECONDS"].flatMap(Double.init) ?? 120
    Task { @MainActor in
        await AutoRenderDebugHarness.runAutoRender(seconds: seconds)
    }
}

enum AutoRenderDebugHarness {
    /// Renders frames directly through `VHSFrameCompositor` (bypassing
    /// AVAssetWriter/H.264 entirely) until the tracking-glitch band fires,
    /// then dumps that raw composited frame straight to PNG -- used to
    /// determine whether a visual defect originates in the Core Image
    /// pipeline itself or downstream in video encoding.
    @MainActor
    static func runGlitchDump() {
        print("[LG_GLITCH_DUMP] starting")
        let width = 848, height = 848
        let fps: Int32 = 30
        guard let uiImage = UIImage(named: ImageLibrary[0].assetName), let cgImage = uiImage.cgImage else {
            print("[LG_GLITCH_DUMP] FAILURE could not load base image")
            return
        }
        let timestamp = VHSTimestamp.random()
        let compositor = VHSFrameCompositor(baseImage: cgImage, timestamp: timestamp, width: width, height: height, fps: fps)

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, pixelAttrs as CFDictionary, &pool)
        guard let pool else {
            print("[LG_GLITCH_DUMP] FAILURE could not create pixel buffer pool")
            return
        }

        let ciContext = CIContext(options: nil)
        var dumped = false
        for frameIndex in 0..<600 where !dumped {
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { continue }
            compositor.render(frameIndex: frameIndex, gain: 1.0, into: pb)
            if compositor.debugGlitchActive {
                let ciImage = CIImage(cvPixelBuffer: pb)
                if let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                    let outImage = UIImage(cgImage: cg)
                    if let data = outImage.pngData() {
                        let path = FileManager.default.temporaryDirectory.appendingPathComponent("glitch_raw_dump.png")
                        try? data.write(to: path)
                        print("[LG_GLITCH_DUMP] SUCCESS frame=\(frameIndex) path=\(path.path)")
                    } else {
                        print("[LG_GLITCH_DUMP] FAILURE pngData nil at frame=\(frameIndex)")
                    }
                } else {
                    print("[LG_GLITCH_DUMP] FAILURE createCGImage nil at frame=\(frameIndex)")
                }
                dumped = true
            }
        }
        if !dumped {
            print("[LG_GLITCH_DUMP] FAILURE no glitch fired within 600 frames")
        }
    }

    @MainActor
    static func runAutoRender(seconds: Double) async {
        print("[LG_AUTORENDER] starting harness duration=\(seconds)s")

        let engine = AudioEngineController()
        if ProcessInfo.processInfo.environment["LG_AUTORENDER_DRUMS"] == "1" {
            engine.drumsEnabled = true
            print("[LG_AUTORENDER] drums enabled via LG_AUTORENDER_DRUMS, loop=\(engine.currentBeat.displayName) bpm=\(engine.currentBeat.bpm)")
        }
        let imageName = ImageLibrary[Int.random(in: 0..<ImageLibrary.count)].assetName
        let timestamp = VHSTimestamp.random()
        let config = ClipRenderer.Config(duration: seconds,
                                          fadeIn: min(3, seconds * 0.25),
                                          fadeOut: min(5, seconds * 0.4))

        let start = Date()
        do {
            let url = try await ClipRenderer.render(engine: engine,
                                                      imageName: imageName,
                                                      timestamp: timestamp,
                                                      config: config) { event in
                print("[LG_AUTORENDER] phase=\(event.phase)")
            }
            let elapsed = Date().timeIntervalSince(start)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            print("[LG_AUTORENDER] SUCCESS path=\(url.path) sizeBytes=\(size) elapsedSeconds=\(elapsed)")

            // Exercise the exact share-sheet thumbnail code path
            // (ShareThumbnailGenerator + VideoShareItem's LPLinkMetadata)
            // against the real rendered file, so this smoke test verifies
            // more than "a video was written".
            if let thumbnail = await ShareThumbnailGenerator.generate(for: url) {
                let meanLuma = Self.meanLuminance(of: thumbnail)
                print("[LG_AUTORENDER] THUMBNAIL ok size=\(thumbnail.size) meanLuma=\(meanLuma)")
                let item = VideoShareItem(url: url, thumbnail: thumbnail)
                let metadata = item.activityViewControllerLinkMetadata(UIActivityViewController(activityItems: [url], applicationActivities: nil))
                print("[LG_AUTORENDER] METADATA title=\(metadata?.title ?? "nil") imageProviderNonNil=\(metadata?.imageProvider != nil)")
            } else {
                print("[LG_AUTORENDER] THUMBNAIL FAILED (nil)")
            }
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            print("[LG_AUTORENDER] FAILURE error=\(error) elapsedSeconds=\(elapsed)")
        }
    }

    /// Average of the 0...255 luma of every pixel in `image` -- used by the
    /// smoke test to confirm the mid-clip share thumbnail is a real frame
    /// (well above black), not an accidental capture of the fade-in.
    static func meanLuminance(of image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return -1 }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return -1 }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: width * 4, space: colorSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return -1
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var total: Double = 0
        let count = width * height
        for i in 0..<count {
            let o = i * 4
            let r = Double(pixels[o])
            let g = Double(pixels[o + 1])
            let b = Double(pixels[o + 2])
            total += 0.299 * r + 0.587 * g + 0.114 * b
        }
        return total / Double(count)
    }
}
#endif
