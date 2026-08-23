//
//  ParameterBus.swift
//  LiminalGenerator
//
//  Lock-free control -> audio thread communication.
//
//  Design: parameters and pre-built pattern buffers are wrapped in small
//  immutable snapshot classes. The control (main) thread publishes a new
//  snapshot by assigning it to a `var` reference; the render thread reads
//  the current reference. A reference (pointer-sized) load/store is a
//  single atomic hardware operation on arm64/x86_64, so the render thread
//  can never observe a torn/partially-written snapshot -- it either sees
//  the old snapshot or the fully-formed new one, with no lock and no
//  allocation on the render thread (allocation happens on the publishing
//  side only, when a new snapshot is created).
//
//  This is the standard "lock-free snapshot struct" pattern referenced by
//  the architecture spec, adapted to not require the Swift `Synchronization`
//  atomics module (iOS 18+ only; this app targets iOS 17).
//

import Foundation

/// Continuous parameters that affect the DSP graph. Immutable -- a new
/// instance is published whenever any field changes.
final class ParamSnapshot: @unchecked Sendable {
    let space: Float
    let age: Float
    let drumsEnabled: Bool
    let drumLevel: Float
    let speed: Float
    let color: Float

    init(space: Float, age: Float, drumsEnabled: Bool, drumLevel: Float, speed: Float, color: Float) {
        self.space = space
        self.age = age
        self.drumsEnabled = drumsEnabled
        self.drumLevel = drumLevel
        self.speed = speed
        self.color = color
    }

    static let initial = ParamSnapshot(space: 0.55, age: 0.4, drumsEnabled: false, drumLevel: 0.65,
                                        speed: 0.5, color: 0.5)
}

/// Wraps a value type (e.g. `ArpeggioPattern`, `DrumPattern`) in a class so
/// it can be published through `SnapshotBox`, which relies on reference
/// (pointer-sized) assignment being atomic -- a plain struct assignment of
/// a multi-field value would not be.
final class ValueBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Single-writer/single-reader box for a snapshot reference. Not a generic
/// lock -- just a named wrapper so the "publish/read" contract is explicit
/// at call sites.
final class SnapshotBox<T: AnyObject>: @unchecked Sendable {
    private var value: T

    init(_ initial: T) {
        value = initial
    }

    /// Called from the control (main) thread only.
    func publish(_ newValue: T) {
        value = newValue
    }

    /// Called from the render thread only. Returns the reference currently
    /// visible; safe because reference assignment/read is atomic-sized.
    func read() -> T {
        value
    }
}
