//
//  WowFlutterProcessor.swift
//  LiminalGenerator
//
//  Modulated fractional delay line over the full mix, simulating tape
//  wow (slow ~0.5-2Hz pitch drift) and flutter (faster, smaller pitch
//  jitter). Depth scales with `age`. One instance per channel, with a
//  phase offset on the R channel, gives a subtle stereo width without any
//  extra allocation.
//

import Foundation

final class WowFlutterProcessor {
    private var buffer: [Float]
    private let bufferSize: Int
    private var writeIndex: Int = 0
    private var wowPhase: Float
    private var flutterPhase: Float
    private let sampleRate: Double

    // Rates chosen within the spec'd ranges: wow slow (~0.5-2Hz), flutter
    // faster/smaller. Fixed per instance (not user-controllable) -- only
    // depth is modulated by `age`.
    private let wowRateHz: Float
    private let flutterRateHz: Float

    init(sampleRate: Double, maxDelayMs: Double = 22, phaseOffset: Float = 0, wowRateHz: Float = 0.85, flutterRateHz: Float = 6.5) {
        self.sampleRate = sampleRate
        bufferSize = Int(sampleRate * maxDelayMs / 1000) + 8
        buffer = [Float](repeating: 0, count: bufferSize)
        wowPhase = phaseOffset
        flutterPhase = phaseOffset * 0.5
        self.wowRateHz = wowRateHz
        self.flutterRateHz = flutterRateHz
    }

    /// - Parameter depth: 0...1 (age-driven wow/flutter intensity).
    @inline(__always)
    func process(_ input: Float, depth: Float) -> Float {
        buffer[writeIndex] = input

        wowPhase += wowRateHz / Float(sampleRate)
        if wowPhase >= 1 { wowPhase -= 1 }
        flutterPhase += flutterRateHz / Float(sampleRate)
        if flutterPhase >= 1 { flutterPhase -= 1 }

        let wow = sin(2 * Float.pi * wowPhase)
        let flutter = sin(2 * Float.pi * flutterPhase)

        // Base delay keeps us mid-buffer so modulation never goes negative.
        let baseDelayMs: Float = 9
        let wowSwingMs: Float = 6.0 * depth
        let flutterSwingMs: Float = 1.4 * depth
        let delayMs = baseDelayMs + wowSwingMs * wow + flutterSwingMs * flutter
        let delaySamples = Double(delayMs) / 1000 * sampleRate

        let readPos = Double(writeIndex) - delaySamples
        let idx0 = Int(floor(readPos))
        let frac = Float(readPos - Double(idx0))
        let i0 = ((idx0 % bufferSize) + bufferSize) % bufferSize
        let i1 = (i0 + 1) % bufferSize
        let s0 = buffer[i0]
        let s1 = buffer[i1]
        let out = s0 + (s1 - s0) * frac

        writeIndex += 1
        if writeIndex >= bufferSize { writeIndex = 0 }
        return out
    }
}
