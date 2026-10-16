import Darwin
import Foundation

/// A session that a server sends its bus events to.
protocol OpenCodeRoute: AnyObject, Sendable {
    var routeID: String { get }
    func deliver(_ type: String, _ payload: JSONValue)
    /// The server stopped or its child died. The session ends.
    func serverGone(_ reason: String)
}

/// One `opencode serve` child: its origin and auth, the routing table and the event streams.
///
/// A server without a child points at a test server.
final class OpenCodeServer: Sendable {
    static let readyTimeout: Duration = .seconds(30)
    static let streamReadyTimeout: Duration = .seconds(10)
    static let retryMin: Duration = .milliseconds(250)
    static let retryMax: Duration = .seconds(10)
    static let stoppedText = "opencode serve stopped"

    /// Why a server did not become ready.
    enum ReadyFailure: Error, Equatable {
        /// The binary speaks the other wire. A retry does not help.
        case wrongWire(String)
        case failed(String)

        var error: AgentBinderError {
            switch self {
            case .wrongWire(let t):
                return .launch("opencode serve: wrong wire: \(t); the binary speaks another OpenCode version")
            case .failed(let t): return .launch(t)
            }
        }
    }

    private struct Stream {
        var task: Task<Void, Never>?
        let ready: Latch
    }

    private struct State {
        var routes: [String: any OpenCodeRoute] = [:]
        var streams: [String: Stream] = [:]
        var stopped = false
    }

    let http: OpenCodeHTTP
    let child: ChildProcess?
    let argv: [String]
    private let ledger: Ledger?
    private let state = Locked(State())

    init(http: OpenCodeHTTP, child: ChildProcess? = nil, argv: [String] = [], ledger: Ledger? = nil) {
        self.http = http
        self.child = child
        self.argv = argv
        self.ledger = ledger
        guard let child else { return }
        // Nobody reads the log on stdout, but a full pipe would block the child.
        Task.detached {
            while case .data = await child.readStdout() {}
        }
        Task.detached { [weak self] in
            _ = await child.waitForExit()
            self?.childExited()
        }
    }

    var wire: OpenCodeWire { http.wire }

    /// The ledger row of the child. The pid keeps it unique, and it holds no environment value.
    var ledgerKey: String { "\(wire.harness):serve-\(child?.pid ?? 0)" }

    var alive: Bool { !state.value.stopped && child?.exitStatus == nil }

    // MARK: readiness

    /// Polls the health path until the server answers, the child dies or the time ends.
    func waitReady(timeout: Duration = readyTimeout) async throws(ReadyFailure) {
        let end = ContinuousClock.now + timeout
        while true {
            if let child, child.exitStatus != nil {
                throw .failed(
                    "opencode serve exited early: \(child.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            switch await http.health() {
            case .ready: return
            case .wrongWire(let t): throw .wrongWire(t)
            case .notYet: break
            }
            if ContinuousClock.now >= end { throw .failed("opencode serve: health timeout") }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                throw .failed("opencode serve: cancelled")
            }
        }
    }

    // MARK: routing

    func subscribe(_ r: any OpenCodeRoute) {
        state.withLock { $0.routes[r.routeID] = r }
    }

    func unsubscribe(_ id: String) {
        state.withLock { _ = $0.routes.removeValue(forKey: id) }
    }

    func route(_ id: String) -> (any OpenCodeRoute)? { state.withLock { $0.routes[id] } }

    var routeIDs: [String] { state.withLock { Array($0.routes.keys) } }

    func dispatch(_ frame: Data) {
        guard let f = wire.frame(frame), let r = route(f.sessionID) else { return }
        r.deliver(f.type, f.payload)
    }

    // MARK: streams

    /// The number of open stream scopes, for tests.
    var streamCount: Int { state.withLock { $0.streams.count } }

    /// Opens the event stream of a scope once. V1 has a scope for each directory; V2 has one scope.
    /// It returns nil when the server is stopped.
    @discardableResult
    func ensureStream(_ directory: String) -> Latch? {
        let scope = wire.eventScoped ? directory : ""
        let (latch, isNew) = state.withLock { s -> (Latch?, Bool) in
            if s.stopped { return (nil, false) }
            if let st = s.streams[scope] { return (st.ready, false) }
            let l = Latch()
            s.streams[scope] = Stream(task: nil, ready: l)
            return (l, true)
        }
        guard let latch, isNew else { return latch }
        let t = Task.detached { [self] in await streamLoop(scope, latch) }
        let keep = state.withLock { s -> Bool in
            guard !s.stopped else { return false }
            s.streams[scope]?.task = t
            return true
        }
        if !keep { t.cancel() }
        return latch
    }

