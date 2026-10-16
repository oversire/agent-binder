import Foundation

@testable import AgentBinder

extension Event {
    /// The event as stable JSON for golden files. It has no time and no raw frame.
    var snapshot: JSONValue {
        var o: [String: JSONValue] = ["kind": .string(kind.name)]
        if turn != 0 { o["turn"] = .int(Int64(turn)) }
        if let s = sessionID { o["session_id"] = .string(s) }
        for (k, v) in kind.fields { o[k] = v }
        return .object(o)
    }
}

extension Event.Kind {
    fileprivate var fields: [String: JSONValue] {
        switch self {
        case .initialized: return [:]
        case .assistant(let t, let d), .thought(let t, let d): return ["text": .string(t), "delta": .bool(d)]
        case .user(let t): return ["text": .string(t)]
        case .tool(let t):
            var o: [String: JSONValue] = [
                "id": .string(t.id), "name": .string(t.name), "tool_kind": .string(t.kind.rawValue),
                "status": .string(t.status.rawValue),
            ]
            if !t.input.isEmpty { o["input"] = .string(t.input) }
            if !t.output.isEmpty { o["output"] = .string(t.output) }
            if !t.paths.isEmpty { o["paths"] = .array(t.paths.map(JSONValue.string)) }
            if let c = t.exitCode { o["exit_code"] = .int(Int64(c)) }
            return o
        case .permission(let p):
            var o: [String: JSONValue] = [
                "id": .string(p.id), "tool": .string(p.tool), "tool_kind": .string(p.kind.rawValue),
            ]
            if !p.question.isEmpty { o["question"] = .string(p.question) }
            if !p.input.isEmpty { o["input"] = .string(p.input) }
            if !p.options.isEmpty { o["options"] = .array(p.options.map(JSONValue.string)) }
            if let id = p.toolUseID { o["tool_use_id"] = .string(id) }
            return o
        case .result(let r):
            var o: [String: JSONValue] = [
                "subtype": .string(r.subtype), "is_error": .bool(r.isError), "text": .string(r.text),
                "usage": r.usage.snapshot,
            ]
            if let s = r.sessionID { o["result_session_id"] = .string(s) }
            if let e = r.endReason { o["end_reason"] = .string(e.rawValue) }
            if let c = r.code { o["code"] = .string(c) }
            return o
        case .error(let e):
            var o: [String: JSONValue] = ["message": .string(e.message), "code": .string(e.code)]
            if let r = e.endReason { o["end_reason"] = .string(r.rawValue) }
            if let t = e.text { o["text"] = .string(t) }
            return o
        case .usage(let u): return ["usage": u.snapshot]
        case .status(let s, let t):
            var o: [String: JSONValue] = ["status": .string(s.rawValue)]
            if let t { o["text"] = .string(t) }
            return o
        case .limits(let l):
            var o: [String: JSONValue] = [
                "windows": .array(
                    l.windows.map { w in
                        var o: [String: JSONValue] = [
                            "key": .string(w.key.rawValue), "minutes": .int(Int64(w.minutes)),
                            "used_percent": .double(w.usedPercent),
                        ]
                        if let s = w.scope { o["scope"] = .string(s) }
                        if let r = w.resetsAt { o["resets_at"] = .double(r.timeIntervalSince1970) }
                        return .object(o)
                    })
            ]
            if let p = l.plan { o["plan"] = .string(p) }
            if l.rejected { o["rejected"] = .bool(true) }
            return o
        case .exit(let c, let e, let ec):
            var o: [String: JSONValue] = [:]
            if let c { o["code"] = .int(Int64(c)) }
            if let e { o["error"] = .string(e) }
            if let ec { o["error_code"] = .string(ec) }
            return o
        }
    }
}

extension Usage {
    fileprivate var snapshot: JSONValue {
        var o: [String: JSONValue] = [
            "input": .int(input), "output": .int(output), "cache_read": .int(cacheRead),
            "cache_creation": .int(cacheCreation), "cost_usd": .double(costUSD),
        ]
        if let m = model { o["model"] = .string(m) }
        return .object(o)
    }
}
