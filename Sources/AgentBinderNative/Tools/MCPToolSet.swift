import AgentBinder
import Foundation
import Logging
import MCP

/// The tools of one MCP server. Each tool is `mcp__<server>__<tool>`, and each call needs approval.
///
/// It is the only file that imports the MCP SDK.
public final class MCPToolSet: ToolSet {
    static let maxPages = 100

    /// The server name.
    public let name: String
    private let client: Client
    private let child: ChildProcess?

    init(name: String, client: Client, child: ChildProcess? = nil) {
        self.name = name
        self.client = client
        self.child = child
    }

    /// Connects to a server. A stdio server gets `environment` with the server values on top.
    public static func connect(_ server: MCPServer, environment: [String: String]) async throws -> MCPToolSet {
        let client = Client(name: "agentbinder", version: "native")
        do {
            switch server.transport {
            case .stdio(let command, let args, let env):
                var full = environment
                for (k, v) in env { full[k] = v }
                let child = try ChildProcess.spawn(
                    SpawnOptions(
                        executable: try Self.executable(command, path: full["PATH"]), arguments: args, environment: full
                    ))
                do {
                    try await client.connect(transport: ChildTransport(child))
                } catch {
                    await child.killTree()
                    throw error
                }
                return MCPToolSet(name: server.name, client: client, child: child)
            case .http(let url, let headers):
                // Fixed on purpose: the headers go on each request.
                let t = HTTPClientTransport(
                    endpoint: url, configuration: .ephemeral, streaming: true,
                    requestModifier: { r in
                        var r = r
                        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
                        return r
                    })
                try await client.connect(transport: t)
                return MCPToolSet(name: server.name, client: client)
            }
        } catch let e as NativeError {
            throw e
        } catch {
            throw NativeError.config("native: mcp server \(server.name) connect: \(error)")
        }
    }

    static func executable(_ command: String, path: String?) throws -> URL {
        if command.contains("/") { return URL(fileURLWithPath: command) }
        for dir in (path ?? "").split(separator: ":") {
            let url = URL(fileURLWithPath: String(dir)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw NativeError.config("native: mcp command \(JSONValue.quote(command)) not found")
    }

    /// The tools of the server, from each page of `tools/list`.
    public func tools() async throws -> [any Tool] {
        var out: [any Tool] = []
        var cursor: String?
        var taken = Set<String>()
        // Fixed on purpose: the list follows `nextCursor`.
        for _ in 0..<Self.maxPages {
            let page = try await client.listTools(cursor: cursor)
            for t in page.tools {
                let tool = MCPTool(server: name, tool: t, client: client, taken: taken)
                taken.insert(tool.spec.name)
                out.append(tool)
            }
            guard let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        return out
    }

    /// Closes the client. A stdio server child ends.
    public func close() async {
        await client.disconnect()
        if let child { await child.gracefulClose(stageTimeout: .seconds(2)) }
    }

    /// A provider-safe name: `mcp__<server>__<tool>` with only `[a-zA-Z0-9_-]`, at most 64 characters.
    static func toolName(server: String, tool: String) -> String {
        let raw = "mcp__\(server)__\(tool)"
        let clean = String(
            raw.unicodeScalars.map { c -> Character in
                c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "_" || c == "-") ? Character(c) : "_"
            })
        return String(clean.prefix(64))
    }
}

/// One tool on an MCP server. The call uses the real tool name.
struct MCPTool: Tool {
    let spec: ToolSpec
    let toolName: String
    let client: Client

    init(server: String, tool t: MCP.Tool, client: Client, taken: Set<String>) {
        var name = MCPToolSet.toolName(server: server, tool: t.name)
        var n = 2
        while taken.contains(name) {
            let suffix = "_\(n)"
            name = String(MCPToolSet.toolName(server: server, tool: t.name).prefix(64 - suffix.count)) + suffix
            n += 1
        }
        let a = t.annotations
        spec = ToolSpec(
            name: name, title: t.title ?? a.title ?? "", description: t.description ?? "",
            inputSchema: try? JSONEncoder().encode(t.inputSchema),
            annotations: ToolAnnotations(
                readOnly: a.readOnlyHint ?? false, destructive: a.destructiveHint == true,
                idempotent: a.idempotentHint ?? false, openWorld: a.openWorldHint == true, kind: .mcp))
        toolName = t.name
        self.client = client
    }

    func call(_ input: Data?) async throws -> ToolResult {
        var args: [String: Value]?
        if let input, !input.isEmpty {
            do {
                args = try JSONDecoder().decode([String: Value].self, from: input)
            } catch {
                return .text("invalid arguments: \(error)", isError: true)
            }
        }
        let r = try await client.callTool(name: toolName, arguments: args)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let parts = r.content.map { c -> Part in
            if case .text(let t, _, _) = c { return .text(t) }
            return .text((try? enc.encode(c)).map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        return ToolResult(content: parts, isError: r.isError ?? false)
    }
}

/// An MCP transport over the stdio of a child: one JSON message on each line.
actor ChildTransport: Transport {
    nonisolated let logger = Logger(label: "agentbinder.mcp.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
    private let child: ChildProcess
    private let stream: AsyncThrowingStream<Data, any Error>
    private let sink: AsyncThrowingStream<Data, any Error>.Continuation
    private var reader: Task<Void, Never>?

    init(_ child: ChildProcess) {
        self.child = child
        (stream, sink) = AsyncThrowingStream.makeStream()
    }

    func connect() async throws {
        let child = child
        let sink = sink
        reader = Task.detached {
            var buf = Data()
            while case .data(let d) = await child.readStdout() {
                buf.append(d)
                while let nl = buf.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buf[buf.startIndex..<nl]
                    buf = Data(buf[buf.index(after: nl)...])
                    if !line.isEmpty { sink.yield(Data(line)) }
                }
            }
            sink.finish()
        }
    }

    func disconnect() async {
        child.closeStdin()
        reader?.cancel()
        sink.finish()
    }

    func send(_ data: Data) async throws {
        try await child.write(data + Data("\n".utf8))
    }

    nonisolated func receive() -> AsyncThrowingStream<Data, any Error> { stream }
}
