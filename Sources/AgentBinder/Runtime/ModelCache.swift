import Foundation

/// Caches the model list of each install and home. A list can need a child process.
final class ModelCache: Sendable {
    /// A failed probe stays short, so a login fixes the list fast.
    static let errorTTL: TimeInterval = 30
    static let probeTimeout: Duration = .seconds(20)

    struct Key: Hashable, Sendable {
        var harness: Harness
        var bin: String
        var version: String
        var home: String
    }

    struct Entry: Sendable {
        var at: Date
        var value: Result<[ModelInfo], any Error>

        func isFresh(at t: Date, ttl: TimeInterval) -> Bool {
            var ttl = ttl
            if case .failure = value { ttl = min(ttl, ModelCache.errorTTL) }
            return t.timeIntervalSince(at) < ttl
        }
    }

    private let entries = Locked<[Key: Entry]>([:])
    private let flight = SingleFlight<Key, Entry>()
    private let ttl: TimeInterval
    private let now: Now

    /// A negative `ttl` turns the cache off.
    init(ttl: Duration, now: @escaping Now = Date.init) {
        self.ttl = ttl.timeInterval
        self.now = now
    }

    /// The cached list, else the result of one probe for all concurrent callers.
    func models(_ key: Key, probe: @escaping @Sendable () async throws -> [ModelInfo]) async throws -> [ModelInfo] {
        guard ttl >= 0 else { return try await probe() }
        if let e = fresh(key) { return try e.value.get() }
        let e = await flight.run(key) {
            if let e = self.fresh(key) { return e }
            let value: Result<[ModelInfo], any Error>
            do { value = .success(try await probe()) } catch { value = .failure(error) }
            let e = Entry(at: self.now(), value: value)
            self.entries.withLock { $0[key] = e }
            return e
        }
        return try e.value.get()
    }

    func invalidate(_ h: Harness) {
        entries.withLock { $0 = $0.filter { $0.key.harness != h } }
    }

    private func fresh(_ key: Key) -> Entry? {
        let t = now()
        return entries.withLock { m in
            guard let e = m[key], e.isFresh(at: t, ttl: ttl) else { return nil }
            return e
        }
    }
}
