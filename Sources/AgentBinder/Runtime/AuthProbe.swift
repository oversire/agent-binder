import Foundation

/// The best-effort login state of each harness. It never fails: a probe that is not conclusive gives
/// ``AuthState/unknown``.
final class AuthProbe: Sendable {
    static let timeout: Duration = .seconds(10)

    struct Result: Sendable, Equatable {
        var state: AuthState
        var detail: String?
    }

    private struct Key: Hashable, Sendable {
        var harness: Harness
        var bin: String
    }

    private struct Entry {
        var at: Date
        var result: Result
    }

    private let cache = Locked<[Key: Entry]>([:])
    private let flight = SingleFlight<Key, Result>()
    private let ttl: TimeInterval
    private let environment: [String: String]
    private let childEnvironment: @Sendable () async -> [String: String]
    private let now: Now

    /// `environment` is the parent environment for the key check. `childEnvironment` gives the
    /// environment of the probe child. A negative `ttl` turns the cache off.
    init(
        ttl: Duration, environment: [String: String],
        childEnvironment: @escaping @Sendable () async -> [String: String], now: @escaping Now = Date.init
    ) {
        self.ttl = ttl.timeInterval
        self.environment = environment
        self.childEnvironment = childEnvironment
        self.now = now
    }

    // Presence only. The library never reads the value of a key.
    static func environmentKeys(_ h: Harness) -> [String] {
        switch h {
        case .claude: return ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"]
        case .codex: return ["OPENAI_API_KEY"]
        case .gemini: return ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .copilot: return ["GITHUB_TOKEN", "GH_TOKEN"]
        default: return []
        }
    }

    static func arguments(_ h: Harness) -> [String]? {
        switch h {
        case .claude: return ["auth", "status"]
        case .codex: return ["login", "status"]
        case .opencode, .opencode2: return ["auth", "list"]
        default: return nil
        }
    }

    /// Maps the output of the login command. Nil means the output is not conclusive.
    static func parse(_ h: Harness, _ out: Probe.Output) -> Result? {
        let low = out.text.lowercased()
        switch h {
        case .claude:
            if let v = JSONValue.parse(out.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                let logged = v["loggedIn"]?.bool
            {
                return logged ? Result(state: .ok, detail: v["email"]?.string) : Result(state: .missing)
            }
            if low.contains("not logged") || low.contains(#""loggedin": false"#) { return Result(state: .missing) }
            if low.contains("logged in") || low.contains(#""loggedin": true"#) { return Result(state: .ok) }
            return nil
        case .codex:
            if low.contains("not logged in") || low.contains("logged out") { return Result(state: .missing) }
            if low.contains("logged in") { return Result(state: .ok) }
            return nil
        case .opencode, .opencode2:
            guard out.code == 0 else { return nil }
            return Result(state: out.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .ok)
        default:
            return nil
        }
    }

    func state(_ h: Harness, bin: URL) async -> Result {
        for k in Self.environmentKeys(h) where !(environment[k] ?? "").isEmpty {
            return Result(state: .ok, detail: "key " + k)
        }
        guard let args = Self.arguments(h) else { return Result(state: .unknown) }
        let key = Key(harness: h, bin: bin.path)
        if let r = fresh(key) { return r }
        return await flight.run(key) {
            if let r = self.fresh(key) { return r }
            let out = await Probe.run(bin, args, environment: await self.childEnvironment(), timeout: Self.timeout)
            let r = Self.parse(h, out) ?? Result(state: .unknown)
            if self.ttl >= 0 {
                let e = Entry(at: self.now(), result: r)
                self.cache.withLock { $0[key] = e }
            }
            return r
        }
    }

    /// Drops the cached probes of one harness, for example after a login or a logout.
    func invalidate(_ h: Harness) {
        cache.withLock { $0 = $0.filter { $0.key.harness != h } }
    }

    private func fresh(_ key: Key) -> Result? {
        guard ttl >= 0 else { return nil }
        let t = now()
        return cache.withLock { c in
            guard let e = c[key], t.timeIntervalSince(e.at) < ttl else { return nil }
            return e.result
        }
    }
}
