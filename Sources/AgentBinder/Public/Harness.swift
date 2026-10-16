/// One vendor coding agent.
///
/// `Harness` is a struct, not an enum, so a consumer can register a custom driver under a new name
/// with ``Runtime/setDriver(_:for:)``.
public struct Harness: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// The stable name, for example `"claude"`.
    public let rawValue: String

    /// Makes a harness from its name.
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Makes a harness from its name.
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Claude Code over stream-json.
    public static let claude = Harness("claude")
    /// Codex over the app-server JSON-RPC protocol.
    public static let codex = Harness("codex")
    /// OpenCode 1.x over its HTTP server.
    public static let opencode = Harness("opencode")
    /// OpenCode 2.x over its HTTP server.
    public static let opencode2 = Harness("opencode2")
    /// pi over its RPC mode.
    public static let pi = Harness("pi")
    /// GitHub Copilot CLI over ACP.
    public static let copilot = Harness("copilot")
    /// Cursor Agent over ACP.
    public static let cursor = Harness("cursor")
    /// Gemini CLI over ACP.
    public static let gemini = Harness("gemini")
    /// The scripted test harness.
    public static let fake = Harness("fake")
    /// The in-process harness of `AgentBinderNative`.
    public static let native = Harness("native")

    /// Every harness that the library knows, in a stable order.
    public static var allBuiltIn: [Harness] {
        [.claude, .codex, .opencode, .opencode2, .pi, .copilot, .cursor, .gemini, .fake, .native]
    }

    /// The executable name on `PATH`.
    public var binaryName: String {
        switch self {
        case .cursor: return "cursor-agent"
        default: return rawValue
        }
    }

    /// The name of the harness.
    public var description: String { rawValue }

    /// Decodes the harness from a plain string.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes the harness as a plain string.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
