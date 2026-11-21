import Foundation

/// The time source of the caches. Tests inject one.
typealias Now = @Sendable () -> Date

/// Caches `--version` and `--help` of each binary. A pinned binary changes rarely, and each session
/// would otherwise pay a spawn.
final class ProbeCache: FlagProbing, Sendable {
    static let ttl: TimeInterval = 300
    static let timeout: Duration = .seconds(5)

    private let versions: ExpiringCache<String, String>
    private let helps: ExpiringCache<String, String>
    private let flight = SingleFlight<String, String>()
    private let environment: @Sendable () async -> [String: String]
    private let timeout: Duration

    /// `environment` gives the child environment of a probe.
    init(
        environment: @escaping @Sendable () async -> [String: String], now: @escaping Now = Date.init,
        timeout: Duration = ProbeCache.timeout
    ) {
        self.environment = environment
        versions = ExpiringCache(ttl: Self.ttl, now: now)
        helps = ExpiringCache(ttl: Self.ttl, now: now)
        self.timeout = timeout
    }

    /// The first line of `<bin> --version`, at most 120 characters. It is nil when the probe fails.
    /// A failure is not cached.
    func version(_ bin: URL) async -> String? {
        if let v = versions.get(bin.path) { return v }
        let line = await flight.run("v:" + bin.path) { [environment, timeout] in
            let out = await Probe.run(bin, ["--version"], environment: await environment(), timeout: timeout)
            guard out.code != nil else { return "" }
            let first = out.text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? ""
            return String(first.trimmingCharacters(in: .whitespaces).prefix(120))
        }
        guard !line.isEmpty else { return nil }
        versions.set(bin.path, line)
        return line
    }

    /// The `<bin> --help` text, for a choice between two flags.
    func help(_ bin: URL) async -> String {
        if let h = helps.get(bin.path) { return h }
        let text = await flight.run("h:" + bin.path) { [environment, timeout] in
            await Probe.run(bin, ["--help"], environment: await environment(), timeout: timeout).text
        }
        helps.set(bin.path, text)
        return text
    }

    func supportsFlag(_ binary: URL, _ flag: String) async -> Bool {
        guard !flag.isEmpty else { return false }
        return await help(binary).contains(flag)
    }
}
