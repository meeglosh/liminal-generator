//
//  PatternGenerator.swift
//  LiminalGenerator
//
//  Random arpeggio + drum pattern generation in the "liminal" style: slow,
//  hazy, melancholic. Musical parameters (key, scale, bpm) live on
//  `ArpeggioPattern`; the render-side (`LiminalDSPCore`) just reads MIDI
//  notes/velocities off the step arrays -- it doesn't need music theory.
//
//  Pinned contract (do not rename): `ArpeggioPattern.displaySeq: String`,
//  `ArpeggioPattern.bpm: Int`.

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

enum LiminalScale: CaseIterable {
    case naturalMinor
    case dorian
    case majorPentatonic7

    /// Semitone offsets from the root, ascending within one octave.
    var intervals: [Int] {
        switch self {
        case .naturalMinor: return [0, 2, 3, 5, 7, 8, 10]
        case .dorian: return [0, 2, 3, 5, 7, 9, 10]
        case .majorPentatonic7: return [0, 2, 4, 7, 9, 11] // pentatonic + maj7 color tone
        }
    }
}

// MARK: - Arpeggio pattern

struct ArpStep: Sendable {
    /// MIDI note number, or nil for a rest.
    var midiNote: Int?
    /// 0...1
    var velocity: Float
    /// If true, this step ties over from the previous sounding note --
    /// the sequencer must NOT retrigger a new voice for it.
    var hold: Bool
}

struct ArpeggioPattern: Sendable {
    var displaySeq: String
    var bpm: Int
    var steps: [ArpStep]
    /// Root MIDI note of the pattern's key (kept for reference/debugging).
    var rootMIDI: Int
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

    // MARK: Arpeggio

    static func randomArpeggioPattern() -> ArpeggioPattern {
        var rng = SystemRandomNumberGenerator()
        return randomArpeggioPattern(using: &rng)
    }

    static func randomArpeggioPattern<R: RandomNumberGenerator>(using rng: inout R) -> ArpeggioPattern {
        let scale = LiminalScale.allCases.randomElement(using: &rng) ?? .naturalMinor
        let intervals = scale.intervals
        let rootMIDI = Int.random(in: 45...52, using: &rng) // A2...E3-ish, warm low-mid center
        let bpm = Int.random(in: 68...96, using: &rng)
        let stepCount = Bool.random(using: &rng) ? 8 : 16
        let octaveSpan = Bool.random(using: &rng) ? 1 : 2

        // Implied i-VI-III-VII-style movement: split the pattern into 4
        // equal segments, each centered on a scale-degree "chord" root.
        let segmentDegreeRoots = [0, 5, 2, 6] // i, VI, III, VII (0-based scale degree indices)
        let stepsPerSegment = max(1, stepCount / 4)

        func degreeToMIDI(_ degree: Int, octaveOffset: Int) -> Int {
            let n = intervals.count
            let wrapped = ((degree % n) + n) % n
            let octavesFromWrap = degree >= 0 ? degree / n : (degree - n + 1) / n
            return rootMIDI + intervals[wrapped] + 12 * octavesFromWrap + 12 * octaveOffset
        }

        var steps: [ArpStep] = []
        steps.reserveCapacity(stepCount)

        for i in 0..<stepCount {
            let segment = min(i / stepsPerSegment, 3)
            let chordRootDegree = segmentDegreeRoots[segment]
            let chordTonePool = [chordRootDegree, chordRootDegree + 2, chordRootDegree + 4]

            let roll = Float.random(in: 0...1, using: &rng)
            if roll < 0.12 && i > 0 {
                // Rest.
                steps.append(ArpStep(midiNote: nil, velocity: 0, hold: false))
                continue
            }
            if roll < 0.22 && i > 0 {
                // Hold/tie the previous sounding note.
                let previousNote = steps.reversed().first(where: { $0.midiNote != nil })?.midiNote
                steps.append(ArpStep(midiNote: previousNote, velocity: 0, hold: true))
                continue
            }

            let useChordTone = Float.random(in: 0...1, using: &rng) < 0.75
            let degree = useChordTone
                ? (chordTonePool.randomElement(using: &rng) ?? chordRootDegree)
                : Int.random(in: 0..<intervals.count, using: &rng)
            let octaveOffset = octaveSpan == 1 ? 0 : Int.random(in: 0...1, using: &rng)
            let midi = degreeToMIDI(degree, octaveOffset: octaveOffset)
            let velocity = Float.random(in: 0.55...1.0, using: &rng)
            steps.append(ArpStep(midiNote: midi, velocity: velocity, hold: false))
        }

        let displaySeq = makeDisplaySeq(steps: steps)
        return ArpeggioPattern(displaySeq: displaySeq, bpm: bpm, steps: steps, rootMIDI: rootMIDI)
    }

    private static func makeDisplaySeq(steps: [ArpStep]) -> String {
        var seen = Set<Int>()
        var names: [String] = []
        for step in steps {
            guard let note = step.midiNote else { continue }
            let pc = ((note % 12) + 12) % 12
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
