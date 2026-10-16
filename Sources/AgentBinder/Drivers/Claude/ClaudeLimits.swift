import Foundation

extension Limits {
    /// The windows of a Claude `rate_limit_info` object, sorted by name. It is nil when there are no
    /// windows and the request was not rejected.
    init?(claude info: JSONValue, rejected: Bool) {
        var windows: [LimitWindow] = []
        let all = info["unifiedWindows"]?.object ?? [:]
        for name in all.keys.sorted() {
            guard let w = all[name], let u = w["utilization"]?.double else { continue }
            var lw = LimitWindow(claudeName: name)
            lw.usedPercent = u * 100
            if let at = w["resetsAt"]?.double, at > 0 { lw.resetsAt = Date(timeIntervalSince1970: at.rounded(.down)) }
            windows.append(lw)
        }
        if windows.isEmpty && !rejected { return nil }
        self.init(rejected: rejected, windows: windows)
    }
}

extension LimitWindow {
    /// Maps a Claude window name: `five_hour`, `seven_day` and `seven_day_<scope>`. Other names are custom.
    init(claudeName name: String) {
        switch name {
        case "five_hour": self.init(key: .fiveHour, minutes: 300)
        case "seven_day": self.init(key: .weekly, minutes: 10080)
        case let n where n.hasPrefix("seven_day_"):
            self.init(key: .weekly, scope: String(n.dropFirst("seven_day_".count)), minutes: 10080)
        default: self.init(key: .custom, scope: name)
        }
    }
}
