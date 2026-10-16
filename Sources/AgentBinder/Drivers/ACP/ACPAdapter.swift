import Foundation

/// The settings of one ACP wire session.
struct ACPConfig: Sendable {
    var variant: ACPVariant
    var clientName = "agentbinder"
    var clientVersion = ""
    var cwd = ""
    var model: String?
    var mcpServers: [MCPServer] = []
    /// The text of the first prompt block.
    var instructions: String?
    /// The preferred `authenticate` method.
    var authMethod: String?
    /// The session to load. With ``resume`` false it is a start with a known id, for example a new Cursor chat.
    var sessionID: String?
    var resume = false
    /// True for an id that `create-chat` just made: it has no `session/resume`.
    var fresh = false
    var handshakeTimeout: Duration = .seconds(45)
    var policy = PermissionPolicy()
    var fileSystem: (any FileSystemAccess)?

    static let setModelWait: Duration = .seconds(10)
    static let fileSystemWait: Duration = .seconds(30)
}

/// The codec of the Agent Client Protocol: JSON-RPC 2.0 with `session/*` methods.
final class ACPAdapter: WireAdapter, RequestPrompting, InterruptEncoding, TurnStateReporting, Sendable {
    struct Option: Sendable, Equatable {
        var id: String
        var kind: String
    }

    private struct State {
        var writer: FrameWriter?
        var sessionID: String?
        var authMethods: [String] = []
        var authMethod: String?
        var trustHTTPMCP = false
        /// The raw JSON id of the open `session/prompt`.
        var promptID: String?
        var sawResult = false
        var firstPrompt: Bool
        var approvals: [String: [Option]] = [:]
        var models: [ModelInfo] = []
        var currentModel: String?
    }

    let config: ACPConfig
    private let peer = JSONRPCPeer()
    private let state: Locked<State>

