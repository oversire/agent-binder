import Foundation
import os

/// What a driver gets from the runtime: the client name, the frame cap, the probe caches, the
/// ledger and the binary resolver.
///
/// A custom driver uses it to find its binary and to probe flags. It hides the ``Runtime`` actor.
public struct RuntimeContext: Sendable {
    /// The product name that the harness sees in `clientInfo` and in the vendor client markers.
    public let clientName: String
    /// The product version next to ``clientName``.
    public let clientVersion: String
    /// The cap of one wire frame, in bytes.
    public let maxFrameBytes: Int
    /// The lifecycle log of the runtime.
    public let logger: Logger?

    let environment: [String: String]
    let resolver: BinaryResolver
    let probes: ProbeCache
    let ledger: Ledger
    let onStderr: (@Sendable (Harness, String) -> Void)?
    let fingerprintIgnoreEnvironment: [String]
    private let ids: Locked<Int>

    init(
        options o: Runtime.Options, environment: [String: String], now: @escaping Now,
        probeTimeout: Duration = ProbeCache.timeout
    ) {
        clientName = o.clientName.isEmpty ? "agentbinder" : o.clientName
        clientVersion = o.clientVersion
        maxFrameBytes = o.maxFrameBytes > 0 ? o.maxFrameBytes : FrameReader.defaultMaxBytes
        logger = o.logger
        self.environment = environment
        let resolver = BinaryResolver(
            .init(
                useLoginShellPath: o.useLoginShellPath, environment: environment, only: o.binarySearchPaths))
        self.resolver = resolver
        probes = ProbeCache(
            environment: {
                ChildEnvironment.merge(base: environment, overrides: [:], path: await resolver.childPath())
            }, now: now, timeout: probeTimeout)
        ledger = Ledger(path: o.ledger)
        onStderr = o.onStderr
        fingerprintIgnoreEnvironment = o.fingerprintIgnoreEnvironment
        ids = Locked(0)
    }

    /// The executable of a harness: the override, else the first match on the search path.
    public func resolveBinary(_ h: Harness, override: URL? = nil) async throws -> URL {
        try await resolver.resolve(h.binaryName, harness: h, override: override)
    }

    /// The first line of `<binary> --version`. It is cached for five minutes.
    public func version(of binary: URL) async -> String? {
        await probes.version(binary)
    }

    /// The `<binary> --help` text. It is cached for five minutes.
    public func helpText(of binary: URL) async -> String {
        await probes.help(binary)
    }

    /// True when `<binary> --help` names the flag.
    public func supportsFlag(_ flag: String, binary: URL) async -> Bool {
        await probes.supportsFlag(binary, flag)
    }

    /// The environment of a child: the runtime environment with the search path, and then the overrides.
    public func childEnvironment(_ overrides: [String: String]) async -> [String: String] {
        ChildEnvironment.merge(base: environment, overrides: overrides, path: await resolver.childPath())
    }

    /// A request id that is unique in this runtime.
    public func nextID() -> Int {
        ids.withLock {
            $0 += 1
            return $0
        }
    }

    /// Records a child that has no session, for example a shared server, so that
    /// ``Runtime/reconcile()`` can kill it after a crash.
    public func track(key: String, harness: Harness, pid: Int32, pgid: Int32?, argv: [String]) {
        ledger.track(key: key, harness: harness, pid: pid, pgid: pgid, argv: argv)
    }

    /// Removes a row that ``track(key:harness:pid:pgid:argv:)`` added.
    public func untrack(key: String) {
        ledger.remove(key)
    }

    /// Adds a hook that ``Runtime/close()`` runs, for a shared resource such as a server pool.
    public func onRuntimeClose(_ hook: @escaping @Sendable () async -> Void) {
        ledger.onCloseAll(hook)
    }

    // MARK: driver plumbing

    var launchBuilder: LaunchBuilder {
        LaunchBuilder(clientName: clientName, resolver: resolver, flags: probes)
    }

    func wireConfig(_ r: StartRequest) -> WireConfig {
        var c = WireConfig()
        c.maxFrameBytes = maxFrameBytes
        c.logPath = r.frameLog
        c.recordPath = recordPath(r.harness)
        if let t = r.handshakeTimeout { c.handshakeTimeout = t }
        return c
    }

    /// The environment key of the fixture recorder. Its value is a folder.
    static let recordEnvironmentKey = "AGENTBINDER_RECORD"

    // One new fixture file for each session: `<dir>/<harness>-<time>-<id>.ndjson`.
    private func recordPath(_ h: Harness) -> URL? {
        guard let dir = environment[Self.recordEnvironmentKey], !dir.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        return folder.appendingPathComponent("\(h.rawValue)-\(stamp)-\(nextID()).ndjson")
    }

    /// The stderr hook of one child: the hook of the request, then the hook of the runtime.
    func stderrHook(_ h: Harness, _ r: StartRequest?) -> (@Sendable (String) -> Void)? {
        let a = r?.onStderr
        let b = onStderr
        if a == nil && b == nil { return nil }
        return { line in
            a?(h, line)
            b?(h, line)
        }
    }

    /// Spawns a prepared launch and starts a wire session on it. The session removes the temp paths.
    func startWire(
        _ r: StartRequest, _ launch: Launch, adapter: any WireAdapter, directory: URL? = nil
    ) async throws -> WireSession {
        let child: ChildProcess
        do {
            child = try ChildProcess.spawn(
                SpawnOptions(
                    executable: launch.binary, arguments: launch.arguments,
                    directory: directory ?? r.workingDirectory,
                    environment: await childEnvironment(launch.environment), onStderrLine: stderrHook(r.harness, r)))
        } catch {
            launch.cleanup()
            throw error
        }
        return try await WireSession.start(
            harness: r.harness, process: child, adapter: adapter, config: wireConfig(r), onClose: [launch.cleanup])
    }
}
