import os

/// A value behind an unfair lock. `Mutex` needs macOS 15, and the floor is macOS 13.
final class Locked<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }

    func withLock<R: Sendable>(_ body: @Sendable (inout Value) throws -> R) rethrows -> R {
        try lock.withLock(body)
    }

    var value: Value { lock.withLock { $0 } }
}
