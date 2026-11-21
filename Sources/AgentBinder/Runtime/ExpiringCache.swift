import Foundation

/// A map whose values expire. The owner decides what to do with a negative TTL.
final class ExpiringCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        var at: Date
        var value: Value
    }

    private let entries = Locked<[Key: Entry]>([:])
    private let now: Now
    private let maxAge: @Sendable (Value) -> TimeInterval

    /// Every value lives `ttl` seconds.
    convenience init(ttl: TimeInterval, now: @escaping Now) {
        self.init(now: now) { _ in ttl }
    }

    /// The age limit comes from the value.
    init(now: @escaping Now, maxAge: @escaping @Sendable (Value) -> TimeInterval) {
        self.now = now
        self.maxAge = maxAge
    }

    /// The value, when it is younger than its age limit. An old entry stays until `set` replaces it.
    func get(_ key: Key) -> Value? {
        let t = now()
        return entries.withLock { m in
            guard let e = m[key], t.timeIntervalSince(e.at) < maxAge(e.value) else { return nil }
            return e.value
        }
    }

    func set(_ key: Key, _ value: Value) {
        let e = Entry(at: now(), value: value)
        entries.withLock { $0[key] = e }
    }

    func removeAll(where shouldRemove: @Sendable (Key) -> Bool) {
        entries.withLock { $0 = $0.filter { !shouldRemove($0.key) } }
    }
}
