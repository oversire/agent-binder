import Foundation

/// An OpenCode 2.x session.
typealias OpenCodeV2Session = OpenCodeSession<OpenCodeV2Dialect>

/// The REST shapes and the bus events of OpenCode 2.x.
struct OpenCodeV2Dialect: OpenCodeDialect {
    /// The instruction entry key. Quirk: a key with a slash gives 404.
    static let instructionKey = "agentbinder.instructions"

    let sessionID: String
    let directory: String
    var variant: String?
    /// The delivered UTF-8 length of each text, by `<assistantMessageID>/<ordinal>`.
    private var text: [String: Int] = [:]
    /// Quirk: only session.tool.input.started has the tool name.
    private var tools: [String: String] = [:]

    init(sessionID: String, directory: String, variant: String?) {
        self.sessionID = sessionID
        self.directory = directory
        self.variant = variant
    }

    private var base: String { "/session/\(sessionID)" }

    // MARK: calls

    mutating func prompt(_ p: Prompt) throws -> OpenCodeCall {
        var body: [String: JSONValue] = ["text": .string(p.text), "location": ["directory": .string(directory)]]
        var files: [JSONValue] = []
        for a in PromptAttachment.sorted(p.attachments) {
            let l = try a.load()
            if case .file(let url) = a.source {
                files.append(["uri": .string(url.absoluteString), "name": .string(url.lastPathComponent)])
            } else {
                files.append(["uri": .string("data:\(l.mime);base64,\(l.base64)")])
            }
        }
        if !files.isEmpty { body["files"] = .array(files) }
        text = [:]
        tools = [:]
        return OpenCodeCall(path: base + "/prompt", body: .object(body))
    }

    var interrupt: OpenCodeCall { OpenCodeCall(path: base + "/interrupt") }

    // Quirk: 2.0.26 reads `decision`; older 2.x builds read `reply`. Each ignores the other key.
    func answer(_ permissionID: String, _ d: Decision) -> OpenCodeCall {
        let v: JSONValue = .string(d.allow ? "once" : "reject")
        return OpenCodeCall(path: base + "/permission/\(permissionID)/reply", body: ["decision": v, "reply": v])
    }

    /// The running turn keeps its model.
    mutating func setModel(_ id: String) -> OpenCodeCall? {
        Self.setModelCall(base, id, variant)
    }

    static func setModelCall(_ base: String, _ model: String, _ variant: String?) -> OpenCodeCall? {
        guard let ref = modelRef(model, variant: variant) else { return nil }
        return OpenCodeCall(path: base + "/model", body: ["model": ref])
    }

    /// The calls that set the instructions entry, in the order to try. It is empty for blank text.
    /// Quirk: 2.0.26 moved the route under `/experimental`. Older 2.x builds give 404 there.
    static func instructionsCalls(_ sessionID: String, _ text: String?) -> [OpenCodeCall] {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        let path = "/session/\(sessionID)/instructions/entries/\(instructionKey)"
        return ["/experimental" + path, path].map { OpenCodeCall(method: "PUT", path: $0, body: ["value": .string(t)]) }
    }

