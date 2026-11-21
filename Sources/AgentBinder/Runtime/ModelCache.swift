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

    private let entries: ExpiringCache<Key, Result<[ModelInfo], any Error>>
    private let flight = SingleFlight<Key, Result<[ModelInfo], any Error>>()
    private let ttl: TimeInterval

    /// A negative `ttl` turns the cache off.
    init(ttl: Duration, now: @escaping Now = Date.init) {
        let ttl = ttl.timeInterval
        self.ttl = ttl
        entries = ExpiringCache(now: now) { value in
            if case .failure = value { return min(ttl, ModelCache.errorTTL) }
            return ttl
        }
    }

    /// The cached list, else the result of one probe for all concurrent callers.
    func models(_ key: Key, probe: @escaping @Sendable () async throws -> [ModelInfo]) async throws -> [ModelInfo] {
        guard ttl >= 0 else { return try await probe() }
        if let v = entries.get(key) { return try v.get() }
        let v = await flight.run(key) {
            if let v = self.entries.get(key) { return v }
            let value: Result<[ModelInfo], any Error>
            do { value = .success(try await probe()) } catch { value = .failure(error) }
            self.entries.set(key, value)
            return value
        }
        return try v.get()
    }

    func invalidate(_ h: Harness) {
        entries.removeAll { $0.harness == h }
    }
}
