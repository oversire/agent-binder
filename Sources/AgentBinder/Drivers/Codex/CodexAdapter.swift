import Foundation

/// The settings of one Codex wire session.
struct CodexConfig: Sendable {
    var clientName = "agentbinder"
    var clientVersion = ""
    var model: String?
    var effort: String?
    var cwd = ""
    var approvalPolicy = "on-request"
    var sandbox = "workspace-write"
    /// The thread of `thread/resume`. It is nil for `thread/start`.
    var resumeID: String?
    /// The `developerInstructions` of the thread.
    var instructions: String?
    var handshakeTimeout: Duration = .seconds(30)
    var policy = PermissionPolicy()

    static let turnStartWait: Duration = .seconds(2)
    static let turnSteerWait: Duration = .seconds(5)

    var clientInfo: JSONValue {
        ["clientInfo": ["name": .string(clientName), "title": .string(clientName), "version": .string(clientVersion)]]
    }
}

/// The codec of `codex app-server`: JSON-RPC 2.0 with threads, turns and server approvals.
final class CodexAdapter: WireAdapter, RequestPrompting, TurnStateReporting, SteerSupporting, InterruptEncoding,
    Sendable
{
    private struct Approval {
        var id: JSONValue
        var method: String
    }

    private struct State {
        var writer: FrameWriter?
        var threadID: String?
        var turnID: String?
        var active = false
        // Session-wide, as the vendor does: a crash in a later turn gets no classified error.
        var sawResult = false
        var completions = 0
        var model: String?
        var sendEffort: Bool
        var limitsID: JSONValue?
        var approvals: [String: Approval] = [:]
        var turnUsage = Usage()
        var base: Usage?
        var imageDirectory: URL?
    }

    private let config: CodexConfig
    private let peer = JSONRPCPeer()
    private let state: Locked<State>

    init(_ config: CodexConfig) {
        self.config = config
        state = Locked(State(model: config.model, sendEffort: !(config.effort ?? "").isEmpty))
    }

    var turnActive: Bool { state.value.active }
    var threadID: String? { state.value.threadID }

    /// Stores the model of the next `turn/start`. It sends no frame.
    func setModel(_ id: String) { state.withLock { $0.model = id } }

    /// Removes the temp folder of the image attachments.
    func cleanup() {
        if let dir = state.withLock({ $0.imageDirectory }) { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: handshake

    func handshake(_ w: FrameWriter) async throws -> [Event] {
        state.withLock { $0.writer = w }
        peer.attach(w)
        let t = config.handshakeTimeout
        try await Self.call(peer, "initialize", config.clientInfo, timeout: t)
        try await peer.notify("initialized", params: [:])
        var params: [String: JSONValue] = [
            "cwd": .string(config.cwd), "approvalPolicy": .string(config.approvalPolicy),
            "sandbox": .string(config.sandbox),
        ]
        if let m = config.model, !m.isEmpty { params["model"] = .string(m) }
        if let i = config.instructions, !i.isEmpty { params["developerInstructions"] = .string(i) }
        var method = "thread/start"
        if let id = config.resumeID {
            method = "thread/resume"
            params["threadId"] = .string(id)
        }
        let reply = try await Self.call(peer, method, .object(params), timeout: t)
        guard reply.object != nil else {
            throw AgentBinderError.handshakeFailed("codex \(method): decode response: not an object")
        }
        // An API-key login has no plan limits, so the read has no waiter and its error is dropped.
        let limitsID = peer.nextID()
        state.withLock { $0.limitsID = limitsID }
        try await peer.send(id: limitsID, "account/rateLimits/read", params: ["excludeResetCreditDetails": true])
        let thread = [reply["threadId"], reply.at("thread", "id"), reply["id"]].lazy.compactMap { $0?.string }
            .first { !$0.isEmpty }
        guard let thread else { return [] }
        state.withLock { $0.threadID = thread }
        return [Event(.initialized, sessionID: thread)]
    }

    /// Sends a request and maps a JSON-RPC error to ``AgentBinderError/vendor(code:message:)``.
    @discardableResult
    static func call(
        _ peer: JSONRPCPeer, _ method: String, _ params: JSONValue, timeout: Duration
    ) async throws
        -> JSONValue
    {
        do {
            return try await peer.request(method, params: params, timeout: timeout)
        } catch let e as JSONRPCError {
            throw AgentBinderError.vendor(code: e.code, message: "codex \(method): \(e.message)")
        }
    }

    // MARK: turns

    func promptSession(_ p: Prompt) async throws {
        let s = state.value
        guard let thread = s.threadID else { throw AgentBinderError.invalidRequest("codex: thread not started") }
        if s.active { throw AgentBinderError.turnActive }
        let input = try inputItems(p)
        let effort = s.sendEffort ? config.effort : nil
        do {
            try await startTurn(thread, input, model: s.model, effort: effort)
        } catch let e as JSONRPCError where effort != nil && Self.rejectsEffort(e) {
            // An older server refuses the field. The -c model_reasoning_effort flag still carries it.
            state.withLock { $0.sendEffort = false }
            try await startTurn(thread, input, model: s.model, effort: nil)
        }
        // The turn id comes from turn/started. A turn that ended during the call stays ended.
        state.withLock { if $0.completions == s.completions { $0.active = true } }
    }

    // A late ack is fine: the turn is live while the server streams notifications.
    private func startTurn(_ thread: String, _ input: [JSONValue], model: String?, effort: String?) async throws {
        var params: [String: JSONValue] = ["threadId": .string(thread), "input": .array(input)]
        if let model, !model.isEmpty { params["model"] = .string(model) }
        if let effort { params["effort"] = .string(effort) }
        do {
            try await peer.request("turn/start", params: .object(params), timeout: CodexConfig.turnStartWait)
        } catch AgentBinderError.timeout {
        }
    }

    private static func rejectsEffort(_ e: JSONRPCError) -> Bool {
        let m = e.message.lowercased()
        return ["unknown", "unexpected", "invalid", "unrecognized", "unsupported"].contains { m.contains($0) }
    }

    // Steer never interrupts. A refusal is unsupported, so a held prompt waits for the next turn.
    func steer(_ p: Prompt) async throws {
        let s = state.value
        guard let thread = s.threadID else { throw AgentBinderError.invalidRequest("codex: thread not started") }
        guard s.active else { throw AgentBinderError.noActiveTurn }
        var params: [String: JSONValue] = ["threadId": .string(thread), "input": .array(try inputItems(p))]
        if let t = s.turnID { params["expectedTurnId"] = .string(t) }
        do {
            try await peer.request("turn/steer", params: .object(params), timeout: CodexConfig.turnSteerWait)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentBinderError.unsupported("codex turn/steer: \(error)")
        }
    }

    // The fire-and-forget form. The session uses promptSession.
    func encodePrompt(_ p: Prompt) throws -> Data {
        guard let thread = state.value.threadID else {
            throw AgentBinderError.invalidRequest("codex: thread not started")
        }
        return Self.request(
            peer.nextID(), "turn/start", ["threadId": .string(thread), "input": .array(try inputItems(p))]
        ).frame
    }

    func encodeInterrupt() throws -> Data {
        let s = state.value
        guard let thread = s.threadID else { throw AgentBinderError.invalidRequest("codex: thread not started") }
        var params: [String: JSONValue] = ["threadId": .string(thread)]
        if let t = s.turnID { params["turnId"] = .string(t) }
        return Self.request(peer.nextID(), "turn/interrupt", .object(params)).frame
    }

    private static func request(_ id: JSONValue, _ method: String, _ params: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params]
    }

    // Images are local files. Bytes go to a 0600 file in the session temp folder.
    private func inputItems(_ p: Prompt) throws -> [JSONValue] {
        var items: [JSONValue] = []
        for a in PromptAttachment.sorted(p.attachments) {
            if a.isImage, case .file(let url) = a.source {
                items.append(["type": "localImage", "path": .string(url.path)])
                continue
            }
            let l = try a.load()
            if l.isImage {
                items.append(["type": "localImage", "path": .string(try writeImage(l).path)])
            } else {
                items.append(["type": "text", "text": .string(String(decoding: l.data, as: UTF8.self))])
            }
        }
        items.append(["type": "text", "text": .string(p.text)])
        return items
    }

    private func writeImage(_ l: LoadedAttachment) throws -> URL {
        let dir = try state.withLock { s -> URL in
            if let d = s.imageDirectory { return d }
            let d = try ConfigFiles.sessionDirectory(.codex, purpose: "images")
            s.imageDirectory = d
            return d
        }
        let ext = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"][l.mime] ?? "bin"
        let url = dir.appendingPathComponent(String(format: "%016llx", UInt64.random(in: .min ... .max)) + "." + ext)
        try ConfigFiles.write(l.data, to: url)
        return url
    }

    // MARK: decisions

    // The reply keeps the id type of the server: 7 stays a number and "7" stays a string.
    func encodeDecision(id: String, _ d: Decision) throws -> Data {
        let a = state.withLock { $0.approvals.removeValue(forKey: id) }
        let wireID = a?.id ?? JSONValue.parse(id) ?? .string(id)
        return (["jsonrpc": "2.0", "id": wireID, "result": Self.decisionBody(method: a?.method ?? "", d)] as JSONValue)
            .frame
    }

    // The vendor ignores a changed input.
    static func decisionBody(method: String, _ d: Decision) -> JSONValue {
        if method.contains("requestUserInput") { return ["answers": [:]] }
        if method.contains("elicitation") { return ["action": d.allow ? "accept" : "decline"] }
        if d.allow { return ["decision": "accept"] }
        var body: [String: JSONValue] = ["decision": "decline"]
        if let m = d.message, !m.isEmpty { body["reason"] = .string(m) }
        return .object(body)
    }

    // MARK: parse

    func parse(_ line: Data) -> [Event] {
        switch peer.handle(line) {
        case .response(let r): return response(r)
        case .request(let id, let method, let params): return serverRequest(id, method, params)
        case .notification(let method, let params): return notification(method, params)
        case .invalid: return []
        }
    }

    // An error reply also fires when a caller got it, for example a refused turn/steer.
    private func response(_ r: JSONRPCPeer.Response) -> [Event] {
        let isLimits = state.withLock { s -> Bool in
            guard let id = s.limitsID, id == r.id else { return false }
            s.limitsID = nil
            return true
        }
        if isLimits {
            guard r.error == nil, let l = Limits(codex: r.result) else { return [] }
            return [Event(.limits(l))]
        }
        guard let e = r.error else { return [] }
        return [Event(.error(WireError(message: e.description, code: "rpc_error", endReason: .protocol)))]
    }

    private static func isApproval(_ method: String) -> Bool {
        method.hasSuffix("Approval") || method.contains("requestUserInput") || method.contains("elicitation")
    }

    private func serverRequest(_ id: JSONValue, _ method: String, _ params: JSONValue?) -> [Event] {
        guard Self.isApproval(method) else {
            let peer = peer
            Task {
                try? await peer.respondError(
                    id: id, code: JSONRPCError.methodNotFound,
                    message: "agentbinder: app-server method unsupported: \(method)")
            }
            return []
        }
        // Legacy methods, for example applyPatchApproval, are kind other, so auto_edit does not answer them.
        let kind: ToolKind =
            method.contains("fileChange") ? .edit : method.contains("commandExecution") ? .exec : .other
        if let d = config.policy.answer(kind: kind, tool: method) {
            let peer = peer
            let body = Self.decisionBody(method: method, d)
            Task { try? await peer.respond(id: id, result: body) }
            return []
        }
        let key = id.jsonString
        state.withLock { $0.approvals[key] = Approval(id: id, method: method) }
        return [
            Event(.permission(PermissionRequest(id: key, tool: method, kind: kind, question: question(method, params))))
        ]
    }

    private func question(_ method: String, _ params: JSONValue?) -> String {
        func text(_ k: String) -> String? { params?[k]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        if method.contains("commandExecution"), let c = text("command") { return "Allow command: \(c)" }
        if method.contains("fileChange") { return "Allow file changes" }
        if method.contains("permissions") { return "Allow requested permissions" }
        if method.contains("requestUserInput") { return text("question") ?? "Codex needs input" }
        if method.contains("elicitation") { return text("message") ?? "Codex requests input" }
        if method == "execCommandApproval" { return "Allow command execution" }
        if method == "applyPatchApproval" { return "Allow patch application" }
        return "Codex requests approval"
    }

    private func notification(_ method: String, _ params: JSONValue?) -> [Event] {
        switch method {
        case "thread/started":
            guard let id = params?.at("thread", "id")?.string, !id.isEmpty else { return [] }
            state.withLock { $0.threadID = id }
            return [Event(.initialized, sessionID: id)]
        case "turn/started":
            if let turn = params?["turn"], turn.object != nil {
                state.withLock { s in
                    s.turnID = turn["id"]?.string
                    s.active = true
                    s.turnUsage = Usage()
                    s.base = nil
                }
            }
            return [Event(.status(.running, text: nil))]
        case "turn/completed": return [Event(.result(completed(params)))]
        case "item/started", "item/updated", "item/completed": return CodexItems.events(method: method, params: params)
        case "item/agentMessage/delta", "item/agent_message/delta":
            let t = params?["delta"].stringValue ?? ""
            return t.isEmpty ? [] : [Event(.assistant(text: t, delta: true))]
        case "thread/tokenUsage/updated", "thread/token_usage/updated": return tokenUsage(params)
        case "account/rateLimits/updated": return Limits(codex: params).map { [Event(.limits($0))] } ?? []
        case "error": return [Event(.error(Self.classified(Self.errorText(params))))]
        default: return []
        }
    }

    // The result has no session id. The session fills it. Open tools stay open, as the vendor does.
    private func completed(_ params: JSONValue?) -> TurnResult {
        let usage = state.withLock { s -> Usage in
            defer {
                s.active = false
                s.turnID = nil
                s.sawResult = true
                s.completions += 1
                s.turnUsage = Usage()
                s.base = nil
            }
            return s.turnUsage
        }
        let turn = params?["turn"]
        let status = turn?["status"].stringValue ?? ""
        switch status {
        case "", "completed", "success":
            return TurnResult(subtype: "success", usage: usage)
        case "interrupted", "cancelled", "canceled":
            return TurnResult(subtype: "interrupted", isError: true, text: "turn interrupted", usage: usage)
        default:
            let err = turn?["error"]
            let text =
                [err?.string, err?["message"]?.string, err?["error"]?.string].lazy.compactMap { $0 }
                .first { !$0.isEmpty } ?? "turn \(status)"
            let w = Self.classified(text)
            return TurnResult(
                subtype: status, isError: true, text: text, usage: usage, endReason: w.endReason, code: w.code)
        }
    }

    // The event is the thread total. The turn usage is the total now less the total before the first call
    // of the turn, so a repeated notification adds nothing.
    private func tokenUsage(_ params: JSONValue?) -> [Event] {
        let (last, total) = CodexItems.tokenUsage(params)
        let turnID = params?["turnId"]?.string
        state.withLock { s in
            guard s.active else { return }
            if let a = turnID, let b = s.turnID, a != b { return }
            if let total {
                let base = s.base ?? last.map { total.minus($0) } ?? total
                s.base = base
                s.turnUsage = total.minus(base)
            } else if let last {
                s.turnUsage = Usage(
                    input: s.turnUsage.input + last.input, output: s.turnUsage.output + last.output,
                    cacheRead: s.turnUsage.cacheRead + last.cacheRead,
                    cacheCreation: s.turnUsage.cacheCreation + last.cacheCreation)
            }
        }
        return total.map { [Event(.usage($0))] } ?? []
    }

    // Fixed on purpose: a missing message takes the error text or its JSON, not a Go map dump.
    private static func errorText(_ params: JSONValue?) -> String {
        let err = params?["error"]
        let candidates = [params?["message"]?.string, err?.string, err?["message"]?.string]
        if let t = candidates.lazy.compactMap({ $0 }).first(where: { !$0.isEmpty }) { return t }
        if let err, !err.isNull { return err.jsonString }
        return "codex reported an error"
    }

    private static func classified(_ text: String) -> WireError {
        let c = Classifier.classify(text, harness: .codex)
        return WireError(
            message: text, code: c.code, endReason: c.cls == .none ? nil : EndReason(rawValue: c.cls.rawValue))
    }

    // MARK: exit

    func exitEvents(code: Int32, stderr: String) -> [Event] {
        if state.value.sawResult { return [] }
        var text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = "codex exited with code \(code) before turn/completed" }
        return [Event(.error(Self.classified(text)))]
    }
}
