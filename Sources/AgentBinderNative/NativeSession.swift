import AgentBinder
import Foundation

/// One in-process session. A turn runs the model loop in a task; ``prompt(_:)`` returns when the turn starts.
final class NativeSession: Session, CloseObserving {
    static let toolInputMax = 8192
    static let errorCode = "native_turn_failed"

    let harness = Harness.native
    let id: String?
    let pid: Int32? = nil
    let events: AsyncStream<Event>

    private struct State {
        var busy = false
        var turn = 0
        var task: Task<Void, Never>?
        var held: [Prompt] = []
        var endAfterTurn = false
        var closed = false
        var ended = false
        var lastError: WireError?
        var hooks: [@Sendable () -> Void] = []
    }

    private let state = Locked(State())
    private let sink: AsyncStream<Event>.Continuation
    private let loop: NativeLoop
    private let release: @Sendable () async -> Void
    private let done = Latch()

    init(
        id: String, model: any Model, tools: ToolTable, system: String, history: [Message], config: NativeConfig,
        permissions: PermissionPolicy, effort: String, release: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.release = release
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        let queue = PermissionQueue()
        let state = state
        let sink = sink
        let emit: @Sendable (Event.Kind) -> Void = { k in
            let turn = state.withLock { $0.turn }
            sink.yield(Event(k, turn: turn, sessionID: id))
        }
        let approver =
            config.approver
            ?? AskingApprover(policy: permissions) { r in
                let pid = queue.nextID()
                emit(
                    .permission(
                        PermissionRequest(
                            id: pid, tool: r.spec.name, kind: r.spec.annotations.kind,
                            question: "Allow \(r.spec.name)?",
                            input: String(decoding: r.input ?? Data(), as: UTF8.self), toolUseID: r.callID)))
                emit(.status(.waiting, text: nil))
                defer { emit(.status(.running, text: nil)) }
                return try await queue.wait(pid)
            }
        loop = NativeLoop(
            id: id, model: model, tools: tools, system: system, history: history, config: config, approver: approver,
            effort: effort, emit: emit)
        self.permissions = queue
        sink.onTermination = { [weak self] reason in
            guard case .cancelled = reason, let self else { return }
            Task { await self.close() }
        }
    }

    private let permissions: PermissionQueue

    var lastError: WireError? { state.value.lastError }

    func start() { emit(.initialized) }

    func onClose(_ hook: @escaping @Sendable () -> Void) {
        let now = state.withLock { s -> Bool in
            if s.ended { return true }
            s.hooks.append(hook)
            return false
        }
        if now { hook() }
    }

    // MARK: turns

    func prompt(_ p: Prompt) async throws {
        let msg = try NativeLoop.userMessage(p)
        let n = try state.withLock { s -> Int in
            if s.closed { throw AgentBinderError.sessionClosed }
            if s.busy { throw AgentBinderError.turnActive }
            s.busy = true
            s.turn += 1
            return s.turn
        }
        let t = Task { [self] in
            let err = await loop.runTurn(msg)
            turnEnded(err)
        }
        state.withLock { s in
            if s.busy && s.turn == n { s.task = t }
        }
    }

    /// Writes the one-shot prompt; the session closes after the turn.
    func oneShot(_ p: Prompt) async throws {
        state.withLock { $0.endAfterTurn = true }
        try await prompt(p)
    }

    func send(_ p: Prompt) async throws -> Delivery {
        let held = try state.withLock { s -> Bool in
            if s.closed { throw AgentBinderError.sessionClosed }
            if s.busy { s.held.append(p) }
            return s.busy
        }
        if held { return .held }
        try await prompt(p)
        return .prompted
    }

    private func turnEnded(_ err: WireError?) {
        let (next, close) = state.withLock { s -> (Prompt?, Bool) in
            s.busy = false
            s.task = nil
            if let err, s.lastError == nil { s.lastError = err }
            if s.closed { return (nil, false) }
            if s.endAfterTurn { return (nil, true) }
            guard !s.held.isEmpty else { return (nil, false) }
            let text = s.held.map(\.text).joined(separator: "\n\n")
            let files = s.held.flatMap(\.attachments)
            s.held = []
            return (Prompt(text, attachments: files), false)
        }
        permissions.cancelAll()
        if close { Task { await self.close() } }
        if let next {
            Task {
                do {
                    try await prompt(next)
                } catch {
                    emit(.error(WireError(message: "native: held prompt: \(error)", code: Self.errorCode)))
                }
            }
        }
    }

    func interrupt() async throws {
        state.value.task?.cancel()
    }

    func answer(_ permissionID: String, _ d: Decision) async throws {
        try permissions.answer(permissionID, d)
    }

    // MARK: close

