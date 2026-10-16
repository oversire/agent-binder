import AgentBinder
import Foundation

extension AnthropicModel {
    static let efforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    /// The JSON body of one Messages call.
    func body(_ r: ModelRequest) throws -> JSONValue {
        var o: [String: JSONValue] = [
            "model": .string(name),
            "max_tokens": .int(Int64(r.maxOutputTokens > 0 ? r.maxOutputTokens : Self.defaultMaxTokens)),
            "stream": true,
            "messages": .array(try Self.messages(r.messages)),
        ]
        if !r.system.isEmpty { o["system"] = [["type": "text", "text": .string(r.system)]] }
        if options.promptCaching { o["cache_control"] = ["type": "ephemeral"] }
        var tools = try r.tools.map { try tool($0) }
        if options.webSearch { tools.append(["type": "web_search_20260209", "name": "web_search", "max_uses": 3]) }
        if !tools.isEmpty {
            o["tools"] = .array(tools)
            o["tool_choice"] = try Self.choice(r.toolChoice)
        }
        if !r.effort.isEmpty {
            guard Self.efforts.contains(r.effort) else {
                throw NativeError.config("anthropic: unknown effort \(JSONValue.quote(r.effort))")
            }
            // Changed on purpose: the current models take an effort level, not a thinking budget.
            o["thinking"] = ["type": "adaptive", "display": "summarized"]
            o["output_config"] = ["effort": .string(r.effort)]
        }
        if sendsFallback { o["fallbacks"] = "default" }
        return .object(o)
    }

    func tool(_ s: ToolSpec) throws -> JSONValue {
        var t: [String: JSONValue] = ["name": .string(s.name), "input_schema": try Self.schema(s.inputSchema)]
        if !s.description.isEmpty { t["description"] = .string(s.description) }
        // The input streams as the model writes it. The tools check the input themselves.
        if firstParty { t["eager_input_streaming"] = true }
        return .object(t)
    }

    /// The input schema: always an object, with the string entries of `required`.
    static func schema(_ data: Data?) throws -> JSONValue {
        guard let data, !data.isEmpty else { return ["type": "object", "properties": [:]] }
        guard var o = JSONValue.parse(data)?.object else {
            throw NativeError.config("anthropic: tool input schema: not a JSON object")
        }
        o["type"] = "object"
        if o["properties"]?.object == nil { o["properties"] = [:] }
        if let req = o["required"] {
            o["required"] = .array((req.array ?? []).filter { $0.string != nil })
        }
        return .object(o)
    }

    static func choice(_ c: ToolChoice) throws -> JSONValue {
        switch c {
        case .auto: return ["type": "auto"]
        case .none: return ["type": "none"]
        case .required: return ["type": "any"]
        case .named(let n):
            guard !n.isEmpty else { throw NativeError.config("anthropic: named tool choice needs a name") }
            return ["type": "tool", "name": .string(n)]
        }
    }

    /// The messages. A tool message is a user message, and messages of the same role merge.
    static func messages(_ ms: [Message]) throws -> [JSONValue] {
        var out: [(role: String, blocks: [JSONValue])] = []
        for m in ms {
            let role = m.role == .assistant ? "assistant" : "user"
            let blocks = try m.parts.compactMap(block)
            guard !blocks.isEmpty else { continue }
            // Fixed on purpose: the results of parallel calls go in one user message.
            if out.last?.role == role {
                out[out.count - 1].blocks += blocks
            } else {
                out.append((role, blocks))
            }
        }
        return out.map { ["role": .string($0.role), "content": .array($0.blocks)] }
    }

    static func block(_ p: Part) throws -> JSONValue? {
        switch p {
        case .text(let t):
            return t.isEmpty ? nil : ["type": "text", "text": .string(t)]
        case .reasoning(let r):
            // A block with no signature cannot go back: it came from another provider or a declined attempt.
            guard let s = r.signature, !s.isEmpty else { return nil }
            return ["type": "thinking", "thinking": .string(r.text), "signature": .string(s)]
        case .toolCall(let c):
            let input = c.input.flatMap { JSONValue.parse($0) }.flatMap { $0.object != nil ? $0 : nil } ?? [:]
            return ["type": "tool_use", "id": .string(c.id), "name": .string(c.name), "input": input]
        case .toolResult(let r):
            var o: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(r.callID)]
            let content = try r.content.compactMap(block).filter {
                ["text", "image", "document"].contains($0["type"]?.string ?? "")
            }
            if !content.isEmpty { o["content"] = .array(content) }
            if r.isError { o["is_error"] = true }
            return .object(o)
        case .file(let f):
            let image = f.mediaType.hasPrefix("image/")
            let source: JSONValue
            if let d = f.data, !d.isEmpty {
                source = [
                    "type": "base64", "media_type": .string(image ? f.mediaType : "application/pdf"),
                    "data": .string(d.base64EncodedString()),
                ]
            } else if let u = f.url, !u.isEmpty {
                source = ["type": "url", "url": .string(u)]
            } else {
                throw NativeError.config("anthropic: file part has neither data nor url")
            }
            return ["type": image ? "image" : "document", "source": source]
        }
    }
}
