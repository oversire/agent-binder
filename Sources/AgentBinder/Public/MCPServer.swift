import Foundation

/// One Model Context Protocol server for a session.
public struct MCPServer: Sendable, Equatable {
    /// The server name that the agent sees.
    public var name: String
    /// How the agent reaches the server.
    public var transport: Transport

    /// Makes a server.
    public init(name: String, transport: Transport) {
        self.name = name
        self.transport = transport
    }

    /// The transport of a server.
    public enum Transport: Sendable, Equatable {
        /// A child process that speaks MCP on stdio.
        case stdio(command: String, args: [String], env: [String: String])
        /// A streamable HTTP endpoint.
        case http(url: URL, headers: [String: String])
    }

    /// A stdio server.
    public static func stdio(
        name: String, command: String, args: [String] = [], env: [String: String] = [:]
    )
        -> MCPServer
    {
        MCPServer(name: name, transport: .stdio(command: command, args: args, env: env))
    }

    /// An HTTP server.
    public static func http(name: String, url: URL, headers: [String: String] = [:]) -> MCPServer {
        MCPServer(name: name, transport: .http(url: url, headers: headers))
    }
}

/// How a harness takes MCP servers for one session.
public enum MCPCapability: String, Sendable, Codable {
    /// The harness cannot take a server.
    case none
    /// The library writes the servers into the launch flags or files.
    case flags
    /// The servers go in the session-open request.
    case session
}
