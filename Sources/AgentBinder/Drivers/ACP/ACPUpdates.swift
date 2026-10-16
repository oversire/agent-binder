import Foundation

/// The mapping of the ACP `session/update` notifications and the usage blocks.
enum ACPUpdates {
    static func events(_ update: JSONValue) -> [Event] {
        switch update["sessionUpdate"].stringValue {
        case "agent_message_chunk":
            guard update.at("content", "type")?.string == "text", let t = update.at("content", "text")?.string,
                !t.isEmpty
            else { return [] }
            return [Event(.assistant(text: t, delta: true))]
        case "agent_thought_chunk", "plan", "plan_update", "available_commands_update", "current_mode_update":
            // The thought text is dropped. The event only tells that the turn runs.
            return [Event(.status(.running, text: nil))]
        case "usage_update":
            // Quirk: the context use goes into input and the context size into output. It is not token usage.
            let u = Usage(
                input: Int64(update["used"]?.double ?? 0), output: Int64(update["size"]?.double ?? 0),
                costUSD: cost(update["cost"]))
            return u == Usage() ? [] : [Event(.usage(u))]
        case "tool_call":
            // The status field of a start is ignored.
            return [Event(.tool(tool(update, .started)))]
        case "tool_call_update":
            let status: ToolStatus =
                switch update["status"].stringValue {
                case "completed": .completed
                case "failed": .failed
                default: .started
                }
            return [Event(.tool(tool(update, status)))]
        default:
            return []
        }
    }

    private static func tool(_ u: JSONValue, _ status: ToolStatus) -> ToolEvent {
        let name = [u["title"].stringValue, u["kind"].stringValue].first { !$0.isEmpty } ?? "tool"
        let kindName = u["kind"].stringValue
        let kind = ToolClassifier.kind(for: kindName.isEmpty ? name : kindName)
        let input = u["rawInput"]?.jsonString ?? ""
        return ToolEvent(
            id: u["toolCallId"].stringValue, name: name, kind: kind, input: input, output: output(u["content"]),
            status: status, paths: ToolClassifier.paths(kind: kind, input: input))
    }

    // Nested text, plain text and diff paths.
    private static func output(_ v: JSONValue?) -> String {
        var parts: [String] = []
        for item in v?.array ?? [] where item.object != nil {
            if let t = item.at("content", "text")?.string, !t.isEmpty {
                parts.append(t)
                continue
            }
            if let t = item["text"]?.string, !t.isEmpty { parts.append(t) }
            if let p = item["path"]?.string, !p.isEmpty { parts.append(p) }
        }
        return parts.joined(separator: "\n")
    }

    /// The usage of a `session/prompt` result. Both spellings count.
    static func usage(_ m: JSONValue?) -> Usage? {
        guard let m, m.object != nil else { return nil }
        func n(_ a: String, _ b: String) -> Int64 { Int64((m[a]?.double ?? 0) + (m[b]?.double ?? 0)) }
        let u = Usage(
            input: n("inputTokens", "input_tokens"), output: n("outputTokens", "output_tokens"),
            cacheRead: n("cachedReadTokens", "cached_read_tokens"),
            cacheCreation: n("cachedWriteTokens", "cached_write_tokens"), costUSD: cost(m["cost"]))
        return u == Usage() ? nil : u
    }

    private static func cost(_ v: JSONValue?) -> Double {
        if let v, v.object != nil { return v["amount"]?.double ?? 0 }
        return v?.double ?? 0
    }
}
