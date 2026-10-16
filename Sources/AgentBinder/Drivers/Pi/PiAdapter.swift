import Foundation

/// The codec of `pi --mode rpc`: NDJSON commands and events, not JSON-RPC.
///
/// The frames follow pi 0.84.1: `agent_start`, `turn_start`, `message_start` and `message_end` with
/// content blocks, `turn_end` and `agent_end`.
final class PiAdapter: WireAdapter, RequestPrompting, InterruptEncoding, TurnStateReporting, SteerSupporting,
    Sendable
{
    private struct State {
        var firstPrompt: Bool
        var sawEnd = false
        var sawError = ""
        var turnActive = false
        /// The id of the open prompt frame, until its ack.
        var promptID: String?
    }

    let commands = PiCommands()
    private let policy: PermissionPolicy
    private let instructions: String?
    private let state: Locked<State>

    init(policy: PermissionPolicy = PermissionPolicy(), instructions: String? = nil) {
        self.policy = policy
        self.instructions = instructions
        let first = !(instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        state = Locked(State(firstPrompt: first))
    }

    var turnActive: Bool { state.value.turnActive }

    // pi has no handshake.
    func handshake(_ w: FrameWriter) async throws -> [Event] {
        commands.attach(w)
        return []
    }

    // MARK: prompt

    // Fixed on purpose: a failed write does not leave the turn active.
    func promptSession(_ p: Prompt) async throws {
        let frame = try encodePrompt(p)
        do {
            guard let w = commands.writer else { throw AgentBinderError.sessionClosed }
            try await w.write(frame)
        } catch {
            endTurn()
            throw error
        }
    }

    // Fixed on purpose: the error of the last turn resets, and the prompt has an id, so its ack matches it.
    func encodePrompt(_ p: Prompt) throws -> Data {
        guard p.attachments.isEmpty else { throw AgentBinderError.unsupported("pi does not accept prompt attachments") }
        let id = commands.nextID()
        let first = try state.withLock { s -> Bool in
            if s.turnActive { throw AgentBinderError.turnActive }
            defer {
                s.firstPrompt = false
                s.sawEnd = false
                s.sawError = ""
                s.turnActive = true
                s.promptID = id
            }
            return s.firstPrompt
        }
        let text = Instructions.withInstructions(instructions, p.text, first: first)
        return (["type": "prompt", "message": .string(text), "id": .string(id)] as JSONValue).frame
    }

    /// Pi gives a steer to the model after the running tool calls.
    func steer(_ p: Prompt) async throws {
        guard p.attachments.isEmpty else { throw AgentBinderError.unsupported("pi does not accept steer attachments") }
        guard turnActive else { throw AgentBinderError.noActiveTurn }
        do {
            try await commands.request(["type": "steer", "message": .string(p.text)])
        } catch {
            throw AgentBinderError.unsupported("pi steer: \(error)")
        }
    }

    /// Sends `set_model`. The id is `provider/model`, as the model list gives it.
    func setModel(_ model: String) async throws {
        let parts = model.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw AgentBinderError.invalidRequest("pi: model \"\(model)\" is not provider/model")
        }
        try await commands.request([
            "type": "set_model", "provider": .string(String(parts[0])), "modelId": .string(String(parts[1])),
        ])
    }

    func encodeInterrupt() throws -> Data { (["type": "abort"] as JSONValue).frame }

    func encodeDecision(id: String, _ d: Decision) throws -> Data {
        let v: JSONValue = [
            "type": "permission_response", "id": .string(id), "approved": .bool(d.allow),
            "message": .string(d.message ?? ""),
        ]
        return v.frame
    }

    private func endTurn() {
        state.withLock { s in
            s.turnActive = false
            s.promptID = nil
        }
    }

    // MARK: parse

    func parse(_ line: Data) -> [Event] {
        guard let m = JSONValue.parse(line), m.object != nil else { return [] }
        switch m["type"].stringValue {
        case "response":
            return response(m)
        case "ready", "session_start", "session_started":
            let id = m["session_id"].stringValue
            return [Event(.initialized, sessionID: id.isEmpty ? nil : id)]
        case "agent_start", "turn_start":
            return [Event(.status(.running, text: nil))]
        case "message_start", "message_end":
            return message(m["message"], end: m["type"] == "message_end")
        case "turn_end":
            noteError(m)
            return []
        case "message_update":
            return update(m["assistantMessageEvent"] ?? m["event"])
        case "message":
            let text = m["text"].stringValue
            return text.isEmpty ? [] : [Event(.assistant(text: text, delta: false))]
        case "tool_execution_start", "tool_execution_end":
            return [Event(.tool(execution(m)))]
        case "permission_request", "permission":
            return permission(m)
        case "agent_end":
            return agentEnd()
        case "error":
            let named = m["error"]?.string ?? m["message"]?.string ?? ""
            let text = named.isEmpty ? m["error"]?.jsonString ?? "pi error" : named
            state.withLock { $0.sawError = text }
            return [Event(.error(Self.classified(text)))]
        default:
            return []
        }
    }

    // The prompt ack has the prompt id. An ack with no id and command prompt is the ack of an older pi.
    private func response(_ m: JSONValue) -> [Event] {
        let id = m["id"].stringValue
        let ack = state.withLock { s -> Bool in
            guard let p = s.promptID, id == p || (id.isEmpty && m["command"] == "prompt") else { return false }
            s.promptID = nil
            return true
        }
        guard ack else {
            commands.deliver(m)
            return []
        }
        guard case .failure(let e) = PiCommands.reply(m) else { return [] }
        endTurn()
        return [Event(.error(Self.classified("\(e)")))]
    }

    private func message(_ msg: JSONValue?, end: Bool) -> [Event] {
        guard let msg, msg.object != nil else { return [] }
        noteError(msg)
        if msg["role"] == "user" { return [] }
        var out: [Event] = []
        for b in msg["content"]?.array ?? [] where b.object != nil {
            switch b["type"].stringValue {
            case "text":
                let t = b["text"].stringValue
                if !t.isEmpty { out.append(Event(.assistant(text: t, delta: false))) }
            case "toolCall":
                let name = b["name"].stringValue
                let kind = ToolClassifier.kind(for: name)
                let input = b["arguments"]?.jsonString ?? ""
                out.append(
                    Event(
                        .tool(
                            ToolEvent(
                                id: b["id"].stringValue, name: name, kind: kind, input: input, status: .started,
                                paths: ToolClassifier.paths(kind: kind, input: input)))))
            case "toolResult":
                let name = b["name"].stringValue
                out.append(
                    Event(
                        .tool(
                            ToolEvent(
                                id: b["id"].stringValue, name: name, kind: ToolClassifier.kind(for: name),
                                output: b["content"]?.flattenedText ?? "", status: .completed))))
            default: break
            }
        }
        // The usage of message_start is all zero.
        if end, let u = Self.usage(msg["usage"]) { out.append(Event(.usage(u))) }
        return out
    }

    private func update(_ ev: JSONValue?) -> [Event] {
        guard let ev, ev.object != nil else { return [] }
        let type = ev["type"].stringValue
        switch type {
        case "text_delta", "text":
            let t = ev["delta"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? ev["text"].stringValue
            return t.isEmpty ? [] : [Event(.assistant(text: t, delta: type == "text_delta"))]
        case "tool_use", "tool_call", "tool_result":
            let name = ev["name"].stringValue
            return [
                Event(
                    .tool(
                        ToolEvent(
                            id: ev["id"].stringValue, name: name, kind: ToolClassifier.kind(for: name),
                            status: type == "tool_result" ? .completed : .started)))
            ]
        default:
            return []
        }
    }

    // Quirk: the pi RPC docs name toolCallId, toolName, args and result. The older keys id, tool,
    // input and output are read too.
    private func execution(_ m: JSONValue) -> ToolEvent {
        let name = m["toolName"]?.string ?? m["tool"].stringValue
        let kind = ToolClassifier.kind(for: name)
        let input = (m["args"] ?? m["input"])?.jsonString ?? ""
        let output = m["output"]?.string ?? m.at("result", "content")?.flattenedText ?? ""
        let status: ToolStatus =
            m["type"] == "tool_execution_start" ? .started : (m["isError"]?.bool == true ? .failed : .completed)
        return ToolEvent(
            id: m["toolCallId"]?.string ?? m["id"].stringValue, name: name, kind: kind, input: input, output: output,
            status: status, paths: ToolClassifier.paths(kind: kind, input: input))
    }

    private func permission(_ m: JSONValue) -> [Event] {
        let id = m["id"].stringValue
        let tool = m["tool"].stringValue
        let kind = ToolClassifier.kind(for: tool)
        if let d = policy.answer(kind: kind, tool: tool) {
            if let frame = try? encodeDecision(id: id, d), let w = commands.writer {
                Task { try? await w.write(frame) }
            }
            return []
        }
        let question = [m["message"].stringValue, m["question"].stringValue].first { !$0.isEmpty }
        return [
            Event(
                .permission(
                    PermissionRequest(id: id, tool: tool, kind: kind, question: question ?? "pi requests permission")))
        ]
    }

    private func agentEnd() -> [Event] {
        let err = state.withLock { s -> String in
            s.sawEnd = true
            s.turnActive = false
            s.promptID = nil
            return s.sawError
        }
        guard !err.isEmpty else { return [Event(.result(TurnResult(subtype: "success")))] }
        let w = Self.classified(err)
        return [
            Event(
                .result(
                    TurnResult(
                        subtype: "error_during_execution", isError: true, text: err, endReason: w.endReason,
                        code: w.code)))
        ]
    }

    // A provider failure on a message makes agent_end a failed result, not a silent success.
    private func noteError(_ m: JSONValue) {
        let key = m["message"].flatMap { $0.object != nil ? $0 : nil } ?? m
        let text = key["errorMessage"].stringValue
        let stop = key["stopReason"].stringValue
        state.withLock { s in
            if !text.isEmpty { s.sawError = text }
            if stop == "error" && s.sawError.isEmpty { s.sawError = "pi turn ended with stopReason error" }
        }
    }

    static func usage(_ v: JSONValue?) -> Usage? {
        guard let v, v.object != nil else { return nil }
        func n(_ k: String) -> Int64 { Int64(v[k]?.double ?? 0) }
        var u = Usage(input: n("input"), output: n("output"), cacheRead: n("cacheRead"), cacheCreation: n("cacheWrite"))
        guard u.input != 0 || u.output != 0 || u.cacheRead != 0 || u.cacheCreation != 0 else { return nil }
        u.costUSD = v.at("cost", "total")?.double ?? 0
        return u
    }

    private static func classified(_ text: String) -> WireError {
        let c = Classifier.classify(text, harness: .pi)
        return WireError(
            message: text, code: c.code, endReason: c.cls == .none ? nil : EndReason(rawValue: c.cls.rawValue))
    }

    // MARK: exit

    // Fixed on purpose: an idle session that ends with code 0 gives no error.
    func exitEvents(code: Int32, stderr: String) -> [Event] {
        commands.failAll()
        let s = state.value
        if !s.turnActive && (s.sawEnd || code == 0) { return [] }
        var text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = s.sawError }
        if text.isEmpty { text = "pi exited with code \(code) before agent_end" }
        return [Event(.error(Self.classified(text)))]
    }
}