    init(_ config: ACPConfig) {
        self.config = config
        let first = !(config.instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        state = Locked(State(authMethod: config.authMethod, firstPrompt: first))
    }

    private var kind: String { config.variant.rawValue }
    var sessionID: String? { state.value.sessionID }
    var turnActive: Bool { state.value.promptID != nil }
    var authMethods: [String] { state.value.authMethods }
    var trustHTTPMCP: Bool { state.value.trustHTTPMCP }

    /// The offered models, with the default on the current model.
    var offeredModels: [ModelInfo] {
        let s = state.value
        return s.models.map { m in
            var m = m
            m.isDefault = m.id == s.currentModel
            return m
        }
    }

    /// Sets the writer without the handshake, for the model probe.
    func attach(_ w: FrameWriter) {
        state.withLock { $0.writer = w }
        peer.attach(w)
    }

    /// Routes a line to the waiting calls only, for the model probe.
    func route(_ line: Data) { _ = peer.handle(line) }

    // MARK: handshake

    func handshake(_ w: FrameWriter) async throws -> [Event] {
        attach(w)
        try await initialize()
        var events = try await openOrLoad()
        // An agent can take a model that it did not list, so the call goes out without a list too.
        if let m = config.model, !m.isEmpty {
            do {
                try await applyModel(m)
                events.append(Event(.status(.running, text: "model \(m)")))
            } catch {
                events.append(Event(.status(.running, text: "model not applied: \(error)")))
            }
        }
        return events
    }

    func initialize() async throws {
        let fs: JSONValue = .bool(config.fileSystem != nil)
        let params: JSONValue = [
            "protocolVersion": 1,
            "clientCapabilities": [
                "terminal": false, "auth": ["terminal": false], "fs": ["readTextFile": fs, "writeTextFile": fs],
            ],
            "clientInfo": ["name": .string(config.clientName), "version": .string(config.clientVersion)],
        ]
        let r = try await call("initialize", params)
        let methods = (r["authMethods"]?.array ?? []).compactMap { $0["id"]?.string }.filter { !$0.isEmpty }
        let http = r.at("agentCapabilities", "mcpCapabilities", "http")?.bool ?? false
        state.withLock { s in
            s.authMethods = methods
            s.trustHTTPMCP = http
        }
    }

    // Fixed on purpose: a failed resume throws. It does not open a new session in silence.
    private func openOrLoad() async throws -> [Event] {
        if let id = config.sessionID, !id.isEmpty {
            state.withLock { $0.sessionID = id }
            do {
                return try await loadSession(id)
            } catch {
                if config.resume { throw AgentBinderError.resumeUnsupported }
            }
        }
        do {
            return try await newSession()
        } catch {
            guard (try? await authenticate()) != nil else {
                throw AgentBinderError.handshakeFailed("\(kind): session/new: \(error)")
            }
            do {
                return try await newSession()
            } catch {
                throw AgentBinderError.handshakeFailed("\(kind): session/new: \(error)")
            }
        }
    }

    private var sessionParams: [String: JSONValue] {
        ["cwd": .string(config.cwd), "mcpServers": MCPRender.acpServers(config.mcpServers, http: trustHTTPMCP)]
    }

    func newSession() async throws -> [Event] {
        let r = try await call("session/new", .object(sessionParams))
        guard let id = r["sessionId"]?.string, !id.isEmpty else {
            throw AgentBinderError.handshakeFailed("\(kind): session/new returned no sessionId")
        }
        return opened(r, id)
    }

    // A fresh id has no session/resume. Cursor answers session/load with "not found" for a fresh id,
    // so a new Cursor chat opens with session/new.
    private func loadSession(_ id: String) async throws -> [Event] {
        var params = sessionParams
        params["sessionId"] = .string(id)
        if !config.fresh, let r = try? await call("session/resume", .object(params)) { return opened(r, id) }
        return opened(try await call("session/load", .object(params)), id)
    }

    private func opened(_ r: JSONValue, _ fallback: String) -> [Event] {
        let id = r["sessionId"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        state.withLock { s in
            s.sessionID = id
            // A reply without the block keeps the old list.
            guard let m = r["models"], m.object != nil else { return }
            s.models = (m["availableModels"]?.array ?? []).compactMap { a in
                guard let id = a["modelId"]?.string, !id.isEmpty else { return nil }
                return ModelInfo(id: id, name: a["name"]?.string, description: a["description"]?.string)
            }
            s.currentModel = m["currentModelId"]?.string
        }
        return [Event(.initialized, sessionID: id)]
    }

    private func authenticate() async throws {
        let s = state.value
        guard let pick = s.authMethod ?? config.variant.authMethod(s.authMethods) else {
            throw AgentBinderError.handshakeFailed("\(kind): no auth methods")
        }
        try await call("authenticate", ["methodId": .string(pick)])
        state.withLock { $0.authMethod = pick }
    }

    /// Sends `session/set_model` and records the model.
    func applyModel(_ id: String) async throws {
        do {
            try await peer.request(
                "session/set_model", params: ["sessionId": .string(sessionID ?? ""), "modelId": .string(id)],
                timeout: ACPConfig.setModelWait)
        } catch {
            throw AgentBinderError.vendor(
                code: (error as? JSONRPCError)?.code ?? 0, message: "\(kind) session/set_model: \(error)")
        }
        state.withLock { $0.currentModel = id }
    }

    @discardableResult
    private func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await peer.request(method, params: params, timeout: config.handshakeTimeout)
    }

    // MARK: prompt

    // Fixed on purpose: the prompt id is set only after the frame is built, and a failed write clears it.
    func promptSession(_ p: Prompt) async throws {
        let frame = try encodePrompt(p)
        let w = state.value.writer
        do {
            guard let w else { throw AgentBinderError.sessionClosed }
            try await w.write(frame)
        } catch {
            state.withLock { $0.promptID = nil }
            throw error
        }
    }

    func encodePrompt(_ p: Prompt) throws -> Data {
        let s = state.value
        if s.promptID != nil { throw AgentBinderError.turnActive }
        var content: [JSONValue] = []
        for a in PromptAttachment.sorted(p.attachments) {
            let l = try a.load()
            if l.isImage {
                content.append(["type": "image", "mimeType": .string(l.mime), "data": .string(l.base64)])
            } else {
                content.append(["type": "text", "text": .string(String(decoding: l.data, as: UTF8.self))])
            }
        }
        let id = peer.nextID()
        let first = try state.withLock { s -> Bool in
            if s.promptID != nil { throw AgentBinderError.turnActive }
            defer {
                s.firstPrompt = false
                s.promptID = id.jsonString
                s.sawResult = false
            }
            return s.firstPrompt
        }
        let text = Instructions.withInstructions(config.instructions, p.text, first: first)
        content.append(["type": "text", "text": .string(text)])
        let params: JSONValue = ["sessionId": .string(s.sessionID ?? ""), "prompt": .array(content)]
        return (["jsonrpc": "2.0", "id": id, "method": "session/prompt", "params": params] as JSONValue).frame
    }

    // The agent answers the open prompt with stopReason cancelled, so the prompt id stays.
    func encodeInterrupt() throws -> Data {
        let params: JSONValue = ["sessionId": .string(sessionID ?? "")]
        return (["jsonrpc": "2.0", "method": "session/cancel", "params": params] as JSONValue).frame
    }

    // MARK: decisions

    // The reply keeps the id type of the agent. The message of the decision is not sent.
    func encodeDecision(id: String, _ d: Decision) throws -> Data {
        let options = state.withLock { $0.approvals.removeValue(forKey: id) } ?? []
        let wireID = JSONValue.parse(id) ?? .string(id)
        return
            (["jsonrpc": "2.0", "id": wireID, "result": ["outcome": Self.outcome(options, allow: d.allow)]]
            as JSONValue).frame
    }

    static func outcome(_ options: [Option], allow: Bool) -> JSONValue {
        let kinds = allow ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        let pick = options.first { kinds.contains($0.kind) } ?? (allow ? options.first : options.last)
        guard let pick else { return ["outcome": "cancelled"] }
        return ["outcome": "selected", "optionId": .string(pick.id)]
    }

    // MARK: parse

    func parse(_ line: Data) -> [Event] {
        switch peer.handle(line) {
        case .response(let r): return response(r)
        case .request(let id, let method, let params): return agentRequest(id, method, params)
        case .notification(let method, let params):
            guard method == "session/update", let params, params.object != nil else { return [] }
            if let sid = params["sessionId"]?.string, !sid.isEmpty, sid != sessionID { return [] }
            guard let update = params["update"], update.object != nil else { return [] }
            return ACPUpdates.events(update)
        case .invalid: return []
        }
    }

    // A new prompt resets sawResult, so a crash after the first turn still gives an error.
    private func response(_ r: JSONRPCPeer.Response) -> [Event] {
        let mine = state.withLock { s -> Bool in
            guard let id = s.promptID, id == r.id.jsonString else { return false }
            s.promptID = nil
            s.sawResult = true
            return true
        }
        guard mine else { return [] }
        if let e = r.error { return [Event(.error(classified(e.description)))] }
        var out: [Event] = []
        if let u = ACPUpdates.usage(r.result?["usage"]) { out.append(Event(.usage(u))) }
        let stop = r.result?["stopReason"].stringValue ?? ""
        switch stop {
        case "", "end_turn":
            out.append(Event(.result(TurnResult(subtype: "success"))))
        case "cancelled":
            out.append(Event(.result(TurnResult(subtype: "cancelled", isError: true, text: "turn cancelled"))))
        default:
            let w = classified(stop)
            out.append(
                Event(
                    .result(
                        TurnResult(
                            subtype: stop, isError: true, text: "stop: \(stop)", endReason: w.endReason, code: w.code)))
            )
        }
        return out
    }

    private func agentRequest(_ id: JSONValue, _ method: String, _ params: JSONValue?) -> [Event] {
        switch method {
        case "session/request_permission": return permission(id, params)
        case "fs/read_text_file", "fs/write_text_file":
            fileSystem(id, method, params)
            return []
        default:
            reply(id, error: JSONRPCError.methodNotFound, "agentbinder: client method unsupported: \(method)")
            return []
        }
    }

    private func permission(_ id: JSONValue, _ params: JSONValue?) -> [Event] {
        let options = (params?["options"]?.array ?? []).map {
            Option(id: $0["optionId"].stringValue, kind: $0["kind"].stringValue)
        }
        let call = params?["toolCall"]
        let title = call?["title"].stringValue ?? ""
        let toolKind = call?["kind"].stringValue ?? ""
        let kind = ToolClassifier.kind(for: toolKind.isEmpty ? title : toolKind)
        let tool = title.isEmpty ? toolKind : title
        if let d = config.policy.answer(kind: kind, tool: tool) {
            let peer = peer
            let body: JSONValue = ["outcome": Self.outcome(options, allow: d.allow)]
            Task { try? await peer.respond(id: id, result: body) }
            return []
        }
        let key = id.jsonString
        state.withLock { $0.approvals[key] = options }
        let question = title.isEmpty ? "Agent requests permission" : "Allow \(title)?"
        return [Event(.permission(PermissionRequest(id: key, tool: tool, kind: kind, question: question)))]
    }

    // Parse runs on the read loop, so a file call runs on its own task.
    private func fileSystem(_ id: JSONValue, _ method: String, _ params: JSONValue?) {
        guard let fs = config.fileSystem else {
            reply(id, error: JSONRPCError.methodNotFound, "agentbinder: file system access is not enabled")
            return
        }
        let peer = peer
        let path = params?["path"].stringValue ?? ""
        let content = params?["content"].stringValue ?? ""
        let read = method == "fs/read_text_file"
        Task {
            let result: Result<JSONValue, any Error>
            do {
                result = .success(
                    try await Deadline.run(ACPConfig.fileSystemWait, onTimeout: AgentBinderError.timeout(method)) {
                        if read { return ["content": .string(try await fs.readTextFile(path))] }
                        try await fs.writeTextFile(path, content: content)
                        return [:]
                    })
            } catch {
                result = .failure(error)
            }
            switch result {
            case .success(let v): try? await peer.respond(id: id, result: v)
            case .failure(let e):
                try? await peer.respondError(id: id, code: JSONRPCError.internalError, message: "\(e)")
            }
        }
    }

    private func reply(_ id: JSONValue, error code: Int, _ message: String) {
        let peer = peer
        Task { try? await peer.respondError(id: id, code: code, message: message) }
    }

    private func classified(_ text: String) -> WireError {
        let c = Classifier.classify(text, harness: config.variant.harness)
        return WireError(
            message: text, code: c.code, endReason: c.cls == .none ? nil : EndReason(rawValue: c.cls.rawValue))
    }

    // MARK: exit

    // Fixed on purpose: the waiting calls fail at once, and an idle session that ends with code 0 is quiet.
    func exitEvents(code: Int32, stderr: String) -> [Event] {
        peer.failAll()
        let s = state.value
        if s.promptID == nil && (s.sawResult || code == 0) { return [] }
        var text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = "\(kind) exited with code \(code) before the turn ended" }
        return [Event(.error(classified(text)))]
    }
}
