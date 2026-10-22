import AgentBinder
import Foundation

/// The setup of a ``NativeDriver``.
public struct NativeConfig: Sendable {
    /// The default number of model calls in one turn.
    public static let defaultMaxTurns = 20

    /// Makes the model of a session from the credentials and `StartRequest.model`.
    public var newModel: @Sendable (Credentials, String?) throws -> any Model
    /// Gives the credentials when `StartRequest.credentials` is nil. It runs on each open.
    public var credentials: (@Sendable () async throws -> Credentials)?
    /// Tool sets that all sessions share. The driver never closes them.
    public var toolSets: [any ToolSet]
    /// Makes one tool set for each session. The session closes it.
    public var toolSetFactories: [@Sendable () async throws -> any ToolSet]
    /// Makes the tool set of one server of `StartRequest.mcpServers`, with the child environment of the
    /// runtime. The session closes it. Set it to `MCPToolSet.factory` of `AgentBinderMCP`. Nil fails a
    /// request with MCP servers with ``NativeError/mcpUnavailable``.
    public var mcpFactory: (@Sendable (MCPServer, [String: String]) async throws -> any ToolSet)?
    /// Adds ``FileTools`` with the root at `StartRequest.workingDirectory`.
    public var builtinTools: Bool
    /// The size limit of a file for ``FileTools``. Zero uses 10 MiB.
    public var maxFileBytes: Int64
    /// Keeps the history of each session. Nil keeps no history, and a resume starts empty.
    public var store: (any MessageStore)?
    /// Makes a long history shorter. It needs ``contextTokens``.
    public var compactor: (any Compactor)?
    /// The context size of the model in tokens. The compactor runs at 60 % of it.
    public var contextTokens: Int
    /// The limit of model calls in one turn. Zero uses ``defaultMaxTurns``.
    public var maxTurns: Int
    /// The output token limit of one model call. Zero uses the provider default.
    public var maxOutputTokens: Int
    /// Runs before each model call with the session id. A throw fails the turn.
    public var beforeCall: (@Sendable (String) async throws -> Void)?
    /// Runs after each model call with the session id and the counters of the call.
    public var afterCall: (@Sendable (String, ModelUsage) async -> Void)?
    /// Decides tool calls. Nil applies `StartRequest.permissions` and asks with permission events.
    public var approver: (any Approver)?

    /// Makes a config.
    public init(
        newModel: @escaping @Sendable (Credentials, String?) throws -> any Model,
        credentials: (@Sendable () async throws -> Credentials)? = nil,
        toolSets: [any ToolSet] = [],
        toolSetFactories: [@Sendable () async throws -> any ToolSet] = [],
        mcpFactory: (@Sendable (MCPServer, [String: String]) async throws -> any ToolSet)? = nil,
        builtinTools: Bool = false,
        maxFileBytes: Int64 = 0,
        store: (any MessageStore)? = nil,
        compactor: (any Compactor)? = nil,
        contextTokens: Int = 0,
        maxTurns: Int = 0,
        maxOutputTokens: Int = 0,
        beforeCall: (@Sendable (String) async throws -> Void)? = nil,
        afterCall: (@Sendable (String, ModelUsage) async -> Void)? = nil,
        approver: (any Approver)? = nil
    ) {
        self.newModel = newModel
        self.credentials = credentials
        self.toolSets = toolSets
        self.toolSetFactories = toolSetFactories
        self.mcpFactory = mcpFactory
        self.builtinTools = builtinTools
        self.maxFileBytes = maxFileBytes
        self.store = store
        self.compactor = compactor
        self.contextTokens = contextTokens
        self.maxTurns = maxTurns
        self.maxOutputTokens = maxOutputTokens
        self.beforeCall = beforeCall
        self.afterCall = afterCall
        self.approver = approver
    }
}
