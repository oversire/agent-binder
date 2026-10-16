import Foundation

/// The mapping of the Codex `item/*` and token-usage notifications.
enum CodexItems {
    /// The events of `item/started`, `item/updated` and `item/completed`.
    static func events(method: String, params: JSONValue?) -> [Event] {
        guard let item = params?["item"], item.object != nil else { return [] }
        let completed = method == "item/completed"
        let id = item["id"].stringValue
        var status: ToolStatus = completed ? .completed : .started
        switch item["type"].stringValue {
        case "agentMessage":
            let t = item["text"].stringValue
            return t.isEmpty ? [] : [Event(.assistant(text: t, delta: !completed))]
        case "commandExecution":
            // Any method can carry the exit code, so a started item can be failed.
            if let code = item["exitCode"]?.double, code != 0 { status = .failed }
            let output = [item["aggregatedOutput"].stringValue, item["output"].stringValue].first { !$0.isEmpty } ?? ""
            return [
                Event(
                    .tool(
                        ToolEvent(
                            id: id, name: "command", kind: .exec, input: item["command"].stringValue, output: output,
                            status: status)))
            ]
        case "fileChange":
            let paths = (item["changes"]?.array ?? []).compactMap { c -> String? in
                [c["path"].stringValue, c["file"].stringValue].first { !$0.isEmpty }
            }
            return [Event(.tool(ToolEvent(id: id, name: "fileChange", kind: .edit, status: status, paths: paths)))]
        case "mcpToolCall":
            return [
                Event(
                    .tool(
                        ToolEvent(
                            id: id, name: "mcp:" + item["tool"].stringValue, kind: .mcp,
                            input: item["arguments"]?.jsonString ?? "", status: status)))
            ]
        case "webSearch":
            return [Event(.tool(ToolEvent(id: id, name: "web_search", kind: .search, status: status)))]
        default:
            return []
        }
    }

    /// The `last` and `total` counts of a token-usage notification. With neither key, the body is the total.
    static func tokenUsage(_ params: JSONValue?) -> (last: Usage?, total: Usage?) {
        guard let params else { return (nil, nil) }
        let tu = params["tokenUsage"].flatMap { $0.object == nil ? nil : $0 } ?? params
        let last = tu["last"].flatMap { $0.object == nil ? nil : $0 }
        let total = tu["total"].flatMap { $0.object == nil ? nil : $0 }
        if last == nil && total == nil { return (nil, breakdown(tu)) }
        return (last.flatMap(breakdown), total.flatMap(breakdown))
    }

    // Both spellings count.
    private static func breakdown(_ m: JSONValue) -> Usage? {
        func n(_ a: String, _ b: String) -> Int64 { Int64((m[a]?.double ?? 0) + (m[b]?.double ?? 0)) }
        let u = Usage(
            input: n("inputTokens", "input_tokens"), output: n("outputTokens", "output_tokens"),
            cacheRead: n("cachedInputTokens", "cached_input_tokens"),
            cacheCreation: n("cacheWriteInputTokens", "cache_write_input_tokens"))
        return u == Usage() ? nil : u
    }
}

extension Usage {
    /// The counts of `self` less the counts of `base`, each at least 0.
    func minus(_ base: Usage) -> Usage {
        Usage(
            input: max(input - base.input, 0), output: max(output - base.output, 0),
            cacheRead: max(cacheRead - base.cacheRead, 0), cacheCreation: max(cacheCreation - base.cacheCreation, 0))
    }
}
