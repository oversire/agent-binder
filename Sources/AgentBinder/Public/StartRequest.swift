import Foundation

/// The description of one session. The caller describes it, and the library builds the command.
public struct StartRequest: Sendable {
    /// The harness to run.
    public var harness: Harness
    /// The executable. Nil lets the binary resolver search for it.
    public var binary: URL?
    /// The working directory of the agent.
    public var workingDirectory: URL
    /// Values that go into the child environment. They win on conflict.
    public var environment: [String: String]
    /// An isolated config home. Nil uses the login, MCP servers and skills of the user.
    public var home: URL?
    /// A resume target, or an id for the new session where the harness accepts one.
    public var sessionID: String?
    /// The vendor model name. Nil uses the vendor default.
    public var model: String?
    /// The reasoning effort. Nil uses the vendor default.
    public var effort: Effort?
    /// The permission policy.
    public var permissions: PermissionPolicy
    /// MCP servers for the session. The servers of the user stay loaded.
    public var mcpServers: [MCPServer]
    /// Extra skills for the session.
    public var skills: [Skill]
    /// Instructions for the session.
    public var instructions: String?
    /// Provider credentials. Only the native harness reads them.
    public var credentials: Credentials?
    /// One prompt that the library writes before it closes stdin, so the child exits after the turn.
    public var oneShot: OneShot?
    /// A different time limit for the protocol handshake.
    public var handshakeTimeout: Duration?
    /// Arguments that go after the arguments of the library.
    public var extraArguments: [String]
    /// An expert override. When it is set, the library uses this command as it is and adds no flags.
    public var baseCommand: [String]?
    /// Overrides for one harness that the typed fields do not cover:
    /// `strict_mcp`, `shared_auth`, `approvalPolicy`, `sandbox`, `auth_method` and `acp_auth_method`.
    public var raw: [String: RawValue]
    /// A file that receives each frame in and out as NDJSON. The library makes it with mode 0600.
    /// It does not remove secrets from the frames.
    public var frameLog: URL?
    /// File access for an ACP agent (`fs/readTextFile`, `fs/writeTextFile`).
    public var fileSystem: (any FileSystemAccess)?
    /// Receives each stderr line of the child.
    public var onStderr: (@Sendable (Harness, String) -> Void)?

    /// Makes a request.
    public init(
        harness: Harness = .claude,
        workingDirectory: URL,
        binary: URL? = nil,
        environment: [String: String] = [:],
        home: URL? = nil,
        sessionID: String? = nil,
        model: String? = nil,
        effort: Effort? = nil,
        instructions: String? = nil,
        permissions: PermissionPolicy = PermissionPolicy(),
        mcpServers: [MCPServer] = [],
        skills: [Skill] = [],
        credentials: Credentials? = nil,
        oneShot: OneShot? = nil,
        handshakeTimeout: Duration? = nil,
        extraArguments: [String] = [],
        baseCommand: [String]? = nil,
        raw: [String: RawValue] = [:],
        frameLog: URL? = nil,
        fileSystem: (any FileSystemAccess)? = nil,
        onStderr: (@Sendable (Harness, String) -> Void)? = nil
    ) {
        self.harness = harness
        self.workingDirectory = workingDirectory
        self.binary = binary
        self.environment = environment
        self.home = home
        self.sessionID = sessionID
        self.model = model
        self.effort = effort
        self.instructions = instructions
        self.permissions = permissions
        self.mcpServers = mcpServers
        self.skills = skills
        self.credentials = credentials
        self.oneShot = oneShot
        self.handshakeTimeout = handshakeTimeout
        self.extraArguments = extraArguments
        self.baseCommand = baseCommand
        self.raw = raw
        self.frameLog = frameLog
        self.fileSystem = fileSystem
        self.onStderr = onStderr
    }

    /// Reads a boolean override from ``raw``.
    public func rawBool(_ key: String) -> Bool? {
        if case .bool(let b)? = raw[key] { return b }
        return nil
    }

    /// Reads a string override from ``raw``.
    public func rawString(_ key: String) -> String? {
        if case .string(let s)? = raw[key] { return s }
        return nil
    }
}

/// One override value in ``StartRequest/raw``.
public enum RawValue: Sendable, Equatable {
    /// A boolean.
    case bool(Bool)
    /// A string.
    case string(String)
}

/// A one-shot turn: the library writes the prompt and closes stdin.
public struct OneShot: Sendable, Equatable {
    /// The prompt text.
    public var prompt: String

    /// Makes a one-shot turn.
    public init(prompt: String) { self.prompt = prompt }
}

/// The reasoning effort of the model.
public struct Effort: RawRepresentable, Hashable, Sendable, Codable {
    /// The vendor value, for example `"high"`.
    public let rawValue: String

    /// Makes an effort from its vendor value.
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Low effort.
    public static let low = Effort(rawValue: "low")
    /// Medium effort.
    public static let medium = Effort(rawValue: "medium")
    /// High effort.
    public static let high = Effort(rawValue: "high")
    /// The most effort.
    public static let max = Effort(rawValue: "max")
}

/// File access that an ACP agent can ask for. The consumer can see or stop each write.
public protocol FileSystemAccess: Sendable {
    /// Reads a text file.
    func readTextFile(_ path: String) async throws -> String
    /// Writes a text file.
    func writeTextFile(_ path: String, content: String) async throws
}
