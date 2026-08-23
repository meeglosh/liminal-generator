//
//  BasslinePattern.swift
//  LiminalGenerator
//
//  Bassline pattern generation: a step-based rhythm with RESTS and
//  HELD/TIED notes (deliberately irregular, unlike the melody's strict
//  straight/even steps) -- see SPEC.md addendum 2, "New BASSLINE section".
//
//  Notes are stored as scale DEGREE ROLES (root/fifth/third/octaveUp), NOT
//  absolute MIDI pitches. This is the key-sync mechanism: `resolveBassMIDI`
//  is called at note-trigger time (inside `LiminalDSPCore.doTick`) against
//  whatever the CURRENT active `ArpeggioPattern`'s root+scale is at that
//  instant -- so the bassline can never "remember" a stale key. Whenever
//  `regenerateMelody()` swaps in a new root/scale, the very next bass note
//  automatically resolves against the new key with no explicit bass-refresh
//  step required.
//
//  Internal type -- no UI-facing readout (per SPEC.md: "No SEQ/BPM readout
//  row (not requested)").
//

import Foundation

/// Scale-degree role a bass note can take, resolved against the CURRENT
/// melody pattern's root+scale at trigger time. All four roles always
/// resolve to a pitch class that is actually in the current scale's
/// `intervals` (root=0 and octaveUp=0 trivially so; fifth/third pick the
/// nearest interval the scale actually contains -- every scale in
/// `LiminalScale` contains an exact interval of 7, so "fifth" is always a
/// true perfect fifth in this app's scale pool).
enum BassRole: Sendable {
    case root
    case fifth
    case third
    case octaveUp
}

struct BassStep: Sendable {
    enum Kind: Sendable {
        case rest
        case hold
        case note(BassRole)
    }
    var kind: Kind
    /// 0...1. Only meaningful for `.note` steps.
    var velocity: Float
}

struct BasslinePattern: Sendable {
    /// Fixed length == `PatternGenerator.stepCount` (16), on the SAME
    /// 16th-note tick grid the melody/loop already share -- see
    /// `BassSequencer` in LiminalDSPCore.swift. One entry per tick, not
    /// straight/even like the melody: many entries are `.rest`/`.hold`.
    var steps: [BassStep]
    /// Semitone offset applied on top of the resolved scale-degree pitch to
    /// push the bassline into a low register, roughly 1-2 octaves below the
    /// melody's root (-12 or -24). Fixed per pattern (not per-step).
    var octaveShift: Int
}

enum BasslineGenerator {

    static func randomBasslinePattern() -> BasslinePattern {
        var rng = SystemRandomNumberGenerator()
        return randomBasslinePattern(using: &rng)
    }

    /// Deliberately irregular rhythm: divides the fixed 16-step grid into 4
    /// quarter-note "beats" (4 steps each) and picks one of a handful of
    /// beat shapes per beat -- long held notes, short stabs, two-note
    /// walking motion, syncopation, or a bar of silence -- for a simple,
    /// melodic "walking bassline" feel rather than a scale run.
    static func randomBasslinePattern<R: RandomNumberGenerator>(using rng: inout R) -> BasslinePattern {
        let stepCount = PatternGenerator.stepCount // 16, same shared tick grid as melody
        let beatsPerBar = stepCount / 4
        var steps = Array(repeating: BassStep(kind: .rest, velocity: 0), count: stepCount)

        for beat in 0..<beatsPerBar {
            let base = beat * 4
            applyBeatShape(BeatShape.random(using: &rng), at: base, into: &steps, rng: &rng)
        }

        // Guarantee at least one sounding note somewhere in the bar -- an
        // all-rest roll (possible via `.silence`) on every single beat is
        // astronomically unlikely (1/5^4) but not worth risking a fully
        // silent bassline pattern.
        if !steps.contains(where: { if case .note = $0.kind { return true }; return false }) {
            steps[0] = BassStep(kind: .note(.root), velocity: Float.random(in: 0.7...0.95, using: &rng))
        }

        let octaveShift = Bool.random(using: &rng) ? -24 : -12
        return BasslinePattern(steps: steps, octaveShift: octaveShift)
    }

