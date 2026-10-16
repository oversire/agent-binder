import Foundation

/// An OpenCode 1.x session.
typealias OpenCodeV1Session = OpenCodeSession<OpenCodeV1Dialect>

/// The REST shapes and the bus events of OpenCode 1.x.
struct OpenCodeV1Dialect: OpenCodeDialect {
    let sessionID: String
    let directory: String
    var model: String?
    var effort: String?
    var instructions: String?
    private var firstPrompt = true
    /// The delivered UTF-8 length of each text part.
    private var parts: [String: Int] = [:]
    private var roles: [String: String] = [:]
    private var partOwner: [String: String] = [:]

    init(sessionID: String, directory: String, model: String?, effort: String?, instructions: String?) {
        self.sessionID = sessionID
        self.directory = directory
        self.model = model
        self.effort = effort
        self.instructions = instructions
    }

    private var base: String { "/session/\(sessionID)" }

    // MARK: calls

    /// Attachments first, images first, then one text part. The model and the effort go with every turn;
    /// the instructions go with the first turn of the session object.
    mutating func prompt(_ p: Prompt) throws -> OpenCodeCall {
        var list: [JSONValue] = []
        for a in PromptAttachment.sorted(p.attachments) {
            let l = try a.load()
            if case .file(let url) = a.source {
                list.append(
                    [
                        "type": "file", "mime": .string(l.mime), "filename": .string(url.path),
                        "url": .string(url.absoluteString),
                    ])
            } else {
                list.append([
                    "type": "file", "mime": .string(l.mime), "url": .string("data:\(l.mime);base64,\(l.base64)"),
                ])
            }
        }
        list.append(["type": "text", "text": .string(p.text)])
        var body: [String: JSONValue] = ["parts": .array(list)]
        if let m = model, !m.isEmpty { body["model"] = Self.modelRef(m) }
        if let e = effort, !e.isEmpty { body["variant"] = .string(e) }
        let text = (instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if firstPrompt && !text.isEmpty { body["system"] = .string(text) }
        firstPrompt = false
        parts = [:]
        return OpenCodeCall(path: base + "/prompt_async", directory: directory, body: .object(body))
    }

    var interrupt: OpenCodeCall { OpenCodeCall(path: base + "/abort", directory: directory, body: [:]) }

    func answer(_ permissionID: String, _ d: Decision) -> OpenCodeCall {
        OpenCodeCall(
            path: base + "/permissions/\(permissionID)", directory: directory,
            body: ["response": .string(d.allow ? "once" : "reject")])
    }

    /// 1.x takes the model with each prompt, so the next prompt uses it.
    mutating func setModel(_ id: String) -> OpenCodeCall? {
        model = id
        return nil
    }

    /// `provider/model` splits at the first slash. A bare id has no provider.
    static func modelRef(_ m: String) -> JSONValue {
        guard let i = m.firstIndex(of: "/") else { return ["modelID": .string(m)] }
        return ["providerID": .string(String(m[..<i])), "modelID": .string(String(m[m.index(after: i)...]))]
    }

    // MARK: events

    mutating func parse(_ type: String, _ p: JSONValue, _ t: inout OpenCodeTurn) -> OpenCodeStep {
        switch type {
        case "session.idle":
            // An idle event with no turn, for example after a resume, is not a result.
            guard t.busy else { return OpenCodeStep() }
            t.sawResult = true
            t.busy = false
            let r =
                t.lastError.isEmpty
                ? TurnResult(subtype: "success", sessionID: sessionID)
                : OpenCodeErrors.failedResult(t.lastError, harness: .opencode)
            return OpenCodeStep([Event(.result(r))], endsTurn: true)
        case "session.error":
            var text = Self.errorText(p)
            if text.isEmpty { text = "opencode session error" }
            t.sawResult = true
            t.lastError = text
            // The turn runs until session.idle.
            return OpenCodeStep([Event(.error(OpenCodeErrors.classified(text, harness: .opencode)))])
        case "session.deleted":
            return OpenCodeStep(deleted: true)
        case "message.updated":
            return OpenCodeStep(message(p["info"], &t))
        case "message.part.updated":
            return OpenCodeStep(part(p["part"]))
        case "permission.updated", "permission.asked", "permission.v2.asked":
            let tool = p["type"].stringValue
            let question = [p["title"].stringValue, p["message"].stringValue].first { !$0.isEmpty }
            let r = PermissionRequest(
                id: p["id"].stringValue, tool: tool, kind: ToolClassifier.permissionKind(name: tool, input: ""),
                question: question ?? "OpenCode requests permission")
            return OpenCodeStep([Event(.permission(r))])
        default:
            // Fixed on purpose: init comes from the driver, because session.updated often has no session id.
            return OpenCodeStep()
        }
    }

    private mutating func message(_ info: JSONValue?, _ t: inout OpenCodeTurn) -> [Event] {
        guard let info, info.object != nil else { return [] }
        let id = info["id"].stringValue
        if !id.isEmpty { roles[id] = info["role"].stringValue }
        let text = Self.errorText(info)
        if !text.isEmpty {
            t.lastError = text
            return [Event(.error(OpenCodeErrors.classified(text, harness: .opencode)))]
        }
        // The message updates many times; the cost or the end time marks the final counts.
        let final = (info["cost"]?.double ?? 0) > 0 || info.at("time", "completed") != nil
        guard final, let u = Self.usage(info) else { return [] }
        return [Event(.usage(u))]
    }

    private mutating func part(_ part: JSONValue?) -> [Event] {
        guard let part, part.object != nil else { return [] }
        let id = part["id"].stringValue
        // The first message id of a part wins.
        var owner = partOwner[id]
        if owner == nil, let m = part["messageID"]?.string, !m.isEmpty {
            partOwner[id] = m
            owner = m
        }
        // Quirk: the bus echoes the user prompt as parts.
        if let owner, roles[owner] == "user" { return [] }
        switch part["type"].stringValue {
        case "text":
            let text = part["text"].stringValue
            guard !text.isEmpty else { return [] }
            let n = text.utf8.count
            let prev = parts[id] ?? 0
            // Fixed on purpose: a replacement also lowers the length, so later deltas start from it.
            parts[id] = n
            if prev == 0 || prev > n { return [Event(.assistant(text: text, delta: false))] }
            if prev == n { return [] }
            return [Event(.assistant(text: String(decoding: text.utf8.dropFirst(prev), as: UTF8.self), delta: true))]
        case "tool":
            return [Event(.tool(Self.tool(id, part)))]
        case "reasoning":
            return [Event(.status(.running, text: nil))]
        default:
            return []
        }
    }

    static func tool(_ id: String, _ part: JSONValue) -> ToolEvent {
        let name = part["tool"].stringValue
        let kind = ToolClassifier.kind(for: name)
        let st = part["state"]
        let input = st?["input"]?.jsonString ?? ""
        var output = st?["output"]?.string ?? ""
        let status: ToolStatus
        switch st?["status"].stringValue ?? "" {
        case "", "pending", "running": status = .started
        case "completed": status = .completed
        case "error":
            status = .failed
            if output.isEmpty { output = st.map(errorText) ?? "" }
        default: status = .started
        }
        return ToolEvent(
            id: id, name: name, kind: kind, input: input, output: output, status: status,
            paths: ToolClassifier.paths(kind: kind, input: input))
    }

    /// The text of `error`: its data message, its message, its name, or the error string itself.
    static func errorText(_ v: JSONValue) -> String {
        guard let e = v["error"] else { return "" }
        let found = [e.at("data", "message"), e["message"], e["name"], e].lazy.compactMap { $0?.string }
        return found.first { !$0.isEmpty } ?? ""
    }

    /// The counts of a finished assistant message. 1.x has `tokens.cache` as `{read, write}`.
    static func usage(_ info: JSONValue) -> Usage? {
        guard let tok = info["tokens"], tok.object != nil else { return nil }
        func n(_ v: JSONValue?) -> Int64 { Int64(v?.double ?? 0) }
        let cache = tok["cache"]
        let read = cache?.object != nil ? n(cache?["read"]) : n(cache)
        var u = Usage(
            input: n(tok["input"]), output: n(tok["output"]), cacheRead: read + n(tok["cache_read"]),
            cacheCreation: n(cache?["write"]))
        guard u.input != 0 || u.output != 0 || u.cacheRead != 0 || u.cacheCreation != 0 else { return nil }
        u.costUSD = info["cost"]?.double ?? 0
        let model = info["modelID"].stringValue
        if !model.isEmpty { u.model = model }
        return u
    }
}
