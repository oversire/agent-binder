import Foundation

/// One REST call of a session.
struct OpenCodeCall: Sendable, Equatable {
    var method = "POST"
    var path: String
    var directory: String?
    var body: JSONValue?
}

/// The turn state that the event maps change.
struct OpenCodeTurn: Sendable {
    var busy = false
    var sawResult = false
    var lastError = ""
}

/// What one bus event does to a session.
struct OpenCodeStep: Sendable {
    var events: [Event] = []
    /// The turn ended: send the held prompts.
    var endsTurn = false
    /// The vendor deleted the session.
    var deleted = false

    init(_ events: [Event] = [], endsTurn: Bool = false, deleted: Bool = false) {
        self.events = events
        self.endsTurn = endsTurn
        self.deleted = deleted
    }
}

/// The REST shapes and the event map of one wire.
protocol OpenCodeDialect: Sendable {
    /// The call of one prompt. It throws before the turn starts, for example for an attachment.
    /// It also resets the maps of the last turn.
    mutating func prompt(_ p: Prompt) throws -> OpenCodeCall
    var interrupt: OpenCodeCall { get }
    func answer(_ permissionID: String, _ d: Decision) -> OpenCodeCall
    /// Changes the model. A returned call goes to the server at once.
    mutating func setModel(_ id: String) -> OpenCodeCall?
    mutating func parse(_ type: String, _ payload: JSONValue, _ turn: inout OpenCodeTurn) -> OpenCodeStep
}

/// A session on a shared `opencode serve`: REST calls out, bus events in.
final class OpenCodeSession<D: OpenCodeDialect>: ModelSettable, OpenCodeRoute, SharedChildBacked, CloseObserving {
    static var closeInterruptWait: Duration { .seconds(2) }

    private struct State {
        var dialect: D
        var turn = OpenCodeTurn()
        var turnCount = 0
        var lastError: WireError?
        var live = false
        var endAfterTurn = false
        var finished = false
        var hooks: [@Sendable () -> Void] = []
    }

    let harness: Harness
    let routeID: String
    let events: AsyncStream<Event>
    let server: OpenCodeServer
    private let policy: PermissionPolicy
    private let release: @Sendable () -> Void
    private let continuation: AsyncStream<Event>.Continuation
    private let outbox = Outbox()
    private let state: Locked<State>
    private let done = Latch()

    /// `release` runs once when the session ends, to drop the server reference.
    init(
        id: String, dialect: D, server: OpenCodeServer, policy: PermissionPolicy,
        release: @escaping @Sendable () -> Void = {}
    ) {
        harness = server.wire.harness
        routeID = id
        self.server = server
        self.policy = policy
        self.release = release
        state = Locked(State(dialect: dialect))
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        // A consumer that cancels its task closes the session.
        continuation.onTermination = { [weak self] t in
            if case .cancelled = t { Task { [weak self] in await self?.close() } }
        }
    }

    var id: String? { routeID }
    var pid: Int32? { server.child?.pid }
    var lastError: WireError? { state.value.lastError }
    var busy: Bool { state.value.turn.busy }

    /// Joins the routing table and emits `init` once.
    func markLive() {
        let first = state.withLock { s -> Bool in
            defer { s.live = true }
            return !s.live && !s.finished
        }
        guard first else { return }
        server.subscribe(self)
        emit(Event(.initialized, sessionID: routeID))
    }

    /// Ends the session after the next turn, for a one-shot request.
    func endAfterTurn() { state.withLock { $0.endAfterTurn = true } }

    func onClose(_ hook: @escaping @Sendable () -> Void) {
        let now = state.withLock { s -> Bool in
            if s.finished { return true }
            s.hooks.append(hook)
            return false
        }
        if now { hook() }
    }

    // MARK: turns

    func prompt(_ p: Prompt) async throws {
        let call = try state.withLock { s -> OpenCodeCall in
            if s.finished { throw AgentBinderError.sessionClosed }
            if s.turn.busy { throw AgentBinderError.turnActive }
            let c = try s.dialect.prompt(p)
            s.turn = OpenCodeTurn(busy: true)
            s.turnCount += 1
            return c
        }
        do {
            try await server.http.call(call)
        } catch {
            state.withLock { $0.turn.busy = false }
            throw error
        }
    }

    func send(_ p: Prompt) async throws -> Delivery {
        try await outbox.send(
            Outbox.Ops(
                active: { [self] in busy }, prompt: { [self] in try await prompt($0) }, steer: nil, concurrent: false),
            p)
    }

    /// The vendor ends the turn on the event stream.
    func interrupt() async throws {
        try await server.http.call(state.value.dialect.interrupt)
    }

    func answer(_ permissionID: String, _ d: Decision) async throws {
        try await server.http.call(state.value.dialect.answer(permissionID, d))
    }

