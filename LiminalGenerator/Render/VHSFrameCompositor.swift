//
//  VHSFrameCompositor.swift
//  LiminalGenerator
//
//  Per-frame video compositor for ClipRenderer. Visually matches the live
//  Metal shader (UI/VHSShader.metal): 3-tap edge-weighted chroma
//  aberration, sine scanlines, luma grain, vignette, an occasional
//  vertically-sweeping tracking-glitch band, plus the baked VCR OSD
//  (timestamp/REC/SP) and a bottom-right "LIMINAL GENERATOR" watermark,
//  all composited with Core Image.
//
//  Intensity parameters below implement the PINNED targets from SPEC.md
//  Addendum 5 item 5 (shared with the live Metal shader so live playback
//  and the rendered MP4 read as the same look):
//    - scanlines: ~0.18 strength, ~2px period @848px, ±20% temporal
//      modulation
//    - grain: animated luma noise, amplitude ~0.06-0.09, refreshed per
//      frame
//    - tracking glitch: ~20-40px band @848px, sweeping vertically over
//      ~0.2-0.4s, every ~4-9s (randomized, seeded once per render instance
//      so different renders get different -- but reproducible -- timing)
//    - chroma aberration: edge magnitude +~50% vs the previous build
//    - chroma bleed: subtle overall desaturation + soft color smear
//    - vignette: unchanged
//
//  Performance: everything that does NOT depend on time or frame content
//  (chroma aberration, chroma bleed/desaturation, vignette) is baked into
//  a single flat `baseImage` bitmap exactly once in `init`. The scanline
//  pattern is also shaped once (its *strength* is modulated per frame via
//  a single cheap colorMatrix pass, not re-shaped). The watermark is drawn
//  once (its text never changes) and composited pre-fade every frame so it
//  fades to black with the rest of the picture. Each of the (up to) 3600
//  output frames then only pays for: a translated sample of a pre-baked
//  noise field (grain), a scalar-modulated multiply of the pre-baked
//  scanline pattern, an occasional cheap strip-shift + noise boost
//  (tracking glitch, only active ~6-12 frames every few seconds), a cached
//  OSD bitmap keyed by (second, blink-state) instead of a fresh Core Text
//  layout per frame, a static watermark composite, and a fade gain.
//
//  Single-writer usage: `render(frameIndex:gain:into:)` is only ever
//  called sequentially, in increasing frame order, from ClipRenderer's
//  video pump task -- never concurrently -- so the small mutable state
//  used for the tracking-glitch state machine and the OSD cache is safe
//  without extra synchronization. `@unchecked Sendable` documents that
//  contract (same pattern as `AudioEngineController`'s
//  `InterleavedScratch`).
//

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import UIKit
import Metal

final class VHSFrameCompositor: @unchecked Sendable {
    private let width: Int
    private let height: Int
    private let fps: Int32
    private let context: CIContext

    private let baseImage: CIImage
    private let baseExtent: CGRect
    private let noiseField: CIImage
    private let noiseFieldSize: CGSize
    private let scanlinePattern: CIImage
    private let watermarkImage: CIImage

    private let timestamp: VHSTimestamp
    private let startHour12: Int
    private let startMinute: Int
    private let startSecond: Int
    private let startIsPM: Bool

    private var osdCache: [Int: CIImage] = [:]

    // Tracking-glitch state machine (mutated sequentially, see header
    // note). Seeded once per render instance so repeated renders don't all
    // glitch at identical wall-clock offsets, while staying fully
    // deterministic/reproducible for a given seed.
    private var glitchGen: SplitMix64
    private var nextGlitchFrame: Int
    private var glitchActive = false
    private var glitchStartFrame = 0
    private var glitchDurationFrames = 0
    private var glitchBandHeight: CGFloat = 0
    private var glitchStartY: CGFloat = 0
    private var glitchEndY: CGFloat = 0
    private var glitchOffsetX: CGFloat = 0

