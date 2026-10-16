import AgentBinder
import Foundation

extension OpenAIModel {
    /// The JSON body of one Chat Completions call.
    func body(_ r: ModelRequest) throws -> JSONValue {
        var msgs: [JSONValue] = []
        if !r.system.isEmpty { msgs.append(["role": "system", "content": .string(r.system)]) }
        for m in r.messages { msgs += Self.messages(m) }
        var o: [String: JSONValue] = [
            "model": .string(name),
            "stream": true,
            // Fixed on purpose: without it, OpenAI reports no usage in a stream.
            "stream_options": ["include_usage": true],
            "messages": .array(msgs),
        ]
        if !r.tools.isEmpty {
            o["tools"] = .array(r.tools.map(Self.tool))
            // Fixed on purpose: OpenAI refuses tool_choice without tools.
            o["tool_choice"] = try Self.choice(r.toolChoice)
        }
        if r.maxOutputTokens > 0 {
            o[firstParty ? "max_completion_tokens" : "max_tokens"] = .int(Int64(r.maxOutputTokens))
        }
        switch r.effort {
        case "low", "medium", "high": o["reasoning_effort"] = .string(r.effort)
        case "max": o["reasoning_effort"] = "high"
        default: break
        }
        return .object(o)
    }

    static func tool(_ s: ToolSpec) -> JSONValue {
        var f: [String: JSONValue] = ["name": .string(s.name), "description": .string(s.description)]
        if let d = s.inputSchema, let p = JSONValue.parse(d), p.object != nil {
            f["parameters"] = p
        } else if s.inputSchema == nil {
            f["parameters"] = ["type": "object", "properties": [:]]
        }
        return ["type": "function", "function": .object(f)]
    }

    static func choice(_ c: ToolChoice) throws -> JSONValue {
        switch c {
        case .auto: return "auto"
        case .none: return "none"
        case .required: return "required"
        case .named(let n):
            guard !n.isEmpty else { throw NativeError.config("openai: named tool choice needs a name") }
            return ["type": "function", "function": ["name": .string(n)]]
        }
    }

    /// The wire messages of one message. A tool message gives one message for each result.
    static func messages(_ m: Message) -> [JSONValue] {
        let text = m.parts.compactMap { p -> String? in
            if case .text(let t) = p, !t.isEmpty { return t }
            return nil
        }.joined(separator: "\n")
        switch m.role {
        case .user:
            let images = m.parts.compactMap { p -> JSONValue? in
                guard case .file(let f) = p, f.mediaType.hasPrefix("image/") else { return nil }
                if let d = f.data, !d.isEmpty {
                    return [
                        "type": "image_url",
                        "image_url": ["url": .string("data:\(f.mediaType);base64,\(d.base64EncodedString())")],
                    ]
                }
                guard let u = f.url, !u.isEmpty else { return nil }
                return ["type": "image_url", "image_url": ["url": .string(u)]]
            }
            if images.isEmpty { return text.isEmpty ? [] : [["role": "user", "content": .string(text)]] }
            let content = images + (text.isEmpty ? [] : [["type": "text", "text": .string(text)]])
            return [["role": "user", "content": .array(content)]]
        case .assistant:
            var o: [String: JSONValue] = ["role": "assistant"]
            if !text.isEmpty { o["content"] = .string(text) }
            let calls = m.parts.compactMap { p -> JSONValue? in
                guard case .toolCall(let c) = p else { return nil }
                // Fixed on purpose: an empty input is "{}", not "".
                let args = c.input.map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
                return [
                    "id": .string(c.id), "type": "function",
                    "function": ["name": .string(c.name), "arguments": .string(args)],
                ]
            }
            if !calls.isEmpty { o["tool_calls"] = .array(calls) }
            return o.count == 1 ? [] : [.object(o)]
        case .tool:
            return m.parts.compactMap { p -> JSONValue? in
                guard case .toolResult(let r) = p else { return nil }
                let t = r.content.compactMap { c -> String? in
                    if case .text(let s) = c { return s }
                    return nil
                }.joined(separator: "\n")
                return ["role": "tool", "tool_call_id": .string(r.callID), "content": .string(t)]
            }
        }
    }
}
