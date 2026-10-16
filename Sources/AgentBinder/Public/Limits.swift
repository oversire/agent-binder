import Foundation

/// The plan limit state of the account behind a session.
public struct Limits: Sendable, Equatable {
    /// The vendor plan name, for example `"plus"`.
    public var plan: String?
    /// True when the harness refused the last request on a limit.
    public var rejected: Bool
    /// The limit windows.
    public var windows: [LimitWindow]

    /// Makes a limit state.
    public init(plan: String? = nil, rejected: Bool = false, windows: [LimitWindow] = []) {
        self.plan = plan
        self.rejected = rejected
        self.windows = windows
    }
}

/// The use of one plan limit window.
public struct LimitWindow: Sendable, Equatable {
    /// The window class.
    public var key: WindowKey
    /// A narrower scope of the window, for example `"opus"` or a Codex limit id.
    public var scope: String?
    /// The window length in minutes. It is 0 when it is not known.
    public var minutes: Int
    /// The used part of the window, 0 to 100.
    public var usedPercent: Double
    /// The time the window resets, when it is known.
    public var resetsAt: Date?

    /// Makes a limit window.
    public init(key: WindowKey, scope: String? = nil, minutes: Int = 0, usedPercent: Double = 0, resetsAt: Date? = nil)
    {
        self.key = key
        self.scope = scope
        self.minutes = minutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// The class of a limit window, from its length.
public enum WindowKey: String, Sendable, Codable {
    /// A 300-minute window.
    case fiveHour = "five_hour"
    /// A 1440-minute window.
    case daily
    /// A 10080-minute window.
    case weekly
    /// A 43200-minute window.
    case monthly
    /// A window of another length.
    case custom

    /// Maps a window length in minutes to its class.
    public init(minutes: Int) {
        switch minutes {
        case 300: self = .fiveHour
        case 1440: self = .daily
        case 10080: self = .weekly
        case 43200: self = .monthly
        default: self = .custom
        }
    }
}
