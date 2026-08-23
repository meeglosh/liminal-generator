//
//  VHSFrameCompositor.swift
//  LiminalGenerator
//
//  Per-frame video compositor for ClipRenderer. Visually matches the live
//  Metal shader (UI/VHSShader.metal): 3-tap edge-weighted chroma
//  aberration, sine scanlines, luma grain, vignette, an occasional
//  horizontal tracking-jitter band, plus the baked VCR OSD (timestamp/
//  REC/SP), all composited with Core Image.
//
//  Performance: everything in the live shader that does NOT depend on
//  time or frame content (chroma aberration, scanlines, vignette) is baked
//  into a single flat `baseImage` bitmap exactly once in `init`. Each of
//  the (up to) 3600 output frames then only pays for the cheap
//  time-varying parts: a translated sample of a pre-baked noise field
//  (grain), an occasional cheap strip-shift (tracking band), a cached OSD
//  bitmap keyed by (second, blink-state) instead of a fresh Core Text
//  layout per frame, and a fade gain.
//
//  Single-writer usage: `render(frameIndex:gain:into:)` is only ever
//  called sequentially, in increasing frame order, from ClipRenderer's
//  video pump task -- never concurrently -- so the small mutable state
//  used for the tracking-band state machine and the OSD cache is safe
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

    private let timestamp: VHSTimestamp
    private let startHour12: Int
    private let startMinute: Int
    private let startSecond: Int
    private let startIsPM: Bool

    private var osdCache: [Int: CIImage] = [:]

    // Tracking-band state machine (mutated sequentially, see header note).
    private var trackingBandFramesRemaining = 0
    private var trackingBandCenterY: CGFloat = 0
    private var trackingBandOffsetX: CGFloat = 0

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
    }

    // MARK: - Per-frame render

    func render(frameIndex: Int, gain: Float, into pixelBuffer: CVPixelBuffer) {
        let elapsedSeconds = Int(Double(frameIndex) / Double(fps))
        let blinkWindow = max(1, Int(fps) / 2)
        let recOn = (frameIndex / blinkWindow) % 2 == 0

        var frame = baseImage

        frame = applyGrain(to: frame, frameIndex: frameIndex)

        updateTrackingBandState(frameIndex: frameIndex)
        if trackingBandFramesRemaining > 0 {
            frame = applyTrackingBand(to: frame)
        }

        let osd = cachedOSD(elapsedSeconds: elapsedSeconds, recOn: recOn)
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = osd
        over.backgroundImage = frame
        frame = (over.outputImage ?? frame).cropped(to: baseExtent)

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

    // MARK: - Static base pass (chroma aberration + scanlines + vignette)

    private static func buildProcessedBase(source: CIImage, targetSize: CGSize, context: CIContext) -> CIImage {
        let filled = aspectFill(source, to: targetSize)
        let aberrated = applyChromaAberration(filled, size: targetSize)
        let scanlined = applyScanlines(aberrated, size: targetSize)
        let vignetted = applyVignette(scanlined, size: targetSize)

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
    /// of the live shader's `mix(1.0, 3.5, edgeDist^2)` per-pixel falloff.
    private static func applyChromaAberration(_ image: CIImage, size: CGSize) -> CIImage {
        let extent = CGRect(origin: .zero, size: size)
        let offset: CGFloat = 3.0

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

    /// Fine sine scanlines matching the live shader's
    /// `sin(uv.y * size.y * 1.3) * 0.5 + 0.5`, precomputed as a 1px-wide
    /// column and stretched horizontally (each row is a constant
    /// brightness, so stretching a single column tiles it perfectly).
    private static func applyScanlines(_ image: CIImage, size: CGSize) -> CIImage {
        let height = max(1, Int(size.height.rounded()))
        var pixels = [UInt8](repeating: 255, count: height * 4)
        for y in 0..<height {
            let scan = sin(Double(y) * 1.3) * 0.5 + 0.5
            let mult = 0.82 + (1.0 - 0.82) * scan
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
            return image
        }
        let scanlineImage = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: size.width, y: 1))
        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = scanlineImage
        multiply.backgroundImage = image
        return (multiply.outputImage ?? image).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Radial darkening toward the corners, matching the live shader's
    /// `smoothstep(0.95, 0.35, dist) -> mix(0.55, 1.0, vig)`.
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

        let strength: CGFloat = 0.05
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

    private func updateTrackingBandState(frameIndex: Int) {
        if trackingBandFramesRemaining > 0 {
            trackingBandFramesRemaining -= 1
            return
        }
        // A new "roll" window every ~1/6s, mirroring the live shader's
        // `floor(time * 6.0)` cadence; most windows stay quiet.
        let windowFrames = max(1, Int(fps) / 6)
        guard frameIndex % windowFrames == 0 else { return }
        var gen = SplitMix64(seed: UInt64(bitPattern: Int64(frameIndex &* 2_246_822_519 &+ 3_266_489_917)))
        guard gen.nextUnit() > 0.93 else { return }
        trackingBandFramesRemaining = Int(2 + gen.nextUnit() * 4) // 2...6 frames
        trackingBandCenterY = CGFloat(gen.nextUnit()) * CGFloat(height)
        trackingBandOffsetX = CGFloat((gen.nextUnit() - 0.5) * 40)
    }

    private func applyTrackingBand(to image: CIImage) -> CIImage {
        let bandHeight = CGFloat(height) * 0.07
        let bandRect = CGRect(x: 0, y: max(0, trackingBandCenterY - bandHeight / 2),
                               width: CGFloat(width), height: bandHeight).intersection(baseExtent)
        guard !bandRect.isEmpty else { return image }
        let strip = image.cropped(to: bandRect)
            .transformed(by: CGAffineTransform(translationX: trackingBandOffsetX, y: 0))
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = strip
        over.backgroundImage = image
        return (over.outputImage ?? image).cropped(to: baseExtent)
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
}

// MARK: - Cheap deterministic per-frame RNG

/// SplitMix64: fast, allocation-free, deterministic given a seed -- used so
/// each frame's "randomness" (grain sample offset, tracking-band decision)
/// is reproducible and safe to compute without any shared mutable RNG
/// state across frames.
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