    /// `provider/model` splits at the first slash. Blank is nil.
    static func modelRef(_ model: String?, variant: String?) -> JSONValue? {
        let m = (model ?? "").trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return nil }
        var ref: [String: JSONValue]
        if let i = m.firstIndex(of: "/") {
            ref = ["providerID": .string(String(m[..<i])), "id": .string(String(m[m.index(after: i)...]))]
        } else {
            ref = ["id": .string(m)]
        }
        if let v = variant, !v.isEmpty { ref["variant"] = .string(v) }
        return .object(ref)
    }

    /// The model of the operator config: `$XDG_CONFIG_HOME/opencode/opencode.json`, else
    /// `~/.config/opencode/opencode.json`. A string `p/m`, or an object `{providerID, model}`.
    static func operatorModel(environment: [String: String]) -> String? {
        let xdg = environment["XDG_CONFIG_HOME"] ?? ""
        let dir =
            xdg.isEmpty
            ? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".config")
            : URL(fileURLWithPath: xdg)
        let file = dir.appendingPathComponent("opencode/opencode.json")
        guard let data = try? Data(contentsOf: file), let v = JSONValue.parse(data), let m = v["model"] else {
            return nil
        }
        if let s = m.string {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        let model = m["model"].stringValue
        guard !model.isEmpty else { return nil }
        let provider = m["providerID"].stringValue
        return provider.isEmpty ? model : provider + "/" + model
    }

    // MARK: events

    mutating func parse(_ type: String, _ d: JSONValue, _ t: inout OpenCodeTurn) -> OpenCodeStep {
        switch type {
        case "session.execution.started", "session.step.started":
            return OpenCodeStep([Event(.status(.running, text: nil))])
        case "session.text.delta":
            let delta = d["delta"].stringValue
            guard !delta.isEmpty else { return OpenCodeStep() }
            text[Self.textKey(d), default: 0] += delta.utf8.count
            return OpenCodeStep([Event(.assistant(text: delta, delta: true))])
        case "session.text.ended":
            return OpenCodeStep(textEnded(d))
        case "session.tool.input.started", "session.tool.input.ended", "session.tool.called", "session.tool.success",
            "session.tool.failed":
            return OpenCodeStep(tool(type, d))
        case "session.step.ended", "session.usage.updated":
            return OpenCodeStep(Self.usage(d).map { [Event(.usage($0))] } ?? [])
        case "session.execution.succeeded":
            t.sawResult = true
            t.busy = false
            let r =
                t.lastError.isEmpty
                ? TurnResult(subtype: "success", sessionID: sessionID)
                : Self.result(t.lastError, Self.classified(t.lastError, status: 0, type: ""))
            return OpenCodeStep([Event(.result(r))], endsTurn: true)
        case "session.execution.interrupted":
            t.sawResult = true
            t.busy = false
            let r = TurnResult(subtype: "interrupted", isError: true, text: "turn interrupted", sessionID: sessionID)
            return OpenCodeStep([Event(.result(r))], endsTurn: true)
        case "session.step.failed", "session.execution.failed":
            var (text, status, kind) = Self.failure(d)
            // Quirk: an interrupt fails the step with type "aborted"; session.execution.interrupted ends the turn.
            if kind == "aborted" { return OpenCodeStep() }
            if text.isEmpty { text = "opencode2 session error" }
            let w = Self.classified(text, status: status, type: kind)
            t.sawResult = true
            t.lastError = text
            // Quirk: a failed step ends the step, not the turn.
            guard type == "session.execution.failed" else { return OpenCodeStep([Event(.error(w))]) }
            t.busy = false
            return OpenCodeStep([Event(.error(w)), Event(.result(Self.result(text, w)))], endsTurn: true)
        case "permission.asked":
            return OpenCodeStep(permission(d))
        default:
            return OpenCodeStep()
        }
    }

    // Quirk: the end text can hold text that never streamed, for example a trailing "(exit code 0)".
    private mutating func textEnded(_ d: JSONValue) -> [Event] {
        let full = d["text"].stringValue
        guard !full.isEmpty else { return [] }
        let key = Self.textKey(d)
        let seen = text[key] ?? 0
        let n = full.utf8.count
        text[key] = n
        if seen == n { return [] }
        if seen == 0 || seen > n { return [Event(.assistant(text: full, delta: false))] }
        return [Event(.assistant(text: String(decoding: full.utf8.dropFirst(seen), as: UTF8.self), delta: true))]
    }

    private mutating func tool(_ type: String, _ d: JSONValue) -> [Event] {
        let id = d["id"].stringValue
        guard !id.isEmpty else { return [] }
        if type == "session.tool.input.started" { tools[id] = d["name"].stringValue }
        let name = tools[id] ?? d["name"].stringValue
        var input = ""
        var output = ""
        var status = ToolStatus.started
        switch type {
        case "session.tool.input.ended": input = d["text"].stringValue
        case "session.tool.called":
            if let v = d["input"] { input = v.string ?? v.jsonString }
        case "session.tool.success":
            output = Self.toolOutput(d)
            status = .completed
        case "session.tool.failed":
            let e = Self.failure(d).text
            output = e.isEmpty ? Self.toolOutput(d) : e
            status = .failed
        default: break
        }
        let kind = ToolClassifier.kind(for: name)
        return [
            Event(
                .tool(
                    ToolEvent(
                        id: id, name: name, kind: kind, input: input, output: output, status: status,
                        paths: ToolClassifier.paths(kind: kind, input: input))))
        ]
    }

    private func permission(_ d: JSONValue) -> [Event] {
        let id = d["id"].stringValue
        guard !id.isEmpty else { return [] }
        let action = d["action"].stringValue
        let label = action.isEmpty ? "OpenCode requests permission" : action
        let resources = (d["resources"]?.array ?? []).compactMap(\.string).filter { !$0.isEmpty }
        let fallback = resources.isEmpty ? label : label + ": " + resources.joined(separator: ", ")
        let message = d["message"].stringValue
        return [
            Event(
                .permission(
                    PermissionRequest(
                        id: id, tool: action, kind: ToolClassifier.permissionKind(name: action, input: ""),
                        question: message.isEmpty ? fallback : message)))
        ]
    }

    static func textKey(_ d: JSONValue) -> String {
        d["assistantMessageID"].stringValue + "/" + numberText(d["ordinal"])
    }

    /// A stable text of a JSON number or string: an integer has no fraction.
    static func numberText(_ v: JSONValue?) -> String {
        switch v {
        case .int(let i): return String(i)
        case .double(let x) where x == x.rounded() && abs(x) < 9e15: return String(Int64(x))
        case .double(let x): return String(x)
        case .string(let s): return s
        default: return ""
        }
    }

    /// The text items of `content`, one on each line, else `output`.
    static func toolOutput(_ d: JSONValue) -> String {
        guard let items = d["content"]?.array, !items.isEmpty else { return d["output"].stringValue }
        return items.compactMap { $0["text"]?.string }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The text, the HTTP status and the type of a failure.
    static func failure(_ d: JSONValue) -> (text: String, status: Int, type: String) {
        guard let e = d["error"], e.object != nil else { return (OpenCodeV1Dialect.errorText(d), 0, "") }
        let text = [e["message"], e["type"], e["name"]].lazy.compactMap { $0?.string }.first { !$0.isEmpty } ?? ""
        return (text, Int(e["status"]?.double ?? 0), e["type"].stringValue)
    }

    /// The typed provider failures, else the shared rules.
    static func classified(_ text: String, status: Int, type: String) -> WireError {
        let typed: (EndReason, String)? =
            switch type {
            case "provider.auth": (.auth, "invalid_credentials")
            case "provider.rate-limit": (.limit, "rate_limited")
            case "provider.quota": (.limit, "credits_exhausted")
            case "provider.internal", "provider.transport": (.overloaded, "capacity")
            case "provider.invalid-request", "provider.invalid-output", "provider.unsupported-operation":
                (.protocol, "wire_drift")
            default: nil
            }
        if let (reason, code) = typed {
            return WireError(message: text, code: "opencode2.\(code)", endReason: reason)
        }
        return OpenCodeErrors.classified(text, status: status, harness: .opencode2)
    }

    static func result(_ text: String, _ w: WireError) -> TurnResult {
        TurnResult(subtype: "error_during_execution", isError: true, text: text, endReason: w.endReason, code: w.code)
    }

    static func usage(_ d: JSONValue) -> Usage? {
        guard let tok = d["tokens"], tok.object != nil else { return nil }
        func n(_ v: JSONValue?) -> Int64 { Int64(v?.double ?? 0) }
        var u = Usage(
            input: n(tok["input"]), output: n(tok["output"]),
            cacheRead: n(tok.at("cache", "read")) + n(tok["cache_read"]),
            cacheCreation: n(tok.at("cache", "write")))
        guard u.input != 0 || u.output != 0 || u.cacheRead != 0 || u.cacheCreation != 0 else { return nil }
        u.costUSD = d["cost"]?.double ?? 0
        let model = d.at("model", "id").stringValue
        if !model.isEmpty { u.model = model }
        return u
    }
}
