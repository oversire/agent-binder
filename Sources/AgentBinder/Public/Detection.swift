import Foundation

/// The result of a probe of one harness on this machine.
public struct Detection: Sendable, Equatable {
    /// The harness.
    public var harness: Harness
    /// The resolved binary. It is nil when the harness is not installed.
    public var path: URL?
    /// The first line of `--version`.
    public var version: String?
    /// True when the binary exists and meets the version floor.
    public var supported: Bool
    /// True when ``supported`` is true and ``auth`` is ``AuthState/ok``.
    public var ready: Bool
    /// The best-effort login state.
    public var auth: AuthState
    /// A short note from the login probe, for example an account email. It never holds a token.
    public var authDetail: String?
    /// The static capabilities of the harness.
    public var features: Features
    /// Why the harness is not supported.
    public var detail: Detail?

    /// Makes a detection.
    public init(
        harness: Harness, path: URL? = nil, version: String? = nil, supported: Bool = false, ready: Bool = false,
        auth: AuthState = .unknown, authDetail: String? = nil, features: Features = Features(), detail: Detail? = nil
    ) {
        self.harness = harness
        self.path = path
        self.version = version
        self.supported = supported
        self.ready = ready
        self.auth = auth
        self.authDetail = authDetail
        self.features = features
        self.detail = detail
    }

    /// The reason for a verdict that is not supported.
    public enum Detail: Sendable, Equatable {
        /// The binary is not installed.
        case notInstalled
        /// The installed version is below the floor of the library. The value is the floor.
        case belowFloor(String)
        /// The host app runs in the App Sandbox.
        case sandboxed
        /// The runtime has no driver for the harness.
        case noDriver
    }
}

/// The best-effort login state of a harness.
public enum AuthState: String, Sendable, Codable {
    /// The probe was not conclusive.
    case unknown
    /// A login or an API key is present.
    case ok
    /// No login is present.
    case missing
}

/// What a harness can take for one session. The table is static for each harness.
public struct Features: Sendable, Equatable {
    /// How MCP servers reach the harness.
    public var mcpInject: MCPCapability
    /// How skills reach the harness.
    public var skillsInject: SkillSupport
    /// The harness takes instructions for one session.
    public var instructions: Bool
    /// The harness takes image attachments.
    public var attachments: Bool
    /// The harness can resume a session.
    public var resume: Bool
    /// The harness asks before a tool runs, and the library can answer.
    public var permissions: Bool
    /// The harness can send file reads and writes to ``StartRequest/fileSystem``.
    public var fileSystem: Bool
    /// ``Runtime/models(_:query:)`` can list the models.
    public var models: Bool
    /// A live session conforms to ``ModelSettable``.
    public var setModel: Bool
    /// A live session conforms to ``Steerable``, and the vendor takes input during a turn.
    public var steer: Bool

    /// Makes a feature table.
    public init(
        mcpInject: MCPCapability = .none, skillsInject: SkillSupport = .none, instructions: Bool = false,
        attachments: Bool = false, resume: Bool = false, permissions: Bool = false, fileSystem: Bool = false,
        models: Bool = false, setModel: Bool = false, steer: Bool = false
    ) {
        self.mcpInject = mcpInject
        self.skillsInject = skillsInject
        self.instructions = instructions
        self.attachments = attachments
        self.resume = resume
        self.permissions = permissions
        self.fileSystem = fileSystem
        self.models = models
        self.setModel = setModel
        self.steer = steer
    }
}
