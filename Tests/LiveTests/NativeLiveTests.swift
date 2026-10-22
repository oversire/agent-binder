import AgentBinderMCP
import AgentBinderNative
import Foundation
import Testing

@testable import AgentBinder

/// Real provider calls. They need `AGENTBINDER_LIVE_NATIVE=1` and a key in
/// `AGENTBINDER_LIVE_ANTHROPIC_KEY` or `AGENTBINDER_LIVE_OPENAI_KEY`. The names differ from the
/// vendor names, so the key cannot reach a CLI child of the other live tests.
@Suite("NativeLiveTests", .serialized, .enabled(if: Live.env["AGENTBINDER_LIVE_NATIVE"] == "1"))
struct NativeLiveTests {
    static let cases: [(Credentials.Format, String, String?)] = [
        (.anthropic, "AGENTBINDER_LIVE_ANTHROPIC_KEY", nil),
        (.openai, "AGENTBINDER_LIVE_OPENAI_KEY", Live.env["AGENTBINDER_LIVE_OPENAI_MODEL"] ?? "gpt-5-mini"),
    ]

    @Test(arguments: [0, 1]) func oneTurn(_ i: Int) async throws {
        let (format, keyName, model) = Self.cases[i]
        guard let key = Live.env[keyName], !key.isEmpty else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentbinder-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let run = try await LiveRun.start(.native, dir, runtime: await Self.runtime()) {
            $0.credentials = Credentials(format: format, apiKey: key)
            $0.model = model
        }
        let r = try await run.turn("Reply with the word PONG only.")
        await run.close()
        try #require(!r.isError && run.text.has("PONG"), "\(r)")
        try #require(r.usage.input > 0, "no usage")
    }

    /// The native loop calls a tool of `agentbinder-mcp-helper` through `MCPToolSet.factory`.
    @Test(arguments: [0, 1]) func mcpTool(_ i: Int) async throws {
        let (format, keyName, model) = Self.cases[i]
        guard let key = Live.env[keyName], !key.isEmpty else { return }
        try #require(
            FileManager.default.isExecutableFile(atPath: Live.helper.path), "build agentbinder-mcp-helper first")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentbinder-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let phrase = "marker-\(UUID().uuidString.prefix(8).lowercased())"
        let run = try await LiveRun.start(.native, dir, runtime: await Self.runtime()) {
            $0.credentials = Credentials(format: format, apiKey: key)
            $0.model = model
            $0.permissions = PermissionPolicy(mode: .auto)
            $0.mcpServers = [.stdio(name: "live", command: Live.helper.path, args: [phrase])]
        }
        let r = try await run.turn("Call the tool marker of the MCP server live. Reply with its output only.") { _ in
            .allow()
        }
        await run.close()
        try #require(!r.isError && run.text.has(phrase), "\(run.text.suffix(300))")
    }

    static func runtime() async -> Runtime {
        let rt = Runtime()
        let config = NativeConfig(
            newModel: { creds, name in
                switch creds.format {
                case .anthropic: return try AnthropicModel(credentials: creds, model: name)
                case .openai: return try OpenAIModel(credentials: creds, model: name)
                }
            }, mcpFactory: MCPToolSet.factory)
        await rt.setDriver(NativeDriver(config), for: .native)
        return rt
    }
}
