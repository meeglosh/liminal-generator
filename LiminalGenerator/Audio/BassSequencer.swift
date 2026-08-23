//
//  BassSequencer.swift
//  LiminalGenerator
//
//  Sample-accurate step "clock" for the bassline -- mirrors
//  `ArpeggioSequencer`'s pattern-swap-at-tick-boundary design, but simpler:
//  `BasslinePattern.steps` is always exactly 16 entries, one per shared
//  16th-note tick (same grid the melody/loop already run on -- see
//  `LiminalDSPCore.doTick`), so there is no `ticksPerStep` variability to
//  account for. Ticks always advance regardless of `bassEnabled` -- the
//  bassline stays phase-locked to the shared clock even while muted, so
//  re-enabling it never needs a resync.
//

import Foundation

final class BassSequencer {
    private(set) var activePattern: BasslinePattern
    private var pendingPattern: BasslinePattern?
    private var stepIndex: Int = 0

    init(initialPattern: BasslinePattern) {
        activePattern = initialPattern
    }

    /// Queue a pattern swap; applied at the next tick so a swap mid-render
    /// never glitches audio already in flight.
    func queuePatternSwap(_ pattern: BasslinePattern) {
        pendingPattern = pattern
    }

    /// Called once per global 16th-note tick. Returns the step for this
    /// tick, or nil only if the pattern is somehow empty (defensive).
    func advanceTick() -> BassStep? {
        if let pending = pendingPattern {
            activePattern = pending
            pendingPattern = nil
            stepIndex = 0
        }
        guard !activePattern.steps.isEmpty else { return nil }
        let step = activePattern.steps[stepIndex % activePattern.steps.count]
        stepIndex += 1
        return step
    }
}
