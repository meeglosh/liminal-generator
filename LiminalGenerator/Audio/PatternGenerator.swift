//
//  PatternGenerator.swift
//  LiminalGenerator
//
//  Ambient-pad scene generation (SPEC.md Addendum 3 -- supersedes the
//  arpeggio engine from Addenda 1/2). `regenerateMelody()` re-rolls a whole
//  "scene": a random minor key, a 4-chord/4-bar looping progression drawn
//  from a curated pool of nostalgic minor progressions, warm open-voiced
//  pad chords (with frequent add9/sus2 substitutions), and a sparse
//  motif-based melody in the key's minor pentatonic. The render side
//  (`LiminalDSPCore`) just reads absolute MIDI notes off the generated
//  scene -- it doesn't need music theory.
//
//  Pinned contract (do not rename): `ArpeggioPattern.displaySeq: String`,
//  now returning the chord progression as chord names, e.g. "Am-F-C-G".
//
//  Chord-tone diatonicity is correct BY CONSTRUCTION: every chord tone is
//  built by stacking `naturalMinorSteps` scale-degree offsets (root/
//  third-or-second/fifth/ninth), never a hardcoded interval -- so any
//  degree of the key's natural minor scale always yields tones that are
//  themselves scale members. Likewise every melody note is built directly
//  from `minorPentatonicIntervals`, so it can never leave the pentatonic
//  set. See the scratchpad harness for an empirical regression check.
//

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

// MARK: - Chord / scene model

/// A single voiced pad chord: `tones` are absolute MIDI notes (4-5 voices,
/// root low, spread over roughly two octaves -- see `PatternGenerator
/// .buildChord`), `rootMIDI` is the chord's own root (used by the bassline
/// to derive the sub an octave below), `name` is the short chord-name
/// string used in `displaySeq` (e.g. "Am", "F").
struct ChordSpec: Sendable {
    var rootMIDI: Int
    var tones: [Int]
    var name: String
}

/// One sparse melody note, positioned by its tick offset within the
/// melody's looping cycle (see `MelodyMotif.cycleTicks`).
struct MelodyNoteEvent: Sendable {
    var tickOffset: Int
    var midiNote: Int
    var velocity: Float
}

/// A short motif (2-5 notes per 2-bar/32-tick phrase) tiled across a fixed
/// multi-phrase cycle, with later phrases repeating the motif with slight
/// variation (octave shift or neighbor-tone substitution) or resting
/// entirely -- see `PatternGenerator.generateMelodyMotif`. `lookup` is a
/// precomputed (control-thread-built, render-thread-read-only) sparse
/// array indexed by `tick % cycleTicks` so the render thread never
/// allocates or searches.
struct MelodyMotif: Sendable {
    var events: [MelodyNoteEvent]
    var cycleTicks: Int
    var lookup: [MelodyNoteEvent?]

    init(events: [MelodyNoteEvent], cycleTicks: Int) {
        self.events = events
        self.cycleTicks = cycleTicks
        var table = [MelodyNoteEvent?](repeating: nil, count: max(1, cycleTicks))
        for event in events where event.tickOffset >= 0 && event.tickOffset < table.count {
            table[event.tickOffset] = event
        }
        self.lookup = table
    }
}

// MARK: - Ambient scene (repurposed `ArpeggioPattern`, name pinned)

/// Pinned type name (do not rename) -- repurposed per SPEC.md Addendum 3 to
/// hold the generated ambient "scene": key, chord progression, voicing, and
/// melody motif, instead of an arpeggio step sequence.
struct ArpeggioPattern: Sendable {
    /// Chord progression as chord names, e.g. "Am-F-C-G" (UI readout label
    /// is "PROG:", changed by the UI agent).
    var displaySeq: String
    /// Key root pitch class 0...11 (always minor tonality).
    var rootPitchClass: Int
    /// Exactly 4 voiced chords, one per bar, looping forever (bar % 4).
    var progression: [ChordSpec]
    /// Scale-degree indices (0...6 into natural-minor `steps`) the
    /// progression was built from, in the SAME order as `progression` --
    /// kept for debugging/regression tests (verifying "progression always
    /// from the curated pool").
    var progressionDegrees: [Int]
    /// Sparse floating melody, minor-pentatonic, motif-based.
    var melodyMotif: MelodyMotif
}

