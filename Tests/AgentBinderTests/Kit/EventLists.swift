@testable import AgentBinder

/// The payloads of one event kind.
extension [Event] {
    var tools: [ToolEvent] {
        compactMap {
            if case .tool(let t) = $0.kind { return t }
            return nil
        }
    }

    var permissions: [PermissionRequest] {
        compactMap {
            if case .permission(let p) = $0.kind { return p }
            return nil
        }
    }

    var results: [TurnResult] {
        compactMap {
            if case .result(let r) = $0.kind { return r }
            return nil
        }
    }

    var errors: [WireError] {
        compactMap {
            if case .error(let e) = $0.kind { return e }
            return nil
        }
    }

    var limits: [Limits] {
        compactMap {
            if case .limits(let l) = $0.kind { return l }
            return nil
        }
    }

    func count(_ name: String) -> Int { filter { $0.kind.name == name }.count }
}
