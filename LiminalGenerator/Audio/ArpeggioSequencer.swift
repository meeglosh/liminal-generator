//
//  ArpeggioSequencer.swift
//  LiminalGenerator
//
//  Sample-accurate step clock for the arpeggio. Ticks are driven by the
//  shared 16th-note grid maintained in `LiminalDSPCore` (no Timers). This
//  type just owns the active pattern + step index and knows how to advance
//  and trigger notes into a `SynthVoiceBank`.
//

import Foundation

final class ArpeggioSequencer {
    private(set) var activePattern: ArpeggioPattern
    private var pendingPattern: ArpeggioPattern?
    private var stepIndex: Int = 0

    init(initialPattern: ArpeggioPattern) {
        activePattern = initialPattern
    }

    /// Queue a pattern swap; applied at the next tick boundary so a swap
    /// mid-render never glitches audio already in flight.
    func queuePatternSwap(_ pattern: ArpeggioPattern) {
        pendingPattern = pattern
    }

    /// Ticks per pattern step on the shared 16th-note grid: an 8-step
    /// pattern plays on eighth notes (2 ticks/step), a 16-step pattern
    /// plays on sixteenth notes (1 tick/step).
    var ticksPerStep: Int {
        max(1, 16 / max(1, activePattern.steps.count))
    }

    /// Called once per global 16th-note tick. Returns the step that should
    /// sound this tick, or nil if this tick isn't a pattern-step boundary
    /// (only relevant for 8-step patterns, which only advance every other tick).
    func advanceTick(globalTickIndex: Int) -> ArpStep? {
        if globalTickIndex % ticksPerStep != 0 { return nil }

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