// MARK: - Drum pattern (loop selection) -- unchanged by this addendum

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

    /// Natural minor (aeolian) scale-degree semitone offsets from the key
    /// root, ascending within one octave. Every chord tone and every
    /// melody-adjacent interval used by the generator is derived from this
    /// table (never a hardcoded major/minor third), which is what makes
    /// diatonicity hold by construction for ANY degree.
    static let naturalMinorSteps = [0, 2, 3, 5, 7, 8, 10]

    /// Minor pentatonic intervals from the key root -- the melody's only
    /// note pool (SPEC.md Addendum 3, "strictly in the key's minor
    /// pentatonic").
    static let minorPentatonicIntervals = [0, 3, 5, 7, 10]

    /// Curated pool of proven nostalgic minor progressions (SPEC.md
    /// Addendum 3), expressed as scale-degree indices into
    /// `naturalMinorSteps`: i=0, ii=1 (unused), III=2, iv=3, v=4, VI=5,
    /// VII=6. Verified against the spec's own worked example: key A minor,
    /// pool[0] == i-VI-III-VII resolves to Am-F-C-G.
    static let progressionPool: [[Int]] = [
        [0, 5, 2, 6], // i-VI-III-VII
        [0, 6, 5, 6], // i-VII-VI-VII
        [0, 3, 5, 4], // i-iv-VI-v
        [0, 5, 3, 4], // i-VI-iv-v
        [5, 6, 0, 0], // VI-VII-i-i
        [0, 4, 5, 2], // i-v-VI-III
        [0, 2, 6, 5], // i-III-VII-VI
    ]

    /// Low-register anchor for a chord's root voice ("root low" per the
    /// addendum). MUST itself be a pitch class 0 (C) MIDI note -- MIDI 36
    /// is C2 -- so that `padRootAnchorMIDI + chordRootPC` (below) lands
    /// EXACTLY on `chordRootPC`'s pitch class with no octave-dependent
    /// skew; every chord root lands in `36...47` (C2...B2). The sub-bass
    /// then sits an octave below whatever the current bar's chord root is
    /// (`rootMIDI - 12`, resolved live -- see `LiminalDSPCore.doTick`),
    /// landing at `24...35` (C1...B1, ~33-65Hz), comfortably under ~150Hz.
    static let padRootAnchorMIDI = 36

    // MARK: Scene (chords + melody)

    static func randomScene() -> ArpeggioPattern {
        var rng = SystemRandomNumberGenerator()
        return randomScene(using: &rng)
    }

    /// Re-rolls the WHOLE scene: key, progression (from the curated pool),
    /// chord voicings (with add9/sus2 substitution rolls), and the melody
    /// motif -- per SPEC.md Addendum 3 "GENERATE MELODY re-rolls the whole
    /// scene."
    static func randomScene<R: RandomNumberGenerator>(using rng: inout R) -> ArpeggioPattern {
        let rootPitchClass = Int.random(in: 0...11, using: &rng)
        let degrees = progressionPool.randomElement(using: &rng) ?? progressionPool[0]
        let progression = degrees.map { buildChord(rootPitchClass: rootPitchClass, degreeIndex: $0, using: &rng) }
        let melody = generateMelodyMotif(rootPitchClass: rootPitchClass, using: &rng)
        let displaySeq = progression.map(\.name).joined(separator: "-")
        return ArpeggioPattern(displaySeq: displaySeq, rootPitchClass: rootPitchClass,
                                progression: progression, progressionDegrees: degrees, melodyMotif: melody)
    }

    /// Builds one warm, open-voiced pad chord for scale degree `degreeIndex`
    /// of the key rooted at `rootPitchClass`. 4-5 voices, root low, spread
    /// over ~2 octaves, with a 15% chance of a sus2 substitution (2nd
    /// degree replaces the 3rd) and a 30% chance of an add9 extension
    /// (9th added on top) -- both computed from the SAME diatonic
    /// scale-degree math as the plain triad, so they can never introduce an
    /// out-of-key tone. Voice gaps are always >= 3 semitones (no tight
    /// clusters): root=0, mid(3rd/2nd)~13-16, 5th=19, top(9th/octave)~24-26,
    /// optional 5th voice=31.
    static func buildChord<R: RandomNumberGenerator>(rootPitchClass: Int, degreeIndex: Int,
                                                       using rng: inout R) -> ChordSpec {
        let steps = naturalMinorSteps
        func step(_ i: Int) -> Int { steps[((i % 7) + 7) % 7] }

        let rootStep = step(degreeIndex)
        func diatonicOffset(_ targetIndex: Int) -> Int {
            let raw = step(targetIndex) - rootStep
            return raw < 0 ? raw + 12 : raw
        }
        let thirdStep = diatonicOffset(degreeIndex + 2)
        let secondStep = diatonicOffset(degreeIndex + 1) // used for sus2 AND the 9th (secondStep + 12)

        let chordRootPC = ((rootPitchClass + rootStep) % 12 + 12) % 12
        let isMajor = thirdStep == 4
        let name = pitchClassNames[chordRootPC] + (isMajor ? "" : "m")

        let subRoll = Float.random(in: 0...1, using: &rng)
        let useSus2 = subRoll >= 0.55 && subRoll < 0.70   // 15%
        let useAdd9 = subRoll >= 0.70                     // 30%
        let midVoiceInterval = useSus2 ? secondStep : thirdStep

        let chordRootMIDI = padRootAnchorMIDI + chordRootPC
        var tones: [Int] = [chordRootMIDI]
        tones.append(chordRootMIDI + 12 + midVoiceInterval) // 3rd/2nd, ~1 octave up
        tones.append(chordRootMIDI + 19)                    // 5th, octave+fifth up
        tones.append(useAdd9 ? chordRootMIDI + 24 + secondStep : chordRootMIDI + 24) // 9th or doubled root, top
        if Float.random(in: 0...1, using: &rng) < 0.6 {
            tones.append(chordRootMIDI + 31) // 5th voice: fifth doubled high, ~60% of chords
        }

        return ChordSpec(rootMIDI: chordRootMIDI, tones: tones, name: name)
    }

    /// Generates a sparse, motif-based melody: a base "phrase" of 2-5 notes
    /// across a 2-bar (32-tick) window from the key's minor pentatonic,
    /// tiled across a 4-phrase (8-bar/128-tick) cycle where phrase 0 always
    /// plays (guarantees a non-empty scene), and phrases 1-3 each either
    /// repeat the base motif exactly, repeat it with an octave shift,
    /// repeat it with a neighbor-tone substitution on one note, or rest
    /// entirely (25% chance) -- "motif repeats across phrases with slight
    /// variation... occasionally resting for an entire phrase" per
    /// SPEC.md Addendum 3.
    static func generateMelodyMotif<R: RandomNumberGenerator>(rootPitchClass: Int, using rng: inout R) -> MelodyMotif {
        let keyRootMIDI = padRootAnchorMIDI + rootPitchClass
        let pentatonic = minorPentatonicIntervals
        func note(degree: Int, octave: Int) -> Int {
            let wrapped = ((degree % pentatonic.count) + pentatonic.count) % pentatonic.count
            return keyRootMIDI + pentatonic[wrapped] + 12 * octave
        }

        let phraseTicks = 32
        let phraseCount = 4

        // Base phrase: 2-5 sparse notes, minimum 5-tick gap between onsets
        // (long soft attacks -- avoid stacking notes too close together).
        let noteCount = Int.random(in: 2...5, using: &rng)
        var offsets: [Int] = []
        var cursor = Int.random(in: 0...3, using: &rng)
        while offsets.count < noteCount && cursor <= phraseTicks - 2 {
            offsets.append(cursor)
            cursor += Int.random(in: 5...9, using: &rng)
        }
        if offsets.isEmpty { offsets = [Int.random(in: 0...3, using: &rng)] }

        let baseDegrees = offsets.map { _ in Int.random(in: 0..<pentatonic.count, using: &rng) }
        // Octave 1 or 2 above the key root -- "1-2 octaves above the pads".
        let baseOctaves = offsets.map { _ in Int.random(in: 1...2, using: &rng) }

        var events: [MelodyNoteEvent] = []
        for phraseIndex in 0..<phraseCount {
            if phraseIndex > 0 {
                let restRoll = Float.random(in: 0...1, using: &rng)
                if restRoll < 0.25 { continue } // rest this phrase entirely
            }

            var degrees = baseDegrees
            var octaves = baseOctaves
            if phraseIndex > 0 {
                switch Int.random(in: 0...2, using: &rng) {
                case 0: // octave-shift variation
                    let dir = Bool.random(using: &rng) ? 1 : -1
                    octaves = octaves.map { clamp($0 + dir, 1, 2) }
                case 1: // neighbor-tone variation on a single note
                    if let idx = degrees.indices.randomElement(using: &rng) {
                        let dir = Bool.random(using: &rng) ? 1 : -1
                        degrees[idx] = ((degrees[idx] + dir) % pentatonic.count + pentatonic.count) % pentatonic.count
                    }
                default:
                    break // exact repeat
                }
            }

            for (i, offset) in offsets.enumerated() {
                let midi = note(degree: degrees[i], octave: octaves[i])
                let velocity = Float.random(in: 0.45...0.70, using: &rng) // "quiet", soft-floating
                events.append(MelodyNoteEvent(tickOffset: phraseIndex * phraseTicks + offset,
                                               midiNote: midi, velocity: velocity))
            }
        }

        return MelodyMotif(events: events, cycleTicks: phraseTicks * phraseCount)
    }

    // MARK: Drums (loop selection) -- unchanged by this addendum

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