    func setModel(_ id: String) async throws {
        let call = state.withLock { $0.dialect.setModel(id) }
        if let call { try await server.http.call(call) }
    }

    // MARK: route

    func deliver(_ type: String, _ payload: JSONValue) {
        let step = state.withLock { s -> OpenCodeStep? in
            s.finished ? nil : s.dialect.parse(type, payload, &s.turn)
        }
        guard let step else { return }
        for e in step.events {
            if case .permission(let r) = e.kind, let d = policy.answer(kind: r.kind, tool: r.tool) {
                reply(r.id, d)
                continue
            }
            emit(e)
        }
        if step.endsTurn && state.value.endAfterTurn {
            finish(code: 0, error: nil, errorCode: nil)
            return
        }
        if step.endsTurn { flushHeld() }
        if step.deleted { finish(code: 0, error: nil, errorCode: "session_deleted") }
    }

    func serverGone(_ reason: String) {
        let open = state.withLock { s -> Bool? in s.finished ? nil : s.turn.busy && !s.turn.sawResult }
        guard let open else { return }
        // Only a running turn loses its result.
        if open { emit(Event(.error(OpenCodeErrors.classified(reason, harness: harness)))) }
        state.withLock { s in
            if s.lastError == nil {
                s.lastError = WireError(message: reason, code: "server_exited", endReason: .failed)
            }
        }
        finish(code: -1, error: reason, errorCode: "server_exited")
    }

    // A policy answer runs off the event reader.
    private func reply(_ id: String, _ d: Decision) {
        let call = state.value.dialect.answer(id, d)
        let http = server.http
        Task.detached {
            try? await Deadline.run(.seconds(10), onTimeout: AgentBinderError.timeout("reply")) {
                try await http.call(call)
            }
        }
    }

    private func flushHeld() {
        guard outbox.pending else { return }
        Task.detached { [self] in
            let dropped = await outbox.flush { [self] in try await prompt($0) }
            if !dropped.isEmpty { emit(Event(.error(Outbox.droppedError(dropped)))) }
        }
    }

    // MARK: close

    /// Sends an interrupt when a turn runs, then ends the session. The server stays for other sessions.
    func close() async {
        let (open, running) = state.withLock { ($0.finished == false, $0.turn.busy) }
        if open && running {
            let call = state.value.dialect.interrupt
            let http = server.http
            _ = try? await Deadline.run(Self.closeInterruptWait, onTimeout: AgentBinderError.timeout("interrupt")) {
                try await http.call(call)
            }
        }
        finish(code: nil, error: nil, errorCode: nil)
        await done.wait()
    }

    func kill() async {
        finish(code: nil, error: nil, errorCode: nil)
    }

    private func finish(code: Int32?, error: String?, errorCode: String?) {
        let hooks = state.withLock { s -> [@Sendable () -> Void]? in
            if s.finished { return nil }
            s.finished = true
            defer { s.hooks = [] }
            return s.hooks
        }
        guard let hooks else { return }
        let dropped = outbox.drop()
        if !dropped.isEmpty { emit(Event(.error(Outbox.droppedError(dropped)))) }
        emit(Event(.exit(code: code, error: error, errorCode: errorCode)))
        continuation.finish()
        server.unsubscribe(routeID)
        release()
        for h in hooks { h() }
        done.open()
    }

    private func emit(_ event: Event) {
        var e = event
        let failure: WireError? = if case .error(let w) = event.kind { w } else { nil }
        let turn = state.withLock { s -> Int in
            if let failure, s.lastError == nil { s.lastError = failure }
            return s.turnCount
        }
        if e.sessionID == nil { e.sessionID = routeID }
        if e.turn == 0 { e.turn = turn }
        continuation.yield(e)
    }
}

extension OpenCodeHTTP {
    @discardableResult
    func call(_ c: OpenCodeCall) async throws -> JSONValue {
        try await call(c.method, c.path, directory: c.directory, body: c.body)
    }
}

/// The failure codes of the OpenCode wires.
enum OpenCodeErrors {
    /// The shared rules: phrases, then the HTTP status.
    static func classified(_ text: String, status: Int = 0, harness: Harness) -> WireError {
        let c = Classifier.classify(text, status: status == 0 ? nil : status, harness: harness)
        return WireError(
            message: text, code: c.code, endReason: c.cls == .none ? nil : EndReason(rawValue: c.cls.rawValue))
    }

    /// The error result of a turn that recorded a failure.
    static func failedResult(_ text: String, harness: Harness) -> TurnResult {
        let w = classified(text, harness: harness)
        return TurnResult(
            subtype: "error_during_execution", isError: true, text: text, endReason: w.endReason, code: w.code)
    }
}
