//
//  PatternGenerator.swift
//  LiminalGenerator
//
//  Random arpeggio + drum pattern generation in the "liminal" style: slow,
//  hazy, melancholic, always straight/even (no rests, no held notes, no
//  swing -- every step triggers its own note). Musical parameters (key,
//  scale, pattern shape) live on `ArpeggioPattern`; tempo is NOT one of
//  them -- see `AudioEngineController.effectiveBPM`/`speed`. The render
//  side (`LiminalDSPCore`) just reads MIDI notes/velocities off the step
//  array -- it doesn't need music theory.
//
//  Pinned contract (do not rename): `ArpeggioPattern.displaySeq: String`.
//  Per the SPEC.md addendum, `ArpeggioPattern` no longer carries a
//  randomized `bpm` used for playback -- nothing reads a per-pattern bpm
//  for timing anymore; the tick clock's rate comes from
//  `AudioEngineController.effectiveBPM`.

import Foundation

// MARK: - Seedable RNG (for deterministic tests)

/// Deterministic RandomNumberGenerator (SplitMix64) so pattern generation
/// can be unit tested for determinism. Real app usage defaults to
/// `SystemRandomNumberGenerator` via the no-argument generator functions.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Scales

/// Weighted at selection time (see `PatternGenerator.randomScale`): 90%
/// uniformly from the first four cases, 10% `majorPentatonic` as an
/// occasional sprinkle. Natural-minor/major-7-pentatonic from the pre-
/// addendum generator are retired.
enum LiminalScale: CaseIterable {
    case minorPentatonic
    case dorian
    case mixolydian
    case lydian
    case majorPentatonic

    /// Semitone offsets from the root, ascending within one octave.
    var intervals: [Int] {
        switch self {
        case .minorPentatonic: return [0, 3, 5, 7, 10]
        case .dorian: return [0, 2, 3, 5, 7, 9, 10]
        case .mixolydian: return [0, 2, 4, 5, 7, 9, 10]
        case .lydian: return [0, 2, 4, 6, 7, 9, 11]
        case .majorPentatonic: return [0, 2, 4, 7, 9]
        }
    }
}

// MARK: - Pattern shape

/// Exactly one is chosen per `regenerateMelody()` call. `up`/`down` walk a
/// fixed 2-octave ascending/descending scale-degree ladder
/// (`PatternGenerator.octaveSpanDegrees`); `upDown` ascends to the top of
/// that ladder then back down without repeating the peak note. All three
/// are tiled (cyclically repeated) to fill the fixed
/// `PatternGenerator.stepCount` steps -- see `PatternGenerator.buildDegreeSequence`.
enum ArpShape: CaseIterable {
    case up
    case down
    case upDown
}

// MARK: - Arpeggio pattern

struct ArpStep: Sendable {
    /// MIDI note number. No rests/holds anymore -- every step triggers its
    /// own note-on with straight, even timing.
    var midiNote: Int
    /// 0...1. Small humanization jitter only -- not a randomized musical
    /// parameter.
    var velocity: Float
}

struct ArpeggioPattern: Sendable {
    var displaySeq: String
    var steps: [ArpStep]
    /// Root MIDI note of the pattern's key (kept for reference/debugging).
    var rootMIDI: Int
    /// Kept for debugging/tests only -- not read by the DSP core for timing.
    var scale: LiminalScale
    var shape: ArpShape
}

// MARK: - Drum pattern (loop selection)

/// Pinned contract (do not rename): selects one of the bundled CC0 lo-fi
/// loops in `Resources/Loops/` (see `LoopLibrary`) rather than describing a
/// synthesized pattern. `loopIndex` indexes `LoopLibrary.all`; `displayName`
/// and `bpm` are copied from the matching `LoopInfo` for cheap UI/tempo-sync
/// access without threading `LoopLibrary` lookups everywhere.
struct DrumPattern: Sendable {
    let loopIndex: Int
    let displayName: String
    let bpm: Int
}

// MARK: - Generator

enum PatternGenerator {

