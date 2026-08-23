//
//  BasslinePattern.swift
//  LiminalGenerator
//
//  Sub-bass MOVEMENT variation (SPEC.md Addendum 3 -- replaces the old
//  walking/melodic bassline). The sub always follows the CURRENT BAR'S
//  CHORD ROOT, one octave below the pads -- this file no longer stores any
//  pitch/role information at all, only WHEN and HOW the sub re-articulates
//  within each bar. Pitches are resolved live in `LiminalDSPCore.doTick`
//  directly from the active scene's `ChordSpec.rootMIDI`, so the sub can
//  never "remember" a stale chord -- exactly the same never-stale-key
//  guarantee the pre-Addendum-3 bassline had, just simpler now that there's
//  no scale-degree indirection to resolve.
//
//  `regenerateBass()` re-rolls ONLY this movement variation -- it never
//  touches the key/progression (see SPEC.md: "GENERATE BASS re-rolls only
//  the bass movement variation").
//

import Foundation

/// One bar's worth of sub-bass behavior, applied against whatever chord
/// root is active for that bar (`ArpeggioPattern.progression[bar % 4]`):
///   - `.hold`: one note at the bar's downbeat, sustained the whole bar.
///   - `.reArticulate(times)`: `times` (2 or 4) evenly-spaced gentle
///     re-triggers of the SAME root within the bar -- a soft pulse rather
///     than a re-attack transient (`BassVoice`'s click-free retrigger).
///   - `.passingTone(atTick:semitoneOffset:)`: root at the downbeat, then a
///     brief passing tone (a fifth, +7, or an octave up, +12) near the bar
///     end, which resolves into the next bar's downbeat root -- "an
///     occasional octave-up or fifth passing tone at bar transitions".
enum BassBarAction: Sendable {
    case hold
    case reArticulate(times: Int)
    case passingTone(atTick: Int, semitoneOffset: Int)
}

/// Internal type -- no UI-facing readout (per SPEC.md: "Existing UI
/// (toggle/COLOR/LEVEL/GENERATE) unchanged").
struct BasslinePattern: Sendable {
    /// Exactly one action per bar of the (always 4-bar) progression cycle.
    var barActions: [BassBarAction]
}

enum BasslineGenerator {

    static func randomBasslinePattern() -> BasslinePattern {
        var rng = SystemRandomNumberGenerator()
        return randomBasslinePattern(using: &rng)
    }

    /// Re-rolls a fresh movement variation per bar (4 bars, matching the
    /// progression's fixed cycle length): weighted so held whole-bar drones
    /// are still the norm (55%), gentle re-articulation is common (25%),
    /// and a passing tone is an occasional accent (20%) -- "fewer notes,
    /// slower envelopes" per the musicality guardrails.
    static func randomBasslinePattern<R: RandomNumberGenerator>(using rng: inout R) -> BasslinePattern {
        let barCount = 4
        let actions = (0..<barCount).map { _ in randomAction(using: &rng) }
        return BasslinePattern(barActions: actions)
    }

    private static func randomAction<R: RandomNumberGenerator>(using rng: inout R) -> BassBarAction {
        let roll = Float.random(in: 0...1, using: &rng)
        switch roll {
        case ..<0.55:
            return .hold
        case ..<0.80:
            return .reArticulate(times: Bool.random(using: &rng) ? 2 : 4)
        default:
            let atTick = Int.random(in: 12...14, using: &rng) // near the bar's end
            let semitoneOffset = Bool.random(using: &rng) ? 12 : 7 // octave-up or fifth
            return .passingTone(atTick: atTick, semitoneOffset: semitoneOffset)
        }
    }
}
