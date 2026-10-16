import Foundation

/// The time source of the caches. Tests inject one.
typealias Now = @Sendable () -> Date

/// Caches `--version` and `--help` of each binary. A pinned binary changes rarely, and each session
/// would otherwise pay a spawn.
final class ProbeCache: FlagProbing, Sendable {
    static let ttl: TimeInterval = 300
    static let timeout: Duration = .seconds(5)

    private struct Entry {
        var at: Date
        var text: String
    }

    private let versions = Locked<[String: Entry]>([:])
    private let helps = Locked<[String: Entry]>([:])
    private let flight = SingleFlight<String, String>()
    private let environment: @Sendable () async -> [String: String]
    private let now: Now

    /// `environment` gives the child environment of a probe.
    init(environment: @escaping @Sendable () async -> [String: String], now: @escaping Now = Date.init) {
        self.environment = environment
        self.now = now
    }

    /// The first line of `<bin> --version`, at most 120 characters. It is nil when the probe fails.
    /// A failure is not cached.
    func version(_ bin: URL) async -> String? {
        if let v = fresh(versions, bin.path) { return v }
        let line = await flight.run("v:" + bin.path) { [environment] in
            let out = await Probe.run(bin, ["--version"], environment: await environment(), timeout: Self.timeout)
            guard out.code != nil else { return "" }
            let first = out.text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? ""
            return String(first.trimmingCharacters(in: .whitespaces).prefix(120))
        }
        guard !line.isEmpty else { return nil }
        store(versions, bin.path, line)
        return line
    }

    /// The `<bin> --help` text, for a choice between two flags.
    func help(_ bin: URL) async -> String {
        if let h = fresh(helps, bin.path) { return h }
        let text = await flight.run("h:" + bin.path) { [environment] in
            await Probe.run(bin, ["--help"], environment: await environment(), timeout: Self.timeout).text
        }
        store(helps, bin.path, text)
        return text
    }

    func supportsFlag(_ binary: URL, _ flag: String) async -> Bool {
        guard !flag.isEmpty else { return false }
        return await help(binary).contains(flag)
    }

    private func fresh(_ m: Locked<[String: Entry]>, _ key: String) -> String? {
        let t = now()
        return m.withLock { m in
            guard let e = m[key], t.timeIntervalSince(e.at) < Self.ttl else { return nil }
            return e.text
        }
    }

    private func store(_ m: Locked<[String: Entry]>, _ key: String, _ text: String) {
        let e = Entry(at: now(), text: text)
        m.withLock { $0[key] = e }
    }
}
