import Foundation

extension Limits {
    /// Maps an `account/rateLimits/read` reply or an `account/rateLimits/updated` body.
    ///
    /// The window key comes from the length, because the primary window is not always the 5-hour
    /// window. It is nil when there are no windows, no rejection and no plan.
    init?(codex body: JSONValue?) {
        guard let body, body.object != nil else { return nil }
        var snaps: [JSONValue] = []
        if let s = body["rateLimits"], s.object != nil { snaps.append(s) }
        let byID = body["rateLimitsByLimitId"]?.object ?? [:]
        for id in byID.keys.sorted() {
            guard var s = byID[id]?.object else { continue }
            if (s["limitId"]?.string ?? "").isEmpty { s["limitId"] = .string(id) }
            snaps.append(.object(s))
        }
        var plan: String?
        var rejected = false
        var windows: [LimitWindow] = []
        var seen = Set<String>()
        for s in snaps {
            if plan == nil, let p = s["planType"]?.string, !p.isEmpty { plan = p }
            if !(s["rateLimitReachedType"]?.string ?? "").isEmpty { rejected = true }
            let id = s["limitId"].stringValue
            let scope = id == "codex" || id.isEmpty ? nil : id
            for w in [s["primary"], s["secondary"]] {
                guard let w, w.object != nil else { continue }
                let minutes = Int(w["windowDurationMins"]?.int ?? 0)
                var lw = LimitWindow(
                    key: WindowKey(minutes: minutes), scope: scope, minutes: minutes,
                    usedPercent: w["usedPercent"]?.double ?? 0)
                if let at = w["resetsAt"]?.int, at > 0 { lw.resetsAt = Date(timeIntervalSince1970: TimeInterval(at)) }
                guard seen.insert("\(lw.key.rawValue)|\(scope ?? "")|\(minutes)").inserted else { continue }
                windows.append(lw)
            }
        }
        if windows.isEmpty && !rejected && plan == nil { return nil }
        self.init(plan: plan, rejected: rejected, windows: windows)
    }
}
