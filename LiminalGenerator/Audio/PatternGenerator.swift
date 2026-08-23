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

// MARK: - Drum pattern

struct DrumStep: Sendable {
    /// Velocity 0...1, or nil if that instrument doesn't hit on this step.
    var kick: Float?
    var snare: Float?
    var hat: Float?
}

struct DrumPattern: Sendable {
    /// Always 16 steps (one bar of 16th notes) -- shares the master tempo
    /// with the currently active `ArpeggioPattern.bpm`.
    var steps: [DrumStep]
    /// 0...~0.15, delay applied to off-16th-note steps for a swung feel.
    var swing: Float
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

    // MARK: Drums

    static func randomDrumPattern() -> DrumPattern {
        var rng = SystemRandomNumberGenerator()
        return randomDrumPattern(using: &rng)
    }

    static func randomDrumPattern<R: RandomNumberGenerator>(using rng: inout R) -> DrumPattern {
        let stepCount = 16
        var steps = [DrumStep](repeating: DrumStep(kick: nil, snare: nil, hat: nil), count: stepCount)

        // Kick: always on the downbeat, sparse elsewhere, favoring beat
        // boundaries (steps 0/4/8/12) over syncopated offbeats.
        var lastKickStep = -4
        for i in 0..<stepCount {
            let isBeat = i % 4 == 0
            let baseProb: Float = isBeat ? 0.42 : 0.08
            let farEnough = (i - lastKickStep) >= 2
            if i == 0 || (farEnough && Float.random(in: 0...1, using: &rng) < baseProb) {
                steps[i].kick = Float.random(in: 0.75...1.0, using: &rng)
                lastKickStep = i
            }
        }

        // Snare: beats 2 & 4 (steps 4, 12) with slight variation, occasional ghost hit.
        for anchor in [4, 12] {
            if Float.random(in: 0...1, using: &rng) < 0.9 {
                steps[anchor].snare = Float.random(in: 0.7...1.0, using: &rng)
            } else {
                let shifted = clamp(anchor + (Bool.random(using: &rng) ? 1 : -1), 0, stepCount - 1)
                steps[shifted].snare = Float.random(in: 0.6...0.9, using: &rng)
            }
        }
        if Float.random(in: 0...1, using: &rng) < 0.15 {
            let ghost = Int.random(in: 0..<stepCount, using: &rng)
            if steps[ghost].snare == nil {
                steps[ghost].snare = Float.random(in: 0.25...0.45, using: &rng)
            }
        }

        // Closed hats: sparse, mostly on the eighth-note grid, humanized velocity.
        for i in 0..<stepCount {
            let onEighth = i % 2 == 0
            let prob: Float = onEighth ? 0.62 : 0.18
            if Float.random(in: 0...1, using: &rng) < prob {
                steps[i].hat = Float.random(in: 0.35...0.85, using: &rng)
            }
        }

        let swing = Float.random(in: 0.0...0.12, using: &rng)
        return DrumPattern(steps: steps, swing: swing)
    }
}
