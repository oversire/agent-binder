import Foundation

/// The codec of the Claude stream-json wire, with its control channel.
final class ClaudeAdapter: WireAdapter, InterruptEncoding, TurnStateReporting, SteerSupporting, ConcurrentPrompting,
    Sendable
{
    static let replyWait: Duration = .seconds(10)

    private final class Reply: Sendable {
        let latch = Latch()
        let value = Locked<Result<JSONValue?, AgentBinderError>?>(nil)

        func resolve(_ r: Result<JSONValue?, AgentBinderError>) {
            value.withLock { $0 = r }
            latch.open()
        }
    }

    private struct State {
        var writer: FrameWriter?
        // Kept after the result and the exit, as the vendor does. An answer to an old id still works.
        var pending: [String: JSONValue] = [:]
        var tools: [String: String] = [:]
        var sawResult = false
        var active = false
        var replies: [String: Reply] = [:]
        var initID: String?
        var models: [ModelInfo] = []
    }

    private let state = Locked(State())
    private let policy: PermissionPolicy
    private let makeID: @Sendable () -> String

    init(policy: PermissionPolicy, makeID: @escaping @Sendable () -> String) {
        self.policy = policy
        self.makeID = makeID
    }

    /// A control request id: `req_<n>_<8 hex>`.
    static func requestID(_ n: Int) -> String {
        "req_\(n)_" + String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    var turnActive: Bool { state.value.active }
    var concurrentPrompt: Bool { true }
    var offeredModels: [ModelInfo] { state.value.models }

    /// Sets the writer without the initialize frame, for the model probe.
    func attach(_ w: FrameWriter) { state.withLock { $0.writer = w } }

    // The first prompt goes out at once, so the handshake does not wait for the initialize reply.
    func handshake(_ w: FrameWriter) async throws -> [Event] {
        let id = makeID()
        state.withLock {
            $0.writer = w
            $0.initID = id
        }
        try await w.write(ClaudeFrames.controlRequest(id: id, ["subtype": "initialize", "hooks": .null]))
        return []
    }

    /// Sends one control request and waits for its reply. It returns `response.response`.
    func control(_ request: [String: JSONValue]) async throws -> JSONValue? {
        let id = makeID()
        let reply = Reply()
        let w = state.withLock { s -> FrameWriter? in
            s.replies[id] = reply
            return s.writer
        }
        defer { state.withLock { $0.replies[id] = nil } }
        guard let w else { throw AgentBinderError.sessionClosed }
        try await w.write(ClaudeFrames.controlRequest(id: id, request))
        guard await reply.latch.wait(timeout: Self.replyWait), let r = reply.value.value else {
            throw AgentBinderError.timeout("claude \(request["subtype"].stringValue)")
        }
        return try r.get()
    }

    func encodePrompt(_ p: Prompt) throws -> Data {
        let frame = try ClaudeFrames.user(p).frame
        state.withLock { $0.active = true }
        return frame
    }

    // The CLI adds the text at the next tool boundary. The turn still ends with one result.
    func steer(_ p: Prompt) async throws {
        let (active, w) = state.withLock { ($0.active, $0.writer) }
        guard active, let w else { throw AgentBinderError.noActiveTurn }
        try await w.write(try ClaudeFrames.user(p))
    }

    // Fire and forget: the reply has no waiter and is dropped.
    func encodeInterrupt() throws -> Data {
        ClaudeFrames.controlRequest(id: makeID(), ["subtype": "interrupt"]).frame
    }

    func encodeDecision(id: String, _ d: Decision) throws -> Data {
        let original = state.withLock { $0.pending.removeValue(forKey: id) }
        return ClaudeFrames.decision(id: id, d, original: original).frame
    }

    // MARK: parse

    func parse(_ line: Data) -> [Event] {
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [] }
        // A non-JSON line, for example an npm notice, must not fail the wire.
        guard text.hasPrefix("{") else { return [Event(.status(.running, text: text))] }
        guard let m = JSONValue.parse(line), case .object = m else {
            var why = "not an object"
            do { _ = try JSONSerialization.jsonObject(with: line) } catch { why = error.localizedDescription }
            return [
                Event(
                    .error(
                        WireError(
                            message: "claude: malformed JSON frame: \(why)", code: "malformed_frame",
                            endReason: .protocol)))
            ]
        }
        switch m["type"].stringValue {
        case "system": return system(m)
        case "assistant": return assistant(m)
        case "user": return user(m)
        case "stream_event": return streamEvent(m)
        case "result": return result(m)
        case "control_request": return controlRequest(m)
        case "control_response":
            controlResponse(m)
            return []
        case "rate_limit_event": return rateLimit(m)
        default: return []
        }
    }

    private func system(_ m: JSONValue) -> [Event] {
        switch m["subtype"].stringValue {
        case "init": return [Event(.initialized, sessionID: m["session_id"]?.string.flatMap { $0.isEmpty ? nil : $0 })]
        case "session_state_changed":
            switch m["state"].stringValue {
            case "idle": return [Event(.status(.idle, text: nil))]
            case "running": return [Event(.status(.running, text: nil))]
            default: return []
            }
        case "status": return [Event(.status(.running, text: m["status"].stringValue))]
        case "compact_boundary": return [Event(.status(.running, text: "compacting"))]
        default: return []
        }
    }

    private func assistant(_ m: JSONValue) -> [Event] {
        guard let msg = m["message"], case .object = msg else { return [] }
        var out: [Event] = []
        for b in msg["content"]?.array ?? [] {
            switch b["type"].stringValue {
            case "text":
                if let t = b["text"]?.string, !t.isEmpty { out.append(Event(.assistant(text: t, delta: false))) }
            case "tool_use": out.append(toolStarted(b))
            default: break
            }
        }
        if let u = ClaudeFrames.usage(msg["usage"]) { out.append(Event(.usage(u))) }
        return out
    }

    // The CLI sends each tool start twice: from content_block_start with an empty input, then from the
    // assistant frame with the full input. Both keep the same id, and consumers dedupe by id.
    private func toolStarted(_ b: JSONValue) -> Event {
        let input = ClaudeFrames.input(b["input"])
        let id = b["id"].stringValue
        let name = b["name"].stringValue
        let kind = ToolClassifier.kind(for: name)
        if !id.isEmpty && !name.isEmpty { state.withLock { $0.tools[id] = name } }
        return Event(
            .tool(
                ToolEvent(
                    id: id, name: name, kind: kind, input: input, status: .started,
                    paths: ToolClassifier.paths(kind: kind, input: input))))
    }

    private func user(_ m: JSONValue) -> [Event] {
        guard let msg = m["message"], case .object = msg else { return [] }
        var out: [Event] = []
        for b in msg["content"]?.array ?? [] {
            switch b["type"].stringValue {
            case "tool_result":
                let id = b["tool_use_id"].stringValue
                let name = state.withLock { $0.tools.removeValue(forKey: id) } ?? ""
                out.append(
                    Event(
                        .tool(
                            ToolEvent(
                                id: id, name: name, kind: ToolClassifier.kind(for: name),
                                output: ClaudeFrames.flatten(b["content"]),
                                status: b["is_error"]?.bool == true ? .failed : .completed))))
            case "text":
                if let t = b["text"]?.string, !t.isEmpty { out.append(Event(.user(text: t))) }
            default: break
            }
        }
        if out.isEmpty, let t = msg["content"]?.string, !t.isEmpty { out.append(Event(.user(text: t))) }
        return out
    }

    private func streamEvent(_ m: JSONValue) -> [Event] {
        guard let ev = m["event"] else { return [] }
        switch ev["type"].stringValue {
        case "content_block_delta":
            guard ev.at("delta", "type")?.string == "text_delta", let t = ev.at("delta", "text")?.string, !t.isEmpty
            else { return [] }
            return [Event(.assistant(text: t, delta: true))]
        case "content_block_start":
            guard let b = ev["content_block"], b["type"]?.string == "tool_use" else { return [] }
            return [toolStarted(b)]
        case "message_start": return ClaudeFrames.usage(ev.at("message", "usage")).map { [Event(.usage($0))] } ?? []
        case "message_delta": return ClaudeFrames.usage(ev["usage"]).map { [Event(.usage($0))] } ?? []
        default: return []
        }
    }

    private func result(_ m: JSONValue) -> [Event] {
        state.withLock {
            $0.sawResult = true
            $0.active = false
        }
        var out = cancelOpenTools()
        var r = TurnResult(
            subtype: m["subtype"].stringValue, isError: m["is_error"]?.bool ?? false, text: ClaudeFrames.resultText(m),
            sessionID: m["session_id"]?.string.flatMap { $0.isEmpty ? nil : $0 },
            usage: ClaudeFrames.usage(m["usage"]) ?? Usage())
        if let cost = m["total_cost_usd"]?.double { r.usage.costUSD = cost }
        if r.isError {
            // A result whose subtype is its only text, for example error_max_turns, has no end reason.
            let c = Classifier.classify(r, harness: .claude)
            r.endReason = c.cls == .none ? nil : EndReason(rawValue: c.cls.rawValue)
            r.code = c.code
        }
        out.append(Event(.result(r), sessionID: r.sessionID))
        return out
    }

    // The ids sort, so the events have a stable order.
    private func cancelOpenTools() -> [Event] {
        let ids = state.withLock { s -> [String] in
            defer { s.tools.removeAll() }
            return s.tools.keys.sorted()
        }
        return ids.map { Event(.tool(ToolEvent(id: $0, status: .cancelled))) }
    }

    private func controlRequest(_ m: JSONValue) -> [Event] {
        guard let req = m["request"], case .object = req else { return [] }
        let id = m["request_id"].stringValue
        let subtype = req["subtype"].stringValue
        guard subtype == "can_use_tool" else {
            write(ClaudeFrames.unsupported(id: id, subtype: subtype))
            return []
        }
        let raw = req["input"]
        let input = ClaudeFrames.input(raw)
        let tool = req["tool_name"].stringValue
        let kind = ToolClassifier.permissionKind(name: tool, input: input)
        if let d = policy.answer(kind: kind, tool: tool) {
            // No tool event here: the tool_use block announced the start, and the tool_result ends the
            // same id. An event keyed by the control request id would never end.
            write(ClaudeFrames.decision(id: id, d, original: raw))
            return []
        }
        if let raw { state.withLock { $0.pending[id] = raw } }
        let question = [req["title"].stringValue, req["description"].stringValue].first { !$0.isEmpty }
        return [
            Event(
                .permission(
                    PermissionRequest(
                        id: id, tool: tool, kind: kind, question: question ?? "Allow \(tool)?", input: input,
                        toolUseID: req["tool_use_id"]?.string)))
        ]
    }

    private func controlResponse(_ m: JSONValue) {
        guard let resp = m["response"], case .object = resp else { return }
        let id = resp["request_id"].stringValue
        let r: Result<JSONValue?, AgentBinderError> =
            resp["subtype"]?.string == "error"
            ? .failure(.vendor(code: 0, message: "claude: " + (resp["error"]?.string ?? "control request failed")))
            : .success(resp["response"])
        let reply = state.withLock { s -> Reply? in
            if !id.isEmpty, id == s.initID, case .success(let v) = r { s.models = ClaudeFrames.models(v) ?? [] }
            return s.replies[id]
        }
        reply?.resolve(r)
    }

    private func rateLimit(_ m: JSONValue) -> [Event] {
        let info = m["rate_limit_info"] ?? m
        let status = info["status"].stringValue
        let rejected = status == "rejected" || status == "blocked"
        var out: [Event] = []
        if let l = Limits(claude: info, rejected: rejected) { out.append(Event(.limits(l))) }
        if rejected {
            let text =
                [info["message"].stringValue, m["message"].stringValue].first { !$0.isEmpty }
                ?? "claude rate limit rejected"
            out.append(Event(.error(Self.classified(text))))
        }
        if out.isEmpty { out.append(Event(.status(.running, text: "rate_limit:\(status)"))) }
        return out
    }

    // MARK: exit

    func exitEvents(code: Int32, stderr: String) -> [Event] {
        var out = cancelOpenTools()
        if state.value.sawResult { return out }
        var text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = "claude exited with code \(code) before a result" }
        out.append(Event(.error(Self.classified(text))))
        return out
    }

    private static func classified(_ text: String) -> WireError {
        let c = Classifier.classify(text, harness: .claude)
        return WireError(
            message: text, code: c.code, endReason: c.cls == .none ? nil : EndReason(rawValue: c.cls.rawValue))
    }

    // Parse runs on the read loop, so a reply from parse goes out on its own task.
    private func write(_ v: JSONValue) {
        guard let w = state.value.writer else { return }
        Task { try? await w.write(v) }
    }
}
