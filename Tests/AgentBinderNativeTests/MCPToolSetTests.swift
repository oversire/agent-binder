import Foundation
import MCP
import Testing

@testable import AgentBinder
@testable import AgentBinderNative

@Suite("MCPToolSetTests")
struct MCPToolSetTests {
    /// An MCP server in memory with a `ping` tool. The list has two pages.
    static func connected(name: String = "trebi") async throws -> (MCPToolSet, Server) {
        let server = Server(name: "fake", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { p in
            let schema: Value = ["type": "object", "properties": ["n": ["type": "number"]]]
            if p.cursor == nil {
                return ListTools.Result(
                    tools: [
                        MCP.Tool(
                            name: "ping", description: "Ping", inputSchema: schema,
                            annotations: .init(readOnlyHint: true)),
                        MCP.Tool(name: "a.b c", description: nil, inputSchema: schema),
                    ], nextCursor: "p2")
            }
            return ListTools.Result(tools: [
                MCP.Tool(
                    name: "a_b c", description: nil, inputSchema: schema,
                    annotations: .init(title: "T", destructiveHint: true))
            ])
        }
        await server.withMethodHandler(CallTool.self) { p in
            switch p.name {
            case "ping":
                return CallTool.Result(content: [
                    .text(text: "pong \(p.arguments?["n"].map { "\($0)" } ?? "-")", annotations: nil, _meta: nil)
                ])
            case "a.b c":
                return CallTool.Result(
                    content: [.image(data: "AA==", mimeType: "image/png", annotations: nil, _meta: nil)], isError: true)
            default: throw MCPError.methodNotFound("no tool")
            }
        }
        let (ct, st) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: st)
        let client = Client(name: "t", version: "1")
        _ = try await client.connect(transport: ct)
        return (MCPToolSet(name: name, client: client), server)
    }

    // Fixed on purpose: the list follows nextCursor, and each name is provider-safe and unique.
    @Test func listAndCall() async throws {
        let (set, server) = try await Self.connected()
        let tools = try await set.tools()
        #expect(tools.map(\.spec.name) == ["mcp__trebi__ping", "mcp__trebi__a_b_c", "mcp__trebi__a_b_c_2"])
        #expect(tools[0].spec.annotations == ToolAnnotations(readOnly: true, kind: .mcp) && tools[0].spec.needsApproval)
        #expect(tools[2].spec.title == "T" && tools[2].spec.annotations.destructive && tools[2].spec.needsApproval)
        #expect(tools[0].spec.description == "Ping" && tools[0].spec.inputSchema != nil)
        let r = try await tools[0].call(Data(#"{"n":2}"#.utf8))
        #expect(r.content.text == "pong 2" && !r.isError)
        let img = try await tools[1].call(nil)
        #expect(img.isError && img.content.text.contains(#""mimeType":"image/png""#))
        let bad = try await tools[0].call(Data("[1".utf8))
        #expect(bad.isError && bad.content.text.hasPrefix("invalid arguments:"))
        await #expect(throws: (any Error).self) { try await tools[2].call(Data("{}".utf8)) }
        await set.close()
        await server.stop()
    }

    @Test func names() {
        #expect(MCPToolSet.toolName(server: "my srv", tool: "é/x") == "mcp__my_srv____x")
        let long = MCPToolSet.toolName(server: "s", tool: String(repeating: "t", count: 100))
        #expect(long.count == 64 && long.hasPrefix("mcp__s__t"))
    }

    @Test func executableLookup() throws {
        #expect(try MCPToolSet.executable("sh", path: "/nope:/bin").path == "/bin/sh")
        #expect(try MCPToolSet.executable("./x", path: nil).path.hasSuffix("/x"))
        #expect(throws: NativeError.config(#"native: mcp command "no-such-cmd" not found"#)) {
            try MCPToolSet.executable("no-such-cmd", path: "/bin")
        }
    }

    @Test func connectFailures() async throws {
        await #expect(throws: NativeError.config(#"native: mcp command "no-such-cmd" not found"#)) {
            _ = try await MCPToolSet.connect(
                MCPServer(name: "x", transport: .stdio(command: "no-such-cmd", args: [], env: [:])),
                environment: ["PATH": "/bin"])
        }
        await #expect {
            _ = try await MCPToolSet.connect(
                MCPServer(name: "x", transport: .stdio(command: "true", args: [], env: [:])),
                environment: ["PATH": "/usr/bin:/bin"])
        } throws: { ($0 as? NativeError)?.message.hasPrefix("native: mcp server x connect:") == true }
    }

    /// A tiny stdio MCP server in Python. It sends the `X_TOKEN` value back.
    static let script = #"""
        import json, os, sys
        for line in sys.stdin:
            m = json.loads(line)
            if "id" not in m: continue
            if m["method"] == "initialize":
                r = {"protocolVersion": m["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "py", "version": "1"}}
            elif m["method"] == "tools/list":
                r = {"tools": [{"name": "env", "inputSchema": {"type": "object"}}]}
            else:
                r = {"content": [{"type": "text", "text": os.environ.get("X_TOKEN", "")}]}
            print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
        """#

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func stdioServer() async throws {
        let dir = try Scratch()
        let file = try dir.write("server.py", Self.script)
        let set = try await MCPToolSet.connect(
            MCPServer(
                name: "py", transport: .stdio(command: "python3", args: ["-I", file.path], env: ["X_TOKEN": "t1"])),
            environment: ["PATH": "/usr/bin:/bin"])
        let tools = try await set.tools()
        #expect(tools.map(\.spec.name) == ["mcp__py__env"])
        #expect(try await tools[0].call(nil).content.text == "t1")
        await set.close()
    }

    @Test func sessionUsesMCPTools() async throws {
        let (set, server) = try await Self.connected()
        let m = ScriptedModel([
            .parts(StreamPart.calls(.call("1", "mcp__trebi__ping", #"{"n":1}"#))), .parts(StreamPart.text("ok")),
        ])
        let rt = await runtime(config(m) { $0.toolSets = [set] })
        var r = request()
        r.permissions = PermissionPolicy(allowTools: ["mcp__trebi__*"])
        let s = try await rt.start(r)
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await sink.waitResults(1)
        #expect(sink.tools.last?.output == "pong 1" && sink.tools.last?.kind == .mcp)
        let results = m.requests.value[1].messages.last?.parts
        #expect(results == [.toolResult(ToolResult(callID: "1", name: "mcp__trebi__ping", content: [.text("pong 1")]))])
        await rt.close()
        await set.close()
        await server.stop()
    }
}