    init(baseImage cgImage: CGImage, timestamp: VHSTimestamp, width: Int, height: Int, fps: Int32) {
        self.width = width
        self.height = height
        self.fps = fps
        self.timestamp = timestamp

        if let device = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: device)
        } else {
            self.context = CIContext(options: nil)
        }

        let targetSize = CGSize(width: width, height: height)
        self.baseExtent = CGRect(origin: .zero, size: targetSize)

        let source = CIImage(cgImage: cgImage)
        self.baseImage = Self.buildProcessedBase(source: source, targetSize: targetSize, context: context)
        self.scanlinePattern = Self.buildScanlinePattern(size: targetSize)
        if let wmCG = Self.drawWatermark(size: targetSize) {
            self.watermarkImage = CIImage(cgImage: wmCG)
        } else {
            self.watermarkImage = CIImage.empty()
        }

        let margin: CGFloat = 256
        let fieldSize = CGSize(width: targetSize.width + margin * 2, height: targetSize.height + margin * 2)
        self.noiseFieldSize = fieldSize
        let randomGen = CIFilter.randomGenerator()
        let cropped = (randomGen.outputImage ?? CIImage.empty()).cropped(to: CGRect(origin: .zero, size: fieldSize))
        if let cg = context.createCGImage(cropped, from: cropped.extent) {
            self.noiseField = CIImage(cgImage: cg)
        } else {
            self.noiseField = cropped
        }

        // Parse "H:MM:SS AM/PM" into components so the OSD clock can tick
        // forward across the clip's duration.
        let parts = timestamp.timeText.split(separator: " ")
        let isPM = parts.count > 1 && parts[1] == "PM"
        let hms = (parts.first.map(String.init) ?? "12:00:00").split(separator: ":").compactMap { Int($0) }
        startHour12 = hms.count > 0 ? hms[0] : 12
        startMinute = hms.count > 1 ? hms[1] : 0
        startSecond = hms.count > 2 ? hms[2] : 0
        startIsPM = isPM

        // Tracking-glitch schedule: a fresh random seed per render instance
        // (from the system RNG), then every subsequent decision comes from
        // that seeded, allocation-free generator so timing is reproducible
        // for a given seed and safe to mutate without synchronization.
        var seedSource = SystemRandomNumberGenerator()
        let renderSeed = UInt64.random(in: UInt64.min...UInt64.max, using: &seedSource)
        var gen = SplitMix64(seed: renderSeed)
        let firstIntervalSeconds = Self.randomInterval(4...9, gen: &gen)
        self.nextGlitchFrame = Int((firstIntervalSeconds * Double(fps)).rounded())
        self.glitchGen = gen
    }

    #if DEBUG
    /// Exposed only for `AutoRenderDebugHarness`'s direct pixel-buffer
    /// verification (bypassing H.264 encoding) of the tracking-glitch band.
    var debugGlitchActive: Bool { glitchActive }
    #endif

    // MARK: - Per-frame render

    func render(frameIndex: Int, gain: Float, into pixelBuffer: CVPixelBuffer) {
        let elapsedSeconds = Int(Double(frameIndex) / Double(fps))
        let blinkWindow = max(1, Int(fps) / 2)
        let recOn = (frameIndex / blinkWindow) % 2 == 0

        var frame = baseImage

        frame = applyScanlines(to: frame, frameIndex: frameIndex)
        frame = applyGrain(to: frame, frameIndex: frameIndex)

        updateTrackingGlitch(frameIndex: frameIndex)
        if glitchActive {
            frame = applyTrackingGlitch(to: frame, frameIndex: frameIndex)
        }

        let osd = cachedOSD(elapsedSeconds: elapsedSeconds, recOn: recOn)
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = osd
        over.backgroundImage = frame
        frame = (over.outputImage ?? frame).cropped(to: baseExtent)

        // Watermark: composited pre-fade (like the OSD) so it fades to
        // black with the rest of the picture instead of surviving over a
        // pure-black lead-in/out.
        let wmOver = CIFilter.sourceOverCompositing()
        wmOver.inputImage = watermarkImage
        wmOver.backgroundImage = frame
        frame = (wmOver.outputImage ?? frame).cropped(to: baseExtent)

        if gain < 1 {
            let g = CGFloat(max(0, gain))
            let fade = CIFilter.colorMatrix()
            fade.inputImage = frame
            fade.rVector = CIVector(x: g, y: 0, z: 0, w: 0)
            fade.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
            fade.bVector = CIVector(x: 0, y: 0, z: g, w: 0)
            fade.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            frame = (fade.outputImage ?? frame).cropped(to: baseExtent)
        }

        context.render(frame, to: pixelBuffer)
    }

    // MARK: - Static base pass (chroma aberration + chroma bleed + vignette)

    private static func buildProcessedBase(source: CIImage, targetSize: CGSize, context: CIContext) -> CIImage {
        let filled = aspectFill(source, to: targetSize)
        let aberrated = applyChromaAberration(filled, size: targetSize)
        let bled = applyChromaBleed(aberrated, size: targetSize)
        let vignetted = applyVignette(bled, size: targetSize)

        // Materialize once: everything above is time-invariant across the
        // whole clip, so the (multi-pass) filter graph cost is paid a
        // single time here, not per output frame.
        let rect = CGRect(origin: .zero, size: targetSize)
        guard let cg = context.createCGImage(vignetted, from: rect) else {
            return vignetted
        }
        return CIImage(cgImage: cg)
    }

    private static func aspectFill(_ image: CIImage, to size: CGSize) -> CIImage {
        let srcExtent = image.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else { return image }
        let scale = max(size.width / srcExtent.width, size.height / srcExtent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let dx = scaledExtent.origin.x + (scaledExtent.width - size.width) / 2
        let dy = scaledExtent.origin.y + (scaledExtent.height - size.height) / 2
        let cropRect = CGRect(x: dx, y: dy, width: size.width, height: size.height)
        return scaled.cropped(to: cropRect).transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
    }

    /// 3-tap channel-split chroma aberration, blended back toward the
    /// unshifted original near the horizontal center -- an offline analog
    /// of the live shader's per-pixel edge falloff. Edge magnitude is
    /// pinned +~50% vs the previous build (3.0px -> 4.5px offset).
    private static func applyChromaAberration(_ image: CIImage, size: CGSize) -> CIImage {
        let extent = CGRect(origin: .zero, size: size)
        let offset: CGFloat = 4.5

        func isolate(_ img: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
            let m = CIFilter.colorMatrix()
            m.inputImage = img
            m.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return m.outputImage ?? img
        }

        let redOnly = isolate(image, r: 1, g: 0, b: 0)
            .transformed(by: CGAffineTransform(translationX: offset, y: 0))
        let greenOnly = isolate(image, r: 0, g: 1, b: 0)
        let blueOnly = isolate(image, r: 0, g: 0, b: 1)
            .transformed(by: CGAffineTransform(translationX: -offset, y: 0))

        let add1 = CIFilter.additionCompositing()
        add1.inputImage = redOnly
        add1.backgroundImage = greenOnly
        let rg = (add1.outputImage ?? greenOnly).cropped(to: extent)

        let add2 = CIFilter.additionCompositing()
        add2.inputImage = blueOnly
        add2.backgroundImage = rg
        let aberrated = (add2.outputImage ?? rg).cropped(to: extent)

        // Edge-weight mask: 0 (show original) at the horizontal center,
        // ramping to 1 (show aberrated) toward the left/right edges.
        let leftGradient = CIFilter.smoothLinearGradient()
        leftGradient.point0 = CGPoint(x: size.width * 0.5, y: 0)
        leftGradient.point1 = CGPoint(x: 0, y: 0)
        leftGradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        leftGradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let leftHalf = (leftGradient.outputImage ?? CIImage.empty())
            .cropped(to: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))

        let rightGradient = CIFilter.smoothLinearGradient()
        rightGradient.point0 = CGPoint(x: size.width * 0.5, y: 0)
        rightGradient.point1 = CGPoint(x: size.width, y: 0)
        rightGradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        rightGradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let rightHalf = (rightGradient.outputImage ?? CIImage.empty())
            .cropped(to: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))

        let combineMask = CIFilter.sourceOverCompositing()
        combineMask.inputImage = rightHalf
        combineMask.backgroundImage = leftHalf
        let mask = (combineMask.outputImage ?? leftHalf).cropped(to: extent)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = aberrated
        blend.backgroundImage = image
        blend.maskImage = mask
        return (blend.outputImage ?? aberrated).cropped(to: extent)
    }

    /// Subtle overall chroma desaturation + a soft, low-opacity blurred
    /// blend back on top -- classic VHS "color softness"/bleed: color
    /// detail smears a touch while luma (from the sharp layer beneath)
    /// stays legible. Time-invariant, so baked into the static base.
    private static func applyChromaBleed(_ image: CIImage, size: CGSize) -> CIImage {
        let extent = CGRect(origin: .zero, size: size)

        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.saturation = 0.88
        controls.brightness = 0
        controls.contrast = 1.0
        let desaturated = (controls.outputImage ?? image).cropped(to: extent)

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = desaturated
        blur.radius = 1.4
        let blurred = (blur.outputImage ?? desaturated).cropped(to: extent)

        // Force a constant, low alpha on the blurred copy regardless of its
        // own alpha channel, then lay it over the sharp desaturated image.
        let alphaMatrix = CIFilter.colorMatrix()
        alphaMatrix.inputImage = blurred
        alphaMatrix.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        alphaMatrix.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        alphaMatrix.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        alphaMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        alphaMatrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0.35)
        let translucentBlur = (alphaMatrix.outputImage ?? blurred).cropped(to: extent)

        let over = CIFilter.sourceOverCompositing()
        over.inputImage = translucentBlur
        over.backgroundImage = desaturated
        return (over.outputImage ?? desaturated).cropped(to: extent)
    }

    /// Radial darkening toward the corners, matching the live shader's
    /// `smoothstep(0.95, 0.35, dist) -> mix(0.55, 1.0, vig)`. Pinned as
    /// unchanged.
    private static func applyVignette(_ image: CIImage, size: CGSize) -> CIImage {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxDist = hypot(size.width, size.height) / 2
        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(maxDist * 0.35)
        gradient.radius1 = Float(maxDist * 0.95)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        gradient.color1 = CIColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1)
        guard let vignette = gradient.outputImage?.cropped(to: CGRect(origin: .zero, size: size)) else {
            return image
        }
        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = vignette
        multiply.backgroundImage = image
        return (multiply.outputImage ?? image).cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: - Scanlines (shape baked once, strength modulated per frame)

    /// Precomputes the scanline brightness pattern at the pinned nominal
    /// strength (~0.18) and ~2px period at the 848px reference frame
    /// height (`sin(y * pi)`), as a 1px-wide column stretched horizontally
    /// (each row is a constant brightness, so stretching a single column
    /// tiles it perfectly). Stored as a full-strength "shape" image;
    /// `applyScanlines` cheaply rescales its deviation from 1.0 per frame
    /// to get the pinned ±20% temporal modulation without re-rasterizing.
    private static func buildScanlinePattern(size: CGSize) -> CIImage {
        let height = max(1, Int(size.height.rounded()))
        var pixels = [UInt8](repeating: 255, count: height * 4)
        let baseStrength = 0.18
        let frequency = Double.pi // 2*pi / 2px period
        for y in 0..<height {
            let scan = sin(Double(y) * frequency) * 0.5 + 0.5
            let mult = 1.0 - baseStrength * (1.0 - scan)
            let v = UInt8(max(0, min(255, (mult * 255).rounded())))
            pixels[y * 4 + 0] = v
            pixels[y * 4 + 1] = v
            pixels[y * 4 + 2] = v
            pixels[y * 4 + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: 1, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                                space: colorSpace,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            return CIImage.empty()
        }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: size.width, y: 1))
    }

    /// Rescales the precomputed pattern's deviation from 1.0 by a slowly
    /// oscillating factor `k` in [0.8, 1.2] (±20%), then multiplies it into
    /// the frame. `mult_t = 1 - k*(1 - mult0)` is affine in `mult0`, so a
    /// single per-frame colorMatrix does the modulation cheaply -- no
    /// re-rasterizing the sine pattern every frame.
    private func applyScanlines(to image: CIImage, frameIndex: Int) -> CIImage {
        let modPeriodFrames = Double(fps) * 4.0 // slow ~4s modulation cycle
        let phase = 2.0 * Double.pi * Double(frameIndex) / modPeriodFrames
        let k = CGFloat(1.0 + 0.2 * sin(phase))

        let modulate = CIFilter.colorMatrix()
        modulate.inputImage = scanlinePattern
        modulate.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        modulate.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
        modulate.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
        modulate.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        modulate.biasVector = CIVector(x: 1 - k, y: 1 - k, z: 1 - k, w: 0)
        let modulated = (modulate.outputImage ?? scanlinePattern).cropped(to: baseExtent)

        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = modulated
        multiply.backgroundImage = image
        return (multiply.outputImage ?? image).cropped(to: baseExtent)
    }

    // MARK: - Per-frame varying parts

    private func applyGrain(to image: CIImage, frameIndex: Int) -> CIImage {
        let maxDX = max(0, noiseFieldSize.width - CGFloat(width))
        let maxDY = max(0, noiseFieldSize.height - CGFloat(height))
        var gen = SplitMix64(seed: UInt64(bitPattern: Int64(frameIndex &* 2_654_435_761 &+ 1_013_904_223)))
        let dx = CGFloat(gen.nextUnit()) * maxDX
        let dy = CGFloat(gen.nextUnit()) * maxDY

        let window = noiseField
            .transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
            .cropped(to: baseExtent)

        // Pinned amplitude ~0.06-0.09; refreshed every frame via the
        // frame-indexed seed above (a fresh window of the pre-baked noise
        // field each frame reads as animated grain without regenerating
        // random noise per pixel per frame).
        let strength: CGFloat = 0.019
        let recentered = CIFilter.colorMatrix()
        recentered.inputImage = window
        recentered.rVector = CIVector(x: strength, y: 0, z: 0, w: 0)
        recentered.gVector = CIVector(x: 0, y: strength, z: 0, w: 0)
        recentered.bVector = CIVector(x: 0, y: 0, z: strength, w: 0)
        recentered.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        recentered.biasVector = CIVector(x: -strength / 2, y: -strength / 2, z: -strength / 2, w: 1)
        let grainLayer = (recentered.outputImage ?? window).cropped(to: baseExtent)

        let add = CIFilter.additionCompositing()
        add.inputImage = grainLayer
        add.backgroundImage = image
        return (add.outputImage ?? image).cropped(to: baseExtent)
    }

    // MARK: - Tracking glitch (~4-9s cadence, ~20-40px band, sweeps for ~0.2-0.4s)

    private static func randomInterval(_ range: ClosedRange<Double>, gen: inout SplitMix64) -> Double {
        range.lowerBound + gen.nextUnit() * (range.upperBound - range.lowerBound)
    }

    private func updateTrackingGlitch(frameIndex: Int) {
        if glitchActive {
            let elapsed = frameIndex - glitchStartFrame
            if elapsed >= glitchDurationFrames {
                glitchActive = false
                let intervalSeconds = Self.randomInterval(4...9, gen: &glitchGen)
                nextGlitchFrame = frameIndex + max(1, Int((intervalSeconds * Double(fps)).rounded()))
            }
            return
        }
        guard frameIndex >= nextGlitchFrame else { return }

        glitchActive = true
        glitchStartFrame = frameIndex
        let durationSeconds = Self.randomInterval(0.2...0.4, gen: &glitchGen)
        glitchDurationFrames = max(1, Int((durationSeconds * Double(fps)).rounded()))

        let referenceScale = CGFloat(height) / 848.0
        glitchBandHeight = CGFloat(Self.randomInterval(20...40, gen: &glitchGen)) * referenceScale
        glitchStartY = CGFloat(glitchGen.nextUnit()) * CGFloat(height)
        let sweep = CGFloat(height) * 0.3
        glitchEndY = min(CGFloat(height), max(0, glitchStartY + CGFloat(glitchGen.nextUnit() - 0.5) * 2 * sweep))
        glitchOffsetX = CGFloat(glitchGen.nextUnit() - 0.5) * 56 * referenceScale

        #if DEBUG
        print("[VHS_GLITCH] startFrame=\(frameIndex) durationFrames=\(glitchDurationFrames) " +
              "bandHeight=\(glitchBandHeight) startY=\(glitchStartY) endY=\(glitchEndY) offsetX=\(glitchOffsetX)")
        #endif
    }

    /// A vertically-sweeping band of displaced, brightened, noise-boosted
    /// pixels -- reads as a tracking error rolling through the frame
    /// rather than a static glitch.
    private func applyTrackingGlitch(to image: CIImage, frameIndex: Int) -> CIImage {
        let elapsed = frameIndex - glitchStartFrame
        let progress = glitchDurationFrames > 1 ? CGFloat(elapsed) / CGFloat(glitchDurationFrames - 1) : 0
        let centerY = glitchStartY + (glitchEndY - glitchStartY) * progress
        let bandRect = CGRect(x: 0, y: max(0, centerY - glitchBandHeight / 2),
                               width: CGFloat(width), height: glitchBandHeight).intersection(baseExtent)
        guard !bandRect.isEmpty else { return image }

        // Materialize the incoming frame to a flat bitmap first. Compositing
        // a *crop of `image`* back over `image` itself -- while both still
        // reference the same lazy Core Image graph node -- was found (via
        // direct pixel-buffer bisection, bypassing H.264 entirely) to
        // corrupt to solid black for the cropped region on-device, even
        // with zero color adjustment and zero transform. Rendering to a
        // CGImage and rewrapping breaks that self-reference; this only
        // runs on the rare handful of frames where the glitch is actually
        // active (a few frames every several seconds), so the extra
        // readback is negligible against the render budget.
        guard let materializedCG = context.createCGImage(image, from: baseExtent) else { return image }
        let materialized = CIImage(cgImage: materializedCG)

        let bandContent = materialized.cropped(to: bandRect)

        let brighten = CIFilter.colorMatrix()
        brighten.inputImage = bandContent
        let boost: CGFloat = 1.28
        brighten.rVector = CIVector(x: boost, y: 0, z: 0, w: 0)
        brighten.gVector = CIVector(x: 0, y: boost, z: 0, w: 0)
        brighten.bVector = CIVector(x: 0, y: 0, z: boost, w: 0)
        brighten.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        brighten.biasVector = CIVector(x: 0.03, y: 0.03, z: 0.03, w: 0)
        let brightened = (brighten.outputImage ?? bandContent).cropped(to: bandRect)

        // Extra brightened noise within the band, sampled from the
        // pre-baked noise field at a stronger amplitude than ordinary
        // grain, so the sweep reads as "hot" tracking-error smear.
        let maxDX = max(0, noiseFieldSize.width - CGFloat(width))
        let maxDY = max(0, noiseFieldSize.height - CGFloat(height))
        var extraGen = SplitMix64(seed: UInt64(bitPattern: Int64(frameIndex &* 40_503 &+ 111)))
        let ndx = CGFloat(extraGen.nextUnit()) * maxDX
        let ndy = CGFloat(extraGen.nextUnit()) * maxDY
        let extraNoise = noiseField
            .transformed(by: CGAffineTransform(translationX: -ndx, y: -ndy))
            .cropped(to: bandRect)

        let noiseBoost = CIFilter.colorMatrix()
        noiseBoost.inputImage = extraNoise
        let ns: CGFloat = 0.16
        noiseBoost.rVector = CIVector(x: ns, y: 0, z: 0, w: 0)
        noiseBoost.gVector = CIVector(x: 0, y: ns, z: 0, w: 0)
        noiseBoost.bVector = CIVector(x: 0, y: 0, z: ns, w: 0)
        noiseBoost.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        noiseBoost.biasVector = CIVector(x: -ns / 2, y: -ns / 2, z: -ns / 2, w: 1)
        let noiseLayer = (noiseBoost.outputImage ?? extraNoise).cropped(to: bandRect)

        let addNoise = CIFilter.additionCompositing()
        addNoise.inputImage = noiseLayer
        addNoise.backgroundImage = brightened
        let hotBand = (addNoise.outputImage ?? brightened).cropped(to: bandRect)

        let shifted = hotBand.transformed(by: CGAffineTransform(translationX: glitchOffsetX, y: 0))
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = shifted
        over.backgroundImage = materialized
        return (over.outputImage ?? materialized).cropped(to: baseExtent)
    }

    // MARK: - OSD (cached per distinct second / blink state)

    private func cachedOSD(elapsedSeconds: Int, recOn: Bool) -> CIImage {
        let key = elapsedSeconds * 2 + (recOn ? 1 : 0)
        if let cached = osdCache[key] { return cached }
        let cg = Self.drawOSD(dateText: timestamp.dateText,
                               timeText: tickedTimeText(elapsedSeconds: elapsedSeconds),
                               recOn: recOn,
                               size: CGSize(width: width, height: height))
        let image = CIImage(cgImage: cg)
        osdCache[key] = image
        return image
    }

    private func tickedTimeText(elapsedSeconds: Int) -> String {
        let secondsPerHalfDay = 12 * 3600
        let base = (startHour12 % 12) * 3600 + startMinute * 60 + startSecond
        var total = base + elapsedSeconds
        let pmFlips = total / secondsPerHalfDay
        total %= secondsPerHalfDay
        var hour = total / 3600
        let minute = (total % 3600) / 60
        let second = total % 60
        if hour == 0 { hour = 12 }
        var isPM = startIsPM
        if pmFlips % 2 == 1 { isPM.toggle() }
        return String(format: "%d:%02d:%02d %@", hour, minute, second, isPM ? "PM" : "AM")
    }

    private static func drawOSD(dateText: String, timeText: String, recOn: Bool, size: CGSize) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let image = renderer.image { rendererContext in
            let cg = rendererContext.cgContext
            let margin: CGFloat = size.width * 0.028
            let dateFont = UIFont(name: "SpaceMono-Bold", size: size.width * 0.032)
                ?? UIFont.monospacedSystemFont(ofSize: size.width * 0.032, weight: .bold)
            let bodyFont = UIFont(name: "SpaceMono-Regular", size: size.width * 0.030)
                ?? UIFont.monospacedSystemFont(ofSize: size.width * 0.030, weight: .regular)
            let osdColor = UIColor(red: 0.933, green: 1.0, blue: 0.894, alpha: 1.0) // liminalPrimary
            let recColor = UIColor(red: 1.0, green: 0.706, blue: 0.671, alpha: 1.0) // liminalError

            func drawGlow(_ text: String, font: UIFont, color: UIColor, origin: CGPoint, alignRight: Bool = false) -> CGSize {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let str = NSAttributedString(string: text, attributes: attrs)
                let measured = str.size()
                let drawOrigin = alignRight ? CGPoint(x: origin.x - measured.width, y: origin.y) : origin
                cg.saveGState()
                cg.setShadow(offset: .zero, blur: size.width * 0.014, color: color.withAlphaComponent(0.85).cgColor)
                str.draw(at: drawOrigin)
                cg.restoreGState()
                return measured
            }

            // Top-left: date, then REC dot + label beneath, then the
            // ticking time as a third line.
            let dateSize = drawGlow(dateText, font: dateFont, color: osdColor, origin: CGPoint(x: margin, y: margin))
            let recY = margin + dateSize.height + size.height * 0.010

            if recOn {
                let dotDiameter = size.width * 0.020
                cg.saveGState()
                cg.setFillColor(UIColor(red: 1, green: 0.2, blue: 0.2, alpha: 1).cgColor)
                cg.setShadow(offset: .zero, blur: size.width * 0.014, color: UIColor.red.withAlphaComponent(0.9).cgColor)
                cg.fillEllipse(in: CGRect(x: margin, y: recY + dotDiameter * 0.15, width: dotDiameter, height: dotDiameter))
                cg.restoreGState()
                _ = drawGlow("REC", font: bodyFont, color: recColor,
                             origin: CGPoint(x: margin + dotDiameter + size.width * 0.012, y: recY))
            }

            let timeY = recY + size.height * 0.032
            _ = drawGlow(timeText, font: bodyFont, color: osdColor, origin: CGPoint(x: margin, y: timeY))

            // Top-right: SP
            _ = drawGlow("SP", font: bodyFont, color: osdColor, origin: CGPoint(x: size.width - margin, y: margin), alignRight: true)
        }

        if let cg = image.cgImage {
            return cg
        }
        // Extremely unlikely fallback: a blank transparent frame-sized image.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)),
                             bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx!.makeImage()!
    }

    // MARK: - Watermark (baked once; static text, composited pre-fade every frame)

    /// "LIMINAL GENERATOR" in Space Mono, bottom-right, ~3.5% of frame
    /// height, off-white with the same glow treatment as the OSD, ~80%
    /// opacity, safe-margined the same as the other OSD elements. Drawn
    /// once in `init` since the text never changes across the clip.
    private static func drawWatermark(size: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let image = renderer.image { rendererContext in
            let cg = rendererContext.cgContext
            let margin: CGFloat = size.width * 0.028
            let fontSize = size.height * 0.035
            let font = UIFont(name: "SpaceMono-Bold", size: fontSize)
                ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
            let color = UIColor(red: 0.933, green: 1.0, blue: 0.894, alpha: 0.8) // liminalPrimary @ ~80%
            let text = "LIMINAL GENERATOR"

            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let str = NSAttributedString(string: text, attributes: attrs)
            let measured = str.size()
            let origin = CGPoint(x: size.width - margin - measured.width, y: size.height - margin - measured.height)

            cg.saveGState()
            cg.setShadow(offset: .zero, blur: size.width * 0.014, color: color.withAlphaComponent(0.85).cgColor)
            str.draw(at: origin)
            cg.restoreGState()
        }
        return image.cgImage
    }
}

// MARK: - Cheap deterministic per-frame RNG

/// SplitMix64: fast, allocation-free, deterministic given a seed -- used so
/// each frame's "randomness" (grain sample offset, tracking-glitch
/// decisions) is reproducible and safe to compute without any shared
/// mutable RNG state across frames.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
