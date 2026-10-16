import Darwin
import Foundation

/// The settings of one wire session.
struct WireConfig: Sendable {
    /// The cap of one frame.
    var maxFrameBytes = FrameReader.defaultMaxBytes
    /// The frame log, when one is set. It holds secrets.
    var logPath: URL?
    /// The time limit of the adapter handshake.
    var handshakeTimeout: Duration = .seconds(30)
    /// The time of each stage of the graceful close.
    var stageTimeout: Duration = ChildProcess.defaultStageTimeout
    /// The capacity of the event buffer.
    var eventCapacity = EventChannel.defaultCapacity
}

/// One conversation over a child process that speaks NDJSON on stdio.
///
/// It owns the child, the framing, the event stream, turn counts, held prompts and the close sequence.
final class WireSession: Session, Steerable {
    /// The time that a hard kill waits for the read loop to end.
    static let killDrainTimeout: Duration = .seconds(2)

    let harness: Harness
    let events: AsyncStream<Event>

    private enum IO {
        case process(ChildProcess)
        case memory(AsyncStream<Data>)
    }

    private struct State {
        var id: String?
        var turn = 0
        var lastError: WireError?
        var closeStarted = false
        var hooks: [@Sendable () -> Void] = []
        var loop: Task<Void, Never>?
    }

    private let io: IO
    private let adapter: any WireAdapter
    private let config: WireConfig
    private let frameCap: Int
    private let channel: EventChannel
    private let outbox = Outbox()
    private let log: FrameLog?
    private let state: Locked<State>
    private let done = Latch()
    /// The writer of the adapter.
    let writer: FrameWriter

    private init(
        harness: Harness, io: IO, adapter: any WireAdapter, config: WireConfig,
        sink: @escaping FrameWriter.Sink
    ) throws {
        self.harness = harness
        self.io = io
        self.adapter = adapter
        self.config = config
        frameCap = FrameReader(maxBytes: config.maxFrameBytes).maxBytes
        let log = try config.logPath.map { try FrameLog(path: $0) }
        self.log = log
        let state = Locked(State())
        self.state = state
        writer = FrameWriter(
            harness: harness, log: log, onSessionID: { id in state.withLock { $0.id = id } }, sink: sink)
        let channel = EventChannel(capacity: config.eventCapacity)
        self.channel = channel
        let onCancel = Locked<(@Sendable () -> Void)?>(nil)
        events = AsyncStream(unfolding: { await channel.receive() }, onCancel: { onCancel.value?() })
        // A consumer that cancels its task closes the session.
        let close: @Sendable () -> Void = { [weak self] in Task { [weak self] in await self?.close() } }
        onCancel.withLock { $0 = close }
    }

    // MARK: start

    /// Starts a session on a spawned child. It returns after the handshake.
    ///
    /// On a handshake failure it kills the child, runs the hooks and throws.
    static func start(
        harness: Harness, process: ChildProcess, adapter: any WireAdapter, config: WireConfig = WireConfig(),
        onClose hooks: [@Sendable () -> Void] = []
    ) async throws -> WireSession {
        let s: WireSession
        do {
            s = try WireSession(
                harness: harness, io: .process(process), adapter: adapter, config: config,
                sink: { try await process.write($0) })
        } catch {
            await process.killTree()
            for h in hooks { h() }
            throw error
        }
        for h in hooks { s.onClose(h) }
        s.startLoop()
        do {
            let w = s.writer
            let evs = try await Deadline.run(config.handshakeTimeout, onTimeout: AgentBinderError.handshakeTimeout) {
                try await adapter.handshake(w)
            }
            for e in evs { await s.emit(e) }
        } catch {
            await s.abort()
            throw error
        }
        return s
    }

