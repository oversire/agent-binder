import Foundation
import os

/// The entry point of the library. It owns all per-process state: the driver table, the probe and
/// model caches, the ledger and the id counter.
///
/// Two runtimes in one process share nothing.
public actor Runtime {
    /// The configuration of a runtime.
    public struct Options: Sendable {
        /// The product name that the harness sees in `clientInfo` and in the vendor client markers.
        public var clientName: String
        /// The product version next to ``clientName``.
        public var clientVersion: String
        /// The crash ledger file. Nil turns the file off; the runtime still closes its live sessions.
        public var ledger: URL?
        /// The lifecycle log.
        public var logger: Logger?
        /// Environment keys that the OpenCode server fingerprint ignores, so values for each run do
        /// not split a shared server.
        public var fingerprintIgnoreEnvironment: [String]
        /// The cap of one wire frame, in bytes.
        public var maxFrameBytes: Int
        /// Receives each stderr line of each child.
        public var onStderr: (@Sendable (Harness, String) -> Void)?
        /// How long a login probe answers from the cache. A negative value turns the cache off.
        public var authCacheTTL: Duration
        /// How long a model list answers from the cache. A negative value turns the cache off.
        public var modelCacheTTL: Duration
        /// When set, the binary resolver searches only these folders.
        public var binarySearchPaths: [URL]?
        /// Read the `PATH` of the login shell, because a GUI app gets a short `PATH`.
        public var useLoginShellPath: Bool
        /// The parent environment of each child. Nil reads the environment of this process.
        public var environment: [String: String]?

        /// Makes a configuration.
        public init(
            clientName: String = "agentbinder", clientVersion: String = "", ledger: URL? = nil,
            logger: Logger? = nil, fingerprintIgnoreEnvironment: [String] = [],
            maxFrameBytes: Int = 16 << 20, onStderr: (@Sendable (Harness, String) -> Void)? = nil,
            authCacheTTL: Duration = .seconds(300), modelCacheTTL: Duration = .seconds(600),
            binarySearchPaths: [URL]? = nil, useLoginShellPath: Bool = true,
            environment: [String: String]? = nil
        ) {
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.ledger = ledger
            self.logger = logger
            self.fingerprintIgnoreEnvironment = fingerprintIgnoreEnvironment
            self.maxFrameBytes = maxFrameBytes
            self.onStderr = onStderr
            self.authCacheTTL = authCacheTTL
            self.modelCacheTTL = modelCacheTTL
            self.binarySearchPaths = binarySearchPaths
            self.useLoginShellPath = useLoginShellPath
            self.environment = environment
        }
    }

    static let limitsTimeout: Duration = .seconds(15)

    /// The minimum vendor versions that the library supports.
    static func versionFloor(_ h: Harness) -> String? {
        h == .claude ? "2.0.0" : nil
    }

    /// The services that drivers get.
    public nonisolated let context: RuntimeContext

    private let builtIn: [Harness: any Driver]
    private var drivers: [Harness: any Driver]
    private let auth: AuthProbe
    private let modelCache: ModelCache
    private var closed = false

    /// Makes a runtime.
    public init(options: Options = .init()) {
        self.init(options: options, now: Date.init)
    }

    /// Tests raise `probeTimeout`: the first run of a new script can wait for a system scan.
    init(options: Options, now: @escaping Now, probeTimeout: Duration = ProbeCache.timeout) {
        let env = options.environment ?? ProcessInfo.processInfo.environment
        let ctx = RuntimeContext(options: options, environment: env, now: now, probeTimeout: probeTimeout)
        context = ctx
        builtIn = DriverTable.builtIn()
        drivers = builtIn
        auth = AuthProbe(
            ttl: options.authCacheTTL, environment: env, childEnvironment: { await ctx.childEnvironment([:]) },
            now: now)
        modelCache = ModelCache(ttl: options.modelCacheTTL, now: now)
    }

    // MARK: drivers

    /// Replaces the driver of a harness. Nil restores the built-in driver, or removes a custom one.
    public func setDriver(_ d: (any Driver)?, for h: Harness) {
        drivers[h] = d ?? builtIn[h]
    }

    /// The driver of a harness.
    public func driver(for h: Harness) -> (any Driver)? { drivers[h] }

    // MARK: sessions

    /// Starts a new session. It returns after the protocol handshake.
    public func start(_ r: StartRequest) async throws -> any Session {
        try await open(r, resume: false)
    }

    /// Opens a known session again. It throws ``AgentBinderError/resumeUnsupported`` when the vendor
    /// does not know the session, or the protocol has no resume.
    public func resume(_ r: StartRequest) async throws -> any Session {
        try await open(r, resume: true)
    }

    private func open(_ r: StartRequest, resume: Bool) async throws -> any Session {
        if closed { throw AgentBinderError.sessionClosed }
        guard let d = drivers[r.harness] else { throw AgentBinderError.noDriver(r.harness) }
        // An in-process driver answers for itself; a child of a sandboxed app cannot run a vendor CLI.
        if !(d is SelfDetecting) && SandboxCheck.isSandboxed(context.environment) {
            throw AgentBinderError.sandboxed
        }
        let ctx = context
        let s = try await resume ? d.resume(r, runtime: ctx) : d.start(r, runtime: ctx)
        context.ledger.add(s)
        return s
    }

    // MARK: detect

    /// Probes one harness: the binary, the version, the floor and the login state.
    ///
    /// A missing binary is a verdict, not an error.
    public func detect(_ h: Harness) async -> Detection {
        var d = Detection(harness: h, features: .builtIn(h))
        if h == .fake {
            // The fake harness runs a script; it has no vendor binary and no login.
            d.supported = true
            d.auth = .ok
            d.ready = true
            return d
        }
        guard let driver = drivers[h] else {
            d.detail = .noDriver
            return d
        }
        if let sd = driver as? SelfDetecting {
            guard var own = try? await sd.detect(runtime: context) else { return d }
            own.harness = h
            if own.features == Features() { own.features = .builtIn(h) }
            own.ready = own.supported && own.auth == .ok
            return own
        }
        if SandboxCheck.isSandboxed(context.environment) {
            d.detail = .sandboxed
            return d
        }
        guard let bin = try? await context.resolveBinary(h) else {
            d.detail = .notInstalled
            return d
        }
        d.path = bin
        d.version = await context.version(of: bin)
        if let floor = Self.versionFloor(h), let v = d.version, !semverAtLeast(v, floor) {
            d.detail = .belowFloor(floor)
            return d
        }
        d.supported = true
        let a = await auth.state(h, bin: bin)
        d.auth = a.state
        d.authDetail = a.detail
        d.ready = a.state == .ok
        return d
    }

    /// Probes every built-in harness in parallel, in the order of ``Harness/allBuiltIn``.
    public func detectAll() async -> [Detection] {
        let all = Harness.allBuiltIn
        let found = await withTaskGroup(of: (Int, Detection).self) { g in
            for (i, h) in all.enumerated() { g.addTask { (i, await self.detect(h)) } }
            var out: [Int: Detection] = [:]
            for await (i, d) in g { out[i] = d }
            return out
        }
        return all.indices.compactMap { found[$0] }
    }

    /// Drops the cached login probes of one harness, for example after a login or a logout.
    public func invalidateDetect(_ h: Harness) {
        auth.invalidate(h)
    }

    // MARK: models and limits

    /// Lists the models of one harness. It answers from a cache; the first call can start a
    /// short-lived child. A harness that lists no models throws ``AgentBinderError/unsupported(_:)``.
    public func models(_ h: Harness, query: ModelQuery = .init()) async throws -> [ModelInfo] {
        guard let d = drivers[h] else { throw AgentBinderError.noDriver(h) }
        guard let lister = d as? ModelListing else { throw AgentBinderError.unsupported("\(h) lists no models") }
        let ctx = context
        var bin = query.binary
        if bin == nil, h != .fake, h != .native { bin = try? await ctx.resolveBinary(h) }
        var version = ""
        if let bin { version = await ctx.version(of: bin) ?? "" }
        let key = ModelCache.Key(harness: h, bin: bin?.path ?? "", version: version, home: query.home?.path ?? "")
        return try await modelCache.models(key) {
            try await Deadline.run(ModelCache.probeTimeout, onTimeout: AgentBinderError.timeout("\(h) models")) {
                try await lister.models(query, runtime: ctx)
            }
        }
    }

    /// Drops the cached model lists of one harness, for example after a login or a config change.
    public func invalidateModels(_ h: Harness) {
        modelCache.invalidate(h)
    }

    /// Reads the plan limits of the account. It is never cached.
    public func limits(_ h: Harness, query: ModelQuery = .init()) async throws -> Limits {
        guard let d = drivers[h] else { throw AgentBinderError.noDriver(h) }
        guard let reader = d as? LimitsReading else { throw AgentBinderError.unsupported("\(h) reads no limits") }
        let ctx = context
        return try await Deadline.run(Self.limitsTimeout, onTimeout: AgentBinderError.timeout("\(h) limits")) {
            try await reader.readLimits(query, runtime: ctx)
        }
    }

    // MARK: lifecycle

    /// Kills the children that a previous process left in the ledger, and drops the ledger.
    ///
    /// Only a matched pid dies: a reused pid is left alone.
    public func reconcile() {
        let killed = context.ledger.reconcile()
        if !killed.isEmpty {
            context.logger?.info("agentbinder: reconciled \(killed.count) stale children")
        }
    }

    /// Closes every live session and shared server, in parallel, and waits. A second call does nothing.
    public func close() async {
        guard !closed else { return }
        closed = true
        await context.ledger.closeAll()
    }
}
