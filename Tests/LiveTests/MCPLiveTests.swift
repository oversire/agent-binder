import Foundation
import Testing

@testable import AgentBinder

@Suite("MCPLiveTests", .serialized, .enabled(if: Live.on))
struct MCPLiveTests {
    @Test(arguments: Live.all) func mcpInjection(_ h: Harness) async throws {
        try await Live.run(h, "mcp", needs: { $0.mcpInject != .none }) { _, dir in
            try #require(
                FileManager.default.isExecutableFile(atPath: Live.helper.path), "build agentbinder-mcp-helper first")
            let phrase = "marker-\(UUID().uuidString.prefix(8).lowercased())"
            let run = try await LiveRun.start(h, dir) {
                $0.permissions = PermissionPolicy(mode: .auto)
                $0.mcpServers = [.stdio(name: "live", command: Live.helper.path, args: [phrase])]
            }
            try await run.turn("Call the tool marker of the MCP server live. Reply with its output only.") { _ in
                .allow()
            }
            await run.close()
            try #require(run.text.has(phrase), "\(run.text.suffix(300))")
        }
    }
}