    /// Makes a session without a process, for scripted-peer tests. `input` is the stdout of the peer.
    ///
    /// A handshake failure becomes an `.error` event with the code `handshake_failed`.
    static func inMemory(
        harness: Harness = .fake, adapter: any WireAdapter, input: AsyncStream<Data>,
        output: @escaping @Sendable (Data) -> Void, config: WireConfig = WireConfig()
    ) async throws -> WireSession {
        let s = try WireSession(
            harness: harness, io: .memory(input), adapter: adapter, config: config, sink: { output($0) })
        s.startLoop()
        do {
            let w = s.writer
            let evs = try await Deadline.run(config.handshakeTimeout, onTimeout: AgentBinderError.handshakeTimeout) {
                try await adapter.handshake(w)
            }
            for e in evs { await s.emit(e) }
        } catch {
            await s.emit(
                Event(
                    .error(
                        WireError(
                            message: "\(error)", code: AgentBinderError.handshakeFailed("").code,
                            endReason: .protocol))))
        }
        return s
    }

    // MARK: properties

    var id: String? { state.withLock { $0.id } }

    var pid: Int32? {
        if case .process(let p) = io { return p.pid }
        return nil
    }

    /// The command line of the child, for the ledger.
    var argv: [String] {
        if case .process(let p) = io { return p.argv }
        return []
    }

    var lastError: WireError? { state.withLock { $0.lastError } }

    /// The number of user turns that the session wrote.
    var turn: Int { state.withLock { $0.turn } }

    /// Records a vendor session id that a driver learned or chose.
    func setID(_ id: String) {
        guard !id.isEmpty else { return }
        state.withLock { $0.id = id }
    }

    /// Adds a cleanup hook. The hooks run once, after the session ends.
    func onClose(_ hook: @escaping @Sendable () -> Void) {
        state.withLock { $0.hooks.append(hook) }
    }

    // MARK: turns

    func prompt(_ p: Prompt) async throws {
        if active && !concurrent { throw AgentBinderError.turnActive }
        state.withLock { $0.turn += 1 }
        if let rp = adapter as? RequestPrompting {
            try await rp.promptSession(p)
        } else {
            try await writer.write(try adapter.encodePrompt(p))
        }
    }

    func send(_ p: Prompt) async throws -> Delivery {
        try await outbox.send(ops, p)
    }

    func steer(_ p: Prompt) async throws {
        guard let st = adapter as? SteerSupporting else { throw AgentBinderError.unsupported("steer") }
        try await st.steer(p)
    }

    func answer(_ permissionID: String, _ d: Decision) async throws {
        try await writer.write(try adapter.encodeDecision(id: permissionID, d))
    }

    /// Sends the protocol interrupt when the adapter has one, else SIGTERM to the process group.
    func interrupt() async throws {
        if let ie = adapter as? InterruptEncoding {
            try await writer.write(try ie.encodeInterrupt())
            return
        }
        guard case .process(let p) = io else { throw AgentBinderError.unsupported("interrupt") }
        p.signalGroup(SIGTERM)
    }

    private var active: Bool { (adapter as? TurnStateReporting)?.turnActive ?? false }
    private var concurrent: Bool { (adapter as? ConcurrentPrompting)?.concurrentPrompt ?? false }

    private var ops: Outbox.Ops {
        var steer: (@Sendable (Prompt) async throws -> Void)?
        if adapter is SteerSupporting { steer = { [self] p in try await self.steer(p) } }
        return Outbox.Ops(
            active: { [self] in active }, prompt: { [self] p in try await prompt(p) }, steer: steer,
            concurrent: concurrent)
    }

    // A RequestPrompting adapter waits for a reply that this read loop parses, so it flushes on its own task.
    private func flushHeld() async {
        guard outbox.pending, !active else { return }
        let run: @Sendable () async -> Void = { [self] in
            let dropped = await outbox.flush { [self] p in try await prompt(p) }
            if !dropped.isEmpty { await emit(Event(.error(Outbox.droppedError(dropped)))) }
        }
        if adapter is RequestPrompting {
            Task { await run() }
        } else {
            await run()
        }
    }

    // MARK: close

    func close() async {
        let first = state.withLock { s -> Bool in
            defer { s.closeStarted = true }
            return !s.closeStarted
        }
        if first {
            switch io {
            case .process(let p): await p.gracefulClose(stageTimeout: config.stageTimeout)
            case .memory: state.withLock { $0.loop }?.cancel()
            }
            // Unblock a stalled consumer so the read loop can finish.
            channel.beginClosing()
        }
        await done.wait()
        runHooks()
    }