    func close() async {
        let first = state.withLock { s -> Bool in
            defer { s.closed = true }
            return !s.closed
        }
        guard first else {
            await done.wait()
            return
        }
        let task = state.value.task
        task?.cancel()
        await task?.value
        permissions.cancelAll()
        await release()
        let (held, hooks) = state.withLock { s -> ([Prompt], [@Sendable () -> Void]) in
            defer {
                s.held = []
                s.hooks = []
                s.ended = true
            }
            return (s.held, s.hooks)
        }
        if !held.isEmpty {
            // The same code as the CLI drivers.
            emit(
                .error(
                    WireError(
                        message: "the session ended before a held prompt was sent", code: "held_prompt_dropped",
                        text: held.map(\.text).joined(separator: "\n\n"))))
        }
        emit(.exit(code: 0, error: nil, errorCode: nil))
        sink.finish()
        for h in hooks { h() }
        done.open()
    }

    func kill() async { await close() }

    private func emit(_ k: Event.Kind) {
        sink.yield(Event(k, turn: state.value.turn, sessionID: id))
    }
}

/// The model loop of one session. It owns the history.
actor NativeLoop {
    enum Stop: String {
        case endTurn = "end_turn"
        case maxTurns = "max_turn_requests"
    }

    let id: String
    let model: any Model
    let tools: ToolTable
    let system: String
    let config: NativeConfig
    let approver: any Approver
    let effort: String
    let emit: @Sendable (Event.Kind) -> Void
    private(set) var history: [Message]

    init(
        id: String, model: any Model, tools: ToolTable, system: String, history: [Message], config: NativeConfig,
        approver: any Approver, effort: String, emit: @escaping @Sendable (Event.Kind) -> Void
    ) {
        self.id = id
        self.model = model
        self.tools = tools
        self.system = system
        self.history = history
        self.config = config
        self.approver = approver
        self.effort = effort
        self.emit = emit
    }

    /// Runs one turn and emits its result. It returns the failure of the turn, if any.
    func runTurn(_ user: Message) async -> WireError? {
        await append([user])
        emit(.status(.running, text: nil))
        var total = ModelUsage()
        defer { emit(.status(.idle, text: nil)) }
        do {
            let stop = try await loop(&total)
            if stop == .maxTurns {
                emit(.result(TurnResult(subtype: "error_max_turns", isError: true, sessionID: id, usage: total.usage)))
            } else {
                emit(.result(TurnResult(sessionID: id, usage: total.usage)))
            }
            return nil
        } catch  where Self.isCancel(error) {
            emit(.result(TurnResult(subtype: "interrupted", isError: true, sessionID: id, usage: total.usage)))
            return nil
        } catch {
            let text = (error as? NativeError)?.message ?? String(describing: error)
            let c = Classifier.classify(text, harness: .native)
            let w = WireError(message: text, code: Self.errorCodeOf(error), endReason: c.endReason)
            emit(.error(w))
            emit(
                .result(
                    TurnResult(
                        subtype: "error", isError: true, text: text, sessionID: id, usage: total.usage,
                        endReason: c.endReason, code: c.code)))
            return w
        }
    }

    static func errorCodeOf(_ e: any Error) -> String {
        (e as? NativeError)?.code ?? (e as? AgentBinderError)?.code ?? NativeSession.errorCode
    }

    static func isCancel(_ e: any Error) -> Bool {
        if e is CancellationError { return true }
        if let u = e as? URLError, u.code == .cancelled { return true }
        return false
    }

    private func loop(_ total: inout ModelUsage) async throws -> Stop {
        let maxTurns = config.maxTurns > 0 ? config.maxTurns : NativeConfig.defaultMaxTurns
        for _ in 0..<maxTurns {
            try Task.checkCancellation()
            try await config.beforeCall?(id)
            try await compactIfNeeded()
            let (msg, usage, calls) = try await call()
            total = total + usage
            emit(.usage(usage.usage))
            await config.afterCall?(id, usage)
            // Fixed on purpose: an empty answer adds no message; the providers refuse a message with no parts.
            if !msg.parts.isEmpty { await append([msg]) }
            if calls.isEmpty { return .endTurn }
            for (i, c) in calls.enumerated() {
                if Task.isCancelled {
                    // Fixed on purpose: each tool call gets a result, so the next prompt works.
                    await append(
                        calls[i...].map {
                            Message(
                                role: .tool,
                                parts: [
                                    .toolResult(
                                        ToolResult(
                                            callID: $0.id, name: $0.name, content: [.text("cancelled")], isError: true))
                                ])
                        })
                    throw CancellationError()
                }
                let r = await run(c)
                await append([Message(role: .tool, parts: [.toolResult(r)])])
            }
        }
        return .maxTurns
    }

    /// One model call: it folds the stream into the assistant message and the tool calls.
    private func call() async throws -> (Message, ModelUsage, [ToolCall]) {
        let req = ModelRequest(
            system: system, messages: history, tools: tools.specs, maxOutputTokens: config.maxOutputTokens,
            effort: effort)
        var text = ""
        var thought = ""
        var reasoning: [ReasoningPart] = []
        var calls: [ToolCall] = []
        var finish: Finish?
        for try await p in model.stream(req) {
            switch p {
            case .textDelta(let t):
                text += t
                emit(.assistant(text: t, delta: true))
            case .reasoningDelta(let t):
                thought += t
                emit(.thought(text: t, delta: true))
            case .reasoningSignature(let s):
                // Fixed on purpose: the signature stays with its block, so a later call with tool results works.
                reasoning.append(ReasoningPart(text: thought, signature: s))
                thought = ""
            case .toolCallDone(let c): calls.append(c)
            case .finish(let f): finish = f
            case .toolInputStart, .toolInputDelta: break
            }
        }
        // A cancel ends the stream with no finish part.
        try Task.checkCancellation()
        guard let finish else {
            throw NativeError("stream_incomplete", "native: model stream ended without a finish part")
        }
        switch finish.reason {
        case .refusal: throw NativeError("model_refused", "model refused the request")
        case .contentFilter: throw NativeError("content_filtered", "model response was blocked by a content filter")
        default: break
        }
        if !thought.isEmpty { reasoning.append(ReasoningPart(text: thought)) }
        if !text.isEmpty { emit(.assistant(text: text, delta: false)) }
        var parts = reasoning.map(Part.reasoning)
        if !text.isEmpty { parts.append(.text(text)) }
        parts += calls.map(Part.toolCall)
        return (Message(role: .assistant, parts: parts), finish.usage, calls)
    }

    private func run(_ c: ToolCall) async -> ToolResult {
        let tool = tools[c.name]
        let spec =
            tool?.spec ?? ToolSpec(name: c.name, inputSchema: Data("{}".utf8), annotations: ToolAnnotations(kind: .mcp))
        let kind = spec.annotations.kind
        emit(
            .tool(
                ToolEvent(
                    id: c.id, name: c.name, kind: kind,
                    input: Part.cut(String(decoding: c.input ?? Data(), as: UTF8.self), NativeSession.toolInputMax))))
        var r = await execute(c, tool, spec)
        r.callID = c.id
        if r.name.isEmpty { r.name = c.name }
        emit(
            .tool(
                ToolEvent(
                    id: c.id, name: c.name, kind: kind, output: r.content.map(\.flatText).joined(separator: " "),
                    status: r.isError ? .failed : .completed)))
        return r
    }

    private func execute(_ c: ToolCall, _ tool: (any Tool)?, _ spec: ToolSpec) async -> ToolResult {
        guard let tool else { return .text("unknown tool \(JSONValue.quote(c.name))", isError: true) }
        var input = c.input
        if spec.needsApproval {
            let d: Decision
            do {
                d = try await approver.approve(ApprovalRequest(callID: c.id, spec: spec, input: c.input))
            } catch  where Self.isCancel(error) {
                return .text("cancelled", isError: true)
            } catch {
                return .text("approval failed: \(error)", isError: true)
            }
            guard d.allow else {
                let m = d.message ?? ""
                return .text(m.isEmpty ? "denied by the operator" : "denied by the operator: \(m)", isError: true)
            }
            if let u = d.updatedInput { input = u }
        }
        do {
            return try await tool.call(input)
        } catch  where Self.isCancel(error) {
            return .text("cancelled", isError: true)
        } catch {
            return .text("tool infrastructure failure: \(error)", isError: true)
        }
    }

    private func compactIfNeeded() async throws {
        guard let compactor = config.compactor, config.contextTokens > 0 else { return }
        guard history.tokenEstimate >= config.contextTokens * 60 / 100 else { return }
        history = try await compactor.compact(model: model, messages: history)
        try await config.store?.replace(id, history)
    }

    private func append(_ m: [Message]) async {
        history += m
        try? await config.store?.append(id, m)
    }

    // MARK: user message

    static let imageTypes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
    ]

    /// The user message of a prompt: the images first, then the text.
    static func userMessage(_ p: Prompt) throws -> Message {
        var parts: [Part] = []
        for a in p.attachments {
            var media = a.mime ?? ""
            if media.isEmpty, case .file(let url) = a.source {
                media = imageTypes[url.pathExtension.lowercased()] ?? ""
            }
            guard media.hasPrefix("image/") else {
                throw AgentBinderError.unsupported("native takes image attachments only, got \(JSONValue.quote(media))")
            }
            let data: Data
            switch a.source {
            case .data(let d): data = d
            case .file(let url):
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    throw AgentBinderError.invalidRequest(
                        "native: attachment \(url.path): \(error.localizedDescription)")
                }
            }
            if data.isEmpty { throw AgentBinderError.invalidRequest("native: attachment with no data") }
            parts.append(.file(FilePart(mediaType: media, data: data)))
        }
        if !p.text.isEmpty || parts.isEmpty { parts.append(.text(p.text)) }
        return Message(role: .user, parts: parts)
    }
}
