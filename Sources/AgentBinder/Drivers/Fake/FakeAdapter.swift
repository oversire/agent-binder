import Foundation

/// The codec of the fake NDJSON vocabulary.
final class FakeAdapter: WireAdapter, TurnStateReporting, SteerSupporting, Sendable {
    private struct State {
        var writer: FrameWriter?
        var active = false
        var models: [ModelInfo] = []
    }

    private let state = Locked(State())
    private let steers: Bool

    init(steers: Bool) { self.steers = steers }

    var turnActive: Bool { state.value.active }
    var offeredModels: [ModelInfo] { state.value.models }

    func handshake(_ w: FrameWriter) async throws -> [Event] {
        state.withLock { $0.writer = w }
        return []
    }

    func encodePrompt(_ p: Prompt) throws -> Data {
        state.withLock { $0.active = true }
        return JSONValue.object(["type": "user", "text": .string(p.text)]).frame
    }

    func steer(_ p: Prompt) async throws {
        guard steers else { throw AgentBinderError.unsupported("fake steer is off") }
        let (active, w) = state.withLock { ($0.active, $0.writer) }
        guard active, let w else { throw AgentBinderError.noActiveTurn }
        try await w.write(JSONValue.object(["type": "steer", "text": .string(p.text)]))
    }

    func encodeDecision(id: String, _ d: Decision) throws -> Data {
        var o: [String: JSONValue] = ["type": "decision", "id": .string(id), "allow": .bool(d.allow)]
        if let m = d.message { o["message"] = .string(m) }
        return JSONValue.object(o).frame
    }

    func parse(_ line: Data) -> [Event] {
        guard let v = JSONValue.parse(line), case .object = v else { return [] }
        let text = v["text"]?.string ?? ""
        switch v["type"]?.string?.lowercased() {
        case "init":
            if let models = v["models"]?.array {
                state.withLock { $0.models = models.compactMap(FakeAdapter.model) }
            }
            return [Event(.initialized, sessionID: v["session_id"]?.string)]
        case "assistant": return [Event(.assistant(text: text, delta: v["delta"]?.bool ?? false))]
        case "thought": return [Event(.thought(text: text, delta: v["delta"]?.bool ?? false))]
        case "user": return [Event(.user(text: text))]
        case "tool":
            let name = v["name"]?.string ?? ""
            let kind = ToolClassifier.kind(for: name)
            let input = v["input"]?.string ?? ""
            return [
                Event(
                    .tool(
                        ToolEvent(
                            id: v["id"]?.string ?? "", name: name, kind: kind, input: input,
                            output: v["output"]?.string ?? "",
                            status: ToolStatus(rawValue: v["status"]?.string ?? "") ?? .started,
                            paths: ToolClassifier.paths(kind: kind, input: input))))
            ]
        case "permission":
            let name = v["tool"]?.string ?? ""
            let input = v["input"]?.string ?? ""
            return [
                Event(
                    .permission(
                        PermissionRequest(
                            id: v["id"]?.string ?? "", tool: name,
                            kind: ToolClassifier.permissionKind(name: name, input: input),
                            question: v["question"]?.string ?? "", input: input)))
            ]
        case "usage": return [Event(.usage(FakeAdapter.usage(v)))]
        case "status":
            let s = SessionStatus(rawValue: v["status"]?.string ?? "") ?? .unknown
            return [Event(.status(s, text: v["text"]?.string))]
        case "result":
            state.withLock { $0.active = false }
            let r = TurnResult(
                subtype: v["subtype"]?.string ?? "success", isError: v["is_error"]?.bool ?? false, text: text,
                sessionID: v["session_id"]?.string, usage: v["usage"].map(FakeAdapter.usage) ?? Usage())
            return [Event(.result(r), sessionID: r.sessionID)]
        case "error":
            return [
                Event(
                    .error(
                        WireError(
                            message: v["error"]?.string ?? text, code: v["code"]?.string ?? "fake_error",
                            endReason: v["end_reason"]?.string.flatMap(EndReason.init(rawValue:)))))
            ]
        default: return []
        }
    }

    func exitEvents(code: Int32, stderr: String) -> [Event] {
        guard code != 0 else { return [] }
        var msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.isEmpty { msg = "fake harness exited with code \(code)" }
        return [Event(.error(WireError(message: msg, code: "process_exited", endReason: .failed)))]
    }

    private static func usage(_ v: JSONValue) -> Usage {
        Usage(input: v["input"]?.int ?? 0, output: v["output"]?.int ?? 0, model: v["model"]?.string)
    }

    private static func model(_ v: JSONValue) -> ModelInfo? {
        guard let id = v["id"]?.string else { return nil }
        return ModelInfo(id: id, name: v["name"]?.string, isDefault: v["default"]?.bool ?? false)
    }
}