    private static let pitchClassNames = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
    ]

    /// Fixed step count for every generated arpeggio (NOT randomized --
    /// see SPEC.md addendum). 16 gives one trigger per 16th-note tick
    /// (`ArpeggioSequencer.ticksPerStep == 1`), the finest grid the shared
    /// tick clock supports, which best resolves the `upDown` zigzag shape
    /// across the fixed 2-octave span.
    static let stepCount = 16

    /// Fixed octave span for the `up`/`down`/`upDown` scale-degree ladder:
    /// exactly 2 octaves (24 semitones == `2 * intervals.count` scale
    /// degrees, which always lands precisely on `root + 24` regardless of
    /// scale since `intervals[0] == 0` for every scale here).
    private static let octaveSpanMultiplier = 2

    /// Warm low-mid register anchor: root pitch class 0 (C) maps to MIDI 48
    /// (C3); pitch classes 1...11 sit within the same octave (48...59).
    private static let rootOctaveAnchorMIDI = 48

    // MARK: Arpeggio

    static func randomArpeggioPattern() -> ArpeggioPattern {
        var rng = SystemRandomNumberGenerator()
        return randomArpeggioPattern(using: &rng)
    }

    /// Re-rolls ONLY root key, scale, and pattern shape (per SPEC.md
    /// addendum) -- step count and octave span are the program constants
    /// above, velocity carries only small humanization jitter.
    static func randomArpeggioPattern<R: RandomNumberGenerator>(using rng: inout R) -> ArpeggioPattern {
        let rootPitchClass = Int.random(in: 0...11, using: &rng)
        let rootMIDI = rootOctaveAnchorMIDI + rootPitchClass
        let scale = randomScale(using: &rng)
        let shape = ArpShape.allCases.randomElement(using: &rng) ?? .up

        let intervals = scale.intervals
        let degreeSequence = buildDegreeSequence(shape: shape, scaleDegreeCount: intervals.count, stepCount: stepCount)

        var steps: [ArpStep] = []
        steps.reserveCapacity(stepCount)
        for degree in degreeSequence {
            let midi = scaleDegreeMIDI(rootMIDI: rootMIDI, intervals: intervals, degree: degree)
            let velocity = rng.nextHumanizedVelocity()
            steps.append(ArpStep(midiNote: midi, velocity: velocity))
        }

        let displaySeq = makeDisplaySeq(steps: steps)
        return ArpeggioPattern(displaySeq: displaySeq, steps: steps, rootMIDI: rootMIDI, scale: scale, shape: shape)
    }

    /// 90% uniformly from {minorPentatonic, dorian, mixolydian, lydian},
    /// 10% majorPentatonic as an occasional sprinkle.
    private static func randomScale<R: RandomNumberGenerator>(using rng: inout R) -> LiminalScale {
        let commonScales: [LiminalScale] = [.minorPentatonic, .dorian, .mixolydian, .lydian]
        let roll = Float.random(in: 0...1, using: &rng)
        if roll < 0.10 {
            return .majorPentatonic
        }
        return commonScales.randomElement(using: &rng) ?? .minorPentatonic
    }

    /// Maps a scale degree (can exceed `intervals.count`, wraps with an
    /// octave shift) to an absolute MIDI note.
    private static func scaleDegreeMIDI(rootMIDI: Int, intervals: [Int], degree: Int) -> Int {
        let k = intervals.count
        let wrapped = ((degree % k) + k) % k
        let octave = degree >= 0 ? degree / k : (degree - k + 1) / k
        return rootMIDI + intervals[wrapped] + 12 * octave
    }

    /// Builds the fixed-length (`stepCount`) sequence of scale degrees for
    /// a pattern shape, by tiling (cyclically repeating) the shape's
    /// natural one-cycle degree ladder over the fixed 2-octave span:
    ///   - `up`: degrees `0...2k` ascending (k = scaleDegreeCount), tiled.
    ///   - `down`: the same ladder reversed, tiled.
    ///   - `upDown`: ascend `0...2k` then back down to (but excluding) the
    ///     root and the already-played peak, i.e. no repeated peak note at
    ///     the turnaround; that `(2k+1) + (2k-1) = 4k` length cycle is tiled.
    /// Tiling (rather than growing the octave span with more steps) is what
    /// keeps the octave span fixed regardless of `stepCount`/scale size.
    static func buildDegreeSequence(shape: ArpShape, scaleDegreeCount k: Int, stepCount: Int) -> [Int] {
        guard k > 0 else { return Array(repeating: 0, count: stepCount) }
        let topDegree = octaveSpanMultiplier * k
        let ascendLadder = Array(0...topDegree) // length topDegree + 1, e.g. 0...2k

        let cycle: [Int]
        switch shape {
        case .up:
            cycle = ascendLadder
        case .down:
            cycle = ascendLadder.reversed()
        case .upDown:
            // Ascend to the peak, then back down without repeating the
            // peak (drop the last element of the reversed descent's
            // leading edge) -- classic zigzag, no doubled turnaround note.
            let descend = ascendLadder.reversed().dropFirst() // exclude the peak (already played)
            cycle = ascendLadder + Array(descend)
        }

        guard !cycle.isEmpty else { return Array(repeating: 0, count: stepCount) }
        return (0..<stepCount).map { cycle[$0 % cycle.count] }
    }

    private static func makeDisplaySeq(steps: [ArpStep]) -> String {
        var seen = Set<Int>()
        var names: [String] = []
        for step in steps {
            let pc = ((step.midiNote % 12) + 12) % 12
            if seen.insert(pc).inserted {
                names.append(pitchClassNames[pc])
                if names.count == 4 { break }
            }
        }
        if names.isEmpty { names = ["C"] }
        return names.joined(separator: "-")
    }

    // MARK: Drums (loop selection)

    /// Picks a random bundled loop. `excludingLoopIndex`, when non-nil,
    /// guarantees the result never repeats that index (used by
    /// `regenerateBeat()` for a guaranteed change) as long as the library
    /// has more than one entry.
    static func randomDrumPattern(excludingLoopIndex: Int? = nil) -> DrumPattern {
        var rng = SystemRandomNumberGenerator()
        return randomDrumPattern(excludingLoopIndex: excludingLoopIndex, using: &rng)
    }

    static func randomDrumPattern<R: RandomNumberGenerator>(excludingLoopIndex: Int?,
                                                              using rng: inout R) -> DrumPattern {
        let count = LoopLibrary.all.count
        var index = Int.random(in: 0..<count, using: &rng)
        if let excludingLoopIndex, count > 1 {
            while index == excludingLoopIndex {
                index = Int.random(in: 0..<count, using: &rng)
            }
        }
        let info = LoopLibrary.all[index]
        return DrumPattern(loopIndex: index, displayName: info.displayName, bpm: info.bpm)
    }
}

private extension RandomNumberGenerator {
    /// Small humanization jitter around a confident lead-line level --
    /// NOT a randomized musical parameter (accenting only).
    mutating func nextHumanizedVelocity() -> Float {
        Float.random(in: 0.78...0.98, using: &self)
    }
}