    private enum BeatShape: CaseIterable {
        case longNote     // note + hold + hold + hold (one sustained note per beat)
        case shortStab    // note + rest + rest + rest (punchy, lots of space)
        case walkingPair  // note + hold + note + hold (two notes, walking motion)
        case syncopated   // note + rest + note + hold (off-grid accent)
        case silence      // whole beat rests -- deliberate space/irregularity

        static func random<R: RandomNumberGenerator>(using rng: inout R) -> BeatShape {
            // Weighted so the bassline still speaks most of the time --
            // silence is an occasional accent, not the norm.
            let roll = Float.random(in: 0...1, using: &rng)
            switch roll {
            case ..<0.28: return .longNote
            case ..<0.50: return .shortStab
            case ..<0.74: return .walkingPair
            case ..<0.92: return .syncopated
            default: return .silence
            }
        }
    }

    private static func applyBeatShape<R: RandomNumberGenerator>(_ shape: BeatShape,
                                                                    at base: Int,
                                                                    into steps: inout [BassStep],
                                                                    rng: inout R) {
        switch shape {
        case .longNote:
            steps[base] = noteStep(randomRole(allowThird: true, using: &rng), rng: &rng)
            steps[base + 1] = holdStep
            steps[base + 2] = holdStep
            steps[base + 3] = holdStep
        case .shortStab:
            steps[base] = noteStep(randomRole(allowThird: false, using: &rng), rng: &rng)
            // steps[base+1...3] stay .rest (default)
        case .walkingPair:
            steps[base] = noteStep(.root, rng: &rng)
            steps[base + 1] = holdStep
            steps[base + 2] = noteStep(randomRole(allowThird: true, using: &rng), rng: &rng)
            steps[base + 3] = holdStep
        case .syncopated:
            steps[base] = noteStep(.root, rng: &rng)
            // steps[base+1] stays .rest -- the syncopated "push"
            steps[base + 2] = noteStep(randomRole(allowThird: true, using: &rng), rng: &rng)
            steps[base + 3] = holdStep
        case .silence:
            break // every step in this beat stays .rest
        }
    }

    private static var holdStep: BassStep { BassStep(kind: .hold, velocity: 0) }

    private static func noteStep<R: RandomNumberGenerator>(_ role: BassRole, rng: inout R) -> BassStep {
        BassStep(kind: .note(role), velocity: Float.random(in: 0.65...0.92, using: &rng))
    }

    /// root 45% / fifth 35% / octaveUp 12% / third 8% (third only offered on
    /// beat shapes that pass `allowThird: true`) -- "mostly root/fifth/
    /// octave, occasional third" per SPEC.md.
    private static func randomRole<R: RandomNumberGenerator>(allowThird: Bool, using rng: inout R) -> BassRole {
        let roll = Float.random(in: 0...1, using: &rng)
        if allowThird && roll < 0.08 { return .third }
        let adjusted = allowThird ? (roll - 0.08) / 0.92 : roll
        switch adjusted {
        case ..<0.45: return .root
        case ..<0.80: return .fifth
        default: return .octaveUp
        }
    }

    /// Resolves a `BassRole` to an absolute MIDI note against the CURRENT
    /// key (root + scale). Called at note-trigger time so the bassline is
    /// always in tune with whatever pattern is currently active -- never a
    /// cached/stale key. `intervals` are semitone offsets from root,
    /// ascending within one octave (e.g. minor pentatonic: [0,3,5,7,10]);
    /// `root=0` and `octaveUp=12` are trivially always scale tones, and
    /// `fifth`/`third` pick the nearest interval the scale actually
    /// contains (every `LiminalScale` case contains an exact 7-semitone
    /// interval, so "fifth" is always a true perfect fifth here).
    static func resolveBassMIDI(role: BassRole, rootMIDI: Int, intervals: [Int], octaveShift: Int) -> Int {
        let base = rootMIDI + octaveShift
        switch role {
        case .root:
            return base
        case .octaveUp:
            return base + 12
        case .fifth:
            return base + nearestInterval(to: 7, in: intervals)
        case .third:
            return base + nearestInterval(to: 3, in: intervals)
        }
    }

    private static func nearestInterval(to target: Int, in intervals: [Int]) -> Int {
        intervals.min(by: { abs($0 - target) < abs($1 - target) }) ?? 0
    }
}
