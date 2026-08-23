//
//  BassSequencer.swift
//  LiminalGenerator
//
//  Sample-accurate step "clock" for the sub-bass movement pattern
//  (SPEC.md Addendum 3). Unlike the pre-Addendum-3 version, this no longer
//  carries pitch information at all -- it just decides, for a given
//  (bar-in-cycle, tick-in-bar) position, whether the sub should retrigger
//  this tick and by what semitone offset from the bar's chord root (0 for
//  the plain root, or the passing-tone offset). `LiminalDSPCore.doTick`
//  resolves the actual absolute MIDI pitch by reading the CURRENT scene's
//  chord root live, every time -- see that file for the "always in key"
//  guarantee this preserves.
//

import Foundation

final class BassSequencer {
    private(set) var activePattern: BasslinePattern
    private var pendingPattern: BasslinePattern?

    init(initialPattern: BasslinePattern) {
        activePattern = initialPattern
    }

    /// Queue a pattern swap; only actually applied at the next bar boundary
    /// (`tickInBar == 0`) by `advanceTick`, so a swap mid-bar never yanks a
    /// re-articulation or passing-tone schedule out from under audio
    /// already in flight.
    func queuePatternSwap(_ pattern: BasslinePattern) {
        pendingPattern = pattern
    }

    enum StepResult: Equatable {
        /// No bass event this tick -- the voice just keeps sustaining
        /// whatever it was already playing.
        case none
        /// Trigger (or retrigger) the bass at `chordRoot - 12 +
        /// semitoneOffset` (semitoneOffset is 0 for a plain root hit, or
        /// +7/+12 for a passing tone).
        case note(semitoneOffset: Int)
    }

    /// Called once per shared 16th-note tick with the scene-relative bar
    /// index (0...3, already wrapped to the progression's 4-bar cycle by
    /// the caller) and tick-within-bar (0...15).
    func advanceTick(barIndexInCycle: Int, tickInBar: Int) -> StepResult {
        if tickInBar == 0, let pending = pendingPattern {
            activePattern = pending
            pendingPattern = nil
        }
        guard activePattern.barActions.indices.contains(barIndexInCycle) else { return .none }

        switch activePattern.barActions[barIndexInCycle] {
        case .hold:
            return tickInBar == 0 ? .note(semitoneOffset: 0) : .none
        case .reArticulate(let times):
            let stepTicks = max(1, 16 / max(1, times))
            return (tickInBar % stepTicks == 0) ? .note(semitoneOffset: 0) : .none
        case .passingTone(let atTick, let semitoneOffset):
            if tickInBar == 0 { return .note(semitoneOffset: 0) }
            if tickInBar == atTick { return .note(semitoneOffset: semitoneOffset) }
            return .none
        }
    }
}
