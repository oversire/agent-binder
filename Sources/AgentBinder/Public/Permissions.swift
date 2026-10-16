/// The one permission policy that each harness maps onto its own mechanism.
public struct PermissionPolicy: Sendable, Equatable {
    /// How the library answers permission requests.
    public var mode: Mode
    /// Tools that the library allows without a question in ``Mode/ask`` and ``Mode/autoEdit`` mode.
    /// A pattern can end in `*`, for example `"mcp__sling__*"`.
    public var allowTools: [String]

    /// Makes a policy.
    public init(mode: Mode = .ask, allowTools: [String] = []) {
        self.mode = mode
        self.allowTools = allowTools
    }

    /// The permission modes.
    public enum Mode: String, Sendable, Codable, CaseIterable {
        /// Each request becomes a ``Event/Kind/permission(_:)`` event. This is the default.
        case ask
        /// The library allows edits. Other requests become events.
        case autoEdit = "auto_edit"
        /// The library allows each request.
        case auto
        /// The library adds no permission-mode flag. The harness configuration of the operator decides.
        /// Requests that the harness sends become events, as in ``ask``.
        case inherit
    }

    /// The decision that the policy makes without the consumer, or nil when the request becomes an event.
    public func answer(kind: ToolKind, tool: String) -> Decision? {
        switch mode {
        case .auto: return .allow()
        case .autoEdit where kind == .edit: return .allow()
        default: break
        }
        return allows(tool) ? .allow() : nil
    }

    func allows(_ tool: String) -> Bool {
        guard !tool.isEmpty else { return false }
        return allowTools.contains { Self.match($0, tool) }
    }

    // Only a trailing star: tool names hold "__" and ":" but no path separator.
    static func match(_ pattern: String, _ tool: String) -> Bool {
        if pattern.isEmpty { return false }
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") { return tool.hasPrefix(pattern.dropLast()) }
        return pattern == tool
    }
}
