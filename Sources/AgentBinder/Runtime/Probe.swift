import Foundation

/// Short-lived children: `--version`, `--help`, login status, and model or limits exchanges.
enum Probe {
    struct Output: Sendable {
        /// Stdout, then the stderr tail.
        var text: String
        /// The exit code. It is nil after a timeout or a spawn failure.
        var code: Int32?
    }

    /// Runs a command, waits up to `timeout`, then kills the tree.
    static func run(
        _ binary: URL, _ arguments: [String], environment: [String: String], timeout: Duration,
        directory: URL? = nil
    ) async -> Output {
        guard
            let child = try? ChildProcess.spawn(
                SpawnOptions(executable: binary, arguments: arguments, directory: directory, environment: environment))
        else { return Output(text: "", code: nil) }
        child.closeStdin()
        let out = Locked(Data())
        let reader = Task {
            while case .data(let d) = await child.readStdout() { out.withLock { $0.append(d) } }
        }
        let exited = await child.waitForExit(timeout: timeout)
        if !exited { await child.killTree() }
        await reader.value
        let code = exited ? child.exitStatus?.code : nil
        return Output(text: String(decoding: out.value, as: UTF8.self) + child.stderrTail, code: code)
    }

    /// The start request of a model or limits probe. The permission mode is inherit, and the working
    /// folder is a temp folder when the query has none. Call the cleanup after the probe.
    static func request(_ h: Harness, _ q: ModelQuery) throws -> (StartRequest, @Sendable () -> Void) {
        var dir = q.workingDirectory
        var cleanup: @Sendable () -> Void = {}
        if dir == nil {
            let tmp = try ConfigFiles.sessionDirectory(h, purpose: "probe")
            dir = tmp
            cleanup = { try? FileManager.default.removeItem(at: tmp) }
        }
        let r = StartRequest(
            harness: h, workingDirectory: dir!, binary: q.binary, environment: q.environment, home: q.home,
            permissions: PermissionPolicy(mode: .inherit))
        return (r, cleanup)
    }

    /// Starts a child with a probe adapter, runs its one exchange, then kills the tree.
    static func exchange(
        _ r: StartRequest, _ launch: Launch, adapter: ProbeAdapter, context: RuntimeContext
    ) async throws {
        let s = try await context.startWire(r, launch, adapter: adapter)
        await s.kill()
    }
}

/// The wire adapter of a probe: one request exchange in the handshake, and no events.
final class ProbeAdapter: WireAdapter {
    typealias Run = @Sendable (FrameWriter) async throws -> Void
    typealias Parse = @Sendable (Data) -> Void

    private let run: Run
    private let parseLine: Parse

    init(run: @escaping Run, parse: @escaping Parse) {
        self.run = run
        parseLine = parse
    }

    func handshake(_ w: FrameWriter) async throws -> [Event] {
        try await run(w)
        return []
    }

    func encodePrompt(_: Prompt) throws -> Data { throw AgentBinderError.unsupported("probe prompt") }

    func parse(_ line: Data) -> [Event] {
        parseLine(line)
        return []
    }

    func encodeDecision(id _: String, _: Decision) throws -> Data {
        throw AgentBinderError.unsupported("probe decision")
    }

    func exitEvents(code _: Int32, stderr _: String) -> [Event] { [] }
}