    /// Opens the stream of a scope and waits until it connects. Call it before a session create:
    /// the server does not replay events from before the connection.
    func ensureStreamReady(_ directory: String, timeout: Duration = streamReadyTimeout) async throws {
        guard let latch = ensureStream(directory) else { throw AgentBinderError.sessionClosed }
        guard await latch.wait(timeout: timeout) else {
            throw AgentBinderError.timeout("\(wire.harness) event stream")
        }
    }

    // Fixed on purpose: the wait doubles up to 10 s, and a good connection resets it.
    private func streamLoop(_ scope: String, _ ready: Latch) async {
        let sse = SSEClient(http: http)
        var wait = Self.retryMin
        while !Task.isCancelled {
            let opened = Locked(false)
            try? await sse.run(
                directory: scope,
                onOpen: {
                    opened.withLock { $0 = true }
                    ready.open()
                },
                onEvent: { [self] in dispatch($0) })
            if Task.isCancelled || !alive { return }
            if opened.value { wait = Self.retryMin }
            try? await Task.sleep(for: wait)
            wait = min(wait * 2, Self.retryMax)
        }
    }

    // MARK: stop

    /// Ends the streams, ends each routed session and closes the child. A second call does nothing.
    func stop() async {
        guard let routes = takeDown() else { return }
        for r in routes { r.serverGone(Self.stoppedText) }
        if let child { _ = await child.gracefulClose() }
    }

    private func childExited() {
        guard let routes = takeDown() else { return }
        let text = exitText
        for r in routes { r.serverGone(text) }
    }

    /// Marks the server stopped and returns the routed sessions. It returns nil on a second call.
    private func takeDown() -> [any OpenCodeRoute]? {
        let taken = state.withLock { s -> ([any OpenCodeRoute], [Task<Void, Never>])? in
            if s.stopped { return nil }
            s.stopped = true
            defer {
                s.routes = [:]
                s.streams = [:]
            }
            return (Array(s.routes.values), s.streams.values.compactMap(\.task))
        }
        guard let (routes, tasks) = taken else { return nil }
        for t in tasks { t.cancel() }
        if child != nil { ledger?.remove(ledgerKey) }
        http.close()
        return routes
    }

    /// Why the child died: the code and the first stderr line.
    var exitText: String {
        let code = child?.exitStatus?.code ?? -1
        let line = WireSession.firstLine(child?.stderrTail ?? "")
        return line.isEmpty
            ? "opencode serve exited with code \(code)" : "opencode serve exited with code \(code): \(line)"
    }

    // MARK: launch

    /// Spawns `<binary> serve` on a free loopback port and waits until it is ready. A lost port race
    /// gets two more tries; a wrong wire gets none.
    static func launch(
        wire: OpenCodeWire, binary: URL, environment: [String: String], arguments: [String],
        context ctx: RuntimeContext
    ) async throws -> OpenCodeServer {
        var env = environment
        env["OPENCODE_SERVER_PASSWORD"] = randomToken()
        if (env["OPENCODE_SERVER_USERNAME"] ?? "").isEmpty { env["OPENCODE_SERVER_USERNAME"] = "opencode" }
        let childEnv = await ctx.childEnvironment(env)
        var last = ReadyFailure.failed("opencode serve: no attempt")
        for _ in 0..<3 {
            let port = try freePort()
            let args = ["serve", "--port", String(port), "--hostname", "127.0.0.1"] + arguments
            let child: ChildProcess
            do {
                child = try ChildProcess.spawn(
                    SpawnOptions(
                        executable: binary, arguments: args, environment: childEnv,
                        onStderrLine: ctx.stderrHook(wire.harness, nil)))
            } catch {
                throw AgentBinderError.launch("\(wire.harness) serve: \(error)")
            }
            let http = OpenCodeHTTP(
                base: URL(string: "http://127.0.0.1:\(port)")!, username: env["OPENCODE_SERVER_USERNAME"]!,
                password: env["OPENCODE_SERVER_PASSWORD"]!, wire: wire, maxBytes: ctx.maxFrameBytes)
            let s = OpenCodeServer(http: http, child: child, argv: [binary.path] + args, ledger: ctx.ledger)
            do {
                try await s.waitReady()
            } catch {
                await child.killTree()
                http.close()
                last = error
                if case .wrongWire = error { break }
                continue
            }
            ctx.ledger.track(key: s.ledgerKey, harness: wire.harness, pid: child.pid, pgid: child.pgid, argv: s.argv)
            return s
        }
        throw last.error
    }

    static func randomToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    // The port is free when it returns; the child can still lose it to another process.
    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentBinderError.launch("socket: \(String(cString: strerror(errno)))") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(fd, sp, len) == 0 && getsockname(fd, sp, &len) == 0
            }
        }
        guard ok else { throw AgentBinderError.launch("bind: \(String(cString: strerror(errno)))") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
