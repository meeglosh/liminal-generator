//
//  SceneSequencer.swift
//  LiminalGenerator
//
//  Replaces the pre-Addendum-3 `ArpeggioSequencer` (deleted -- its step-
//  index-based arp-stepping logic has no analog in the ambient-pad engine).
//  This is a much thinner object: it just holds the active generated
//  "scene" (`ArpeggioPattern`, repurposed per SPEC.md Addendum 3) and swaps
//  in a pending one at the next bar boundary. All the actual chord/melody/
//  bass triggering logic lives in `LiminalDSPCore.doTick`, which reads
//  `activeScene` directly (chords + melody motif are fully pre-resolved
//  absolute-MIDI data at generation time, so there's no per-tick music
//  theory to do here -- see `PatternGenerator.swift`).
//

import Foundation

final class SceneSequencer {
    private(set) var activeScene: ArpeggioPattern
    private var pendingScene: ArpeggioPattern?

    init(initialScene: ArpeggioPattern) {
        activeScene = initialScene
    }

    /// Queue a new scene; picked up by the render thread and applied only
    /// at the next bar boundary (see `applyPendingSwapAtBarBoundary`) so a
    /// regenerate mid-bar never cuts off an in-flight chord swell.
    func queueSceneSwap(_ scene: ArpeggioPattern) {
        pendingScene = scene
    }

    /// Call exactly at a bar boundary (`globalTickIndex % 16 == 0`).
    /// Returns `true` if a swap was applied this call -- the caller uses
    /// this to reset its "scene-relative tick" reference so the new
    /// scene's progression and melody motif always start fresh at their
    /// own bar/phrase 0, rather than resuming mid-cycle against the old
    /// scene's absolute tick position.
    @discardableResult
    func applyPendingSwapAtBarBoundary() -> Bool {
        guard let pending = pendingScene else { return false }
        activeScene = pending
        pendingScene = nil
        return true
    }
}
