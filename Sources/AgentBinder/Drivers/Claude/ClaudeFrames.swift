import Foundation

/// The frame shapes of the Claude stream-json wire.
enum ClaudeFrames {
    /// A user frame. A prompt and a steer use the same frame.
    static func user(_ p: Prompt) throws -> JSONValue {
        .object([
            "type": "user", "session_id": "", "parent_tool_use_id": .null,
            "message": .object(["role": "user", "content": try content(p)]),
        ])
    }

    /// The prompt text, or a block list when the prompt has attachments: images first, the text last.
    static func content(_ p: Prompt) throws -> JSONValue {
        guard !p.attachments.isEmpty else { return .string(p.text) }
        var blocks: [JSONValue] = []
        for a in PromptAttachment.sorted(p.attachments) {
            let l = try a.load()
            if l.isImage {
                blocks.append(
                    .object([
                        "type": "image",
                        "source": .object(["type": "base64", "media_type": .string(l.mime), "data": .string(l.base64)]),
                    ]))
            } else {
                blocks.append(.object(["type": "text", "text": .string(String(decoding: l.data, as: UTF8.self))]))
            }
        }
        blocks.append(.object(["type": "text", "text": .string(p.text)]))
        return .array(blocks)
    }

    static func controlRequest(id: String, _ request: [String: JSONValue]) -> JSONValue {
        .object(["type": "control_request", "request_id": .string(id), "request": .object(request)])
    }

    /// The answer to a `can_use_tool` request. An allow without an input echoes the original input.
    static func decision(id: String, _ d: Decision, original: JSONValue?) -> JSONValue {
        var r: [String: JSONValue]
        if d.allow {
            let updated = d.updatedInput.flatMap { JSONValue.parse($0) } ?? original ?? .object([:])
            r = ["behavior": "allow", "updatedInput": updated]
        } else {
            r = ["behavior": "deny"]
            if let m = d.message, !m.isEmpty { r["message"] = .string(m) }
        }
        return .object([
            "type": "control_response",
            "response": .object(["subtype": "success", "request_id": .string(id), "response": .object(r)]),
        ])
    }

    /// The refusal of a control request that the library does not handle, for example a hook callback.
    static func unsupported(id: String, subtype: String) -> JSONValue {
        .object([
            "type": "control_response",
            "response": .object([
                "subtype": "error", "request_id": .string(id),
                "error": .string("agentbinder: unsupported control request subtype \(subtype)"),
            ]),
        ])
    }

    /// The token counts of a message. All zero gives nil.
    static func usage(_ v: JSONValue?) -> Usage? {
        guard let v, case .object = v else { return nil }
        func n(_ k: String) -> Int64 { Int64(v[k]?.double ?? 0) }
        var u = Usage(
            input: n("input_tokens"), output: n("output_tokens"), cacheRead: n("cache_read_input_tokens"),
            cacheCreation: n("cache_creation_input_tokens"))
        if u.input == 0 && u.output == 0 && u.cacheRead == 0 && u.cacheCreation == 0 { return nil }
        u.model = v["model"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return u
    }

    /// The text of a tool result: a string as it is, or the text fields of a block list.
    static func flatten(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s): return s
        case .array(let items):
            return items.compactMap { $0["text"]?.string }.filter { !$0.isEmpty }.joined(separator: "\n")
        default: return ""
        }
    }

    /// The text of a result frame. Success results get text too.
    static func resultText(_ m: JSONValue) -> String {
        var errors: [String] = []
        switch m["errors"] {
        case .array(let a): errors = a.compactMap(\.string).filter { !$0.isEmpty }
        case .string(let s) where !s.isEmpty: errors = [s]
        default: break
        }
        let subtype = m["subtype"]?.string ?? ""
        let status = Int(m["api_error_status"]?.double ?? 0)
        let candidates = [
            errors.joined(separator: "; "),
            (m["result"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            subtype == "success" ? "" : subtype,
            status > 0 ? "API error (HTTP \(status))" : "",
        ]
        return candidates.first { !$0.isEmpty } ?? "unknown error"
    }

    /// The models of an `initialize` reply. An empty list gives nil.
    static func models(_ res: JSONValue?) -> [ModelInfo]? {
        let list = (res?["models"]?.array ?? []).compactMap { m -> ModelInfo? in
            guard let id = m["value"]?.string, !id.isEmpty else { return nil }
            return ModelInfo(
                id: id, name: m["displayName"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                description: m["description"]?.string.flatMap { $0.isEmpty ? nil : $0 }, isDefault: id == "default")
        }
        return list.isEmpty ? nil : list
    }

    /// The input of a tool block or a permission request as JSON text. A missing input is `{}`.
    static func input(_ v: JSONValue?) -> String { v?.jsonString ?? "{}" }
}