    func kill() async {
        state.withLock { $0.closeStarted = true }
        await hardStop()
    }

    private func abort() async {
        state.withLock { $0.closeStarted = true }
        await hardStop()
    }

    private func hardStop() async {
        switch io {
        case .process(let p): await p.killTree()
        case .memory: state.withLock { $0.loop }?.cancel()
        }
        channel.beginClosing()
        _ = await done.wait(timeout: WireSession.killDrainTimeout)
        runHooks()
    }

    private func runHooks() {
        let hooks = state.withLock { s -> [@Sendable () -> Void] in
            defer { s.hooks = [] }
            return s.hooks
        }
        for h in hooks { h() }
    }

    // MARK: read loop

    private func startLoop() {
        let t = Task.detached { [self] in await readLoop() }
        state.withLock { $0.loop = t }
    }

    private func readLoop() async {
        var reader = FrameReader(maxBytes: config.maxFrameBytes)
        var failed = false
        switch io {
        case .process(let p):
            reading: while true {
                switch await p.readStdout() {
                case .data(let d):
                    for f in reader.feed(d) { await handle(f) }
                case .eof:
                    break reading
                case .failed(let e):
                    failed = true
                    await emit(
                        Event(.error(WireError(message: String(cString: strerror(e)), code: "read_failed"))))
                    break reading
                }
            }
        case .memory(let input):
            for await d in input {
                for f in reader.feed(d) { await handle(f) }
            }
        }
        if !failed, let f = reader.finish() { await handle(f) }
        await finishLoop()
    }

    private func handle(_ frame: FrameReader.Frame) async {
        switch frame {
        case .tooLarge:
            await emit(
                Event(
                    .error(
                        WireError(
                            message: "frame exceeds \(frameCap) bytes and was discarded",
                            code: AgentBinderError.frameTooLarge.code))))
        case .line(let line):
            if FrameReader.isBlank(line) { return }
            log?.write(.in, line)
            for var e in adapter.parse(line) {
                if e.raw == nil { e.raw = line }
                switch e.kind {
                case .result, .error:
                    // Keep the turn of the result before a flush starts the next turn.
                    if e.turn == 0 { e.turn = turn }
                    await flushHeld()
                default: break
                }
                await emit(e)
            }
        }
    }

    private func finishLoop() async {
        var code: Int32?
        var stderr = ""
        if case .process(let p) = io {
            code = await p.waitForExit()
            stderr = p.stderrTail
            for e in adapter.exitEvents(code: code!, stderr: stderr) { await emit(e) }
        }
        let dropped = outbox.drop()
        if !dropped.isEmpty { await emit(Event(.error(Outbox.droppedError(dropped)))) }
        var error: String?
        var errorCode: String?
        if let code, code != 0 {
            error = WireSession.firstLine(stderr)
            errorCode = "process_exited"
            let failure = WireError(message: error ?? "", code: "process_exited", endReason: .failed)
            state.withLock { s in
                if s.lastError == nil { s.lastError = failure }
            }
        }
        await emit(Event(.exit(code: code, error: error, errorCode: errorCode)))
        writer.close()
        channel.finish()
        log?.close()
        state.withLock { $0.loop = nil }
        done.open()
    }

    /// The first line of a text, without white space around it.
    static func firstLine(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = t.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: emit

    func emit(_ event: Event) async {
        var e = event
        let learned = event.sessionID.flatMap { $0.isEmpty ? nil : $0 }
        var failure: WireError?
        if case .error(let we) = event.kind { failure = we }
        let (id, turn) = state.withLock { [failure] s -> (String?, Int) in
            if let learned { s.id = learned }
            if let failure, s.lastError == nil { s.lastError = failure }
            return (s.id, s.turn)
        }
        if e.sessionID == nil { e.sessionID = id }
        if e.turn == 0 { e.turn = turn }
        await channel.send(e)
    }
}
