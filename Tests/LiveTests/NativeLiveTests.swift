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
        let rt = Runtime()
        let config = NativeConfig(newModel: { creds, name in
            switch creds.format {
            case .anthropic: return try AnthropicModel(credentials: creds, model: name)
            case .openai: return try OpenAIModel(credentials: creds, model: name)
            }
        })
        await rt.setDriver(NativeDriver(config), for: .native)
        let run = try await LiveRun.start(.native, dir, runtime: rt) {
            $0.credentials = Credentials(format: format, apiKey: key)
            $0.model = model
        }
        let r = try await run.turn("Reply with the word PONG only.")
        await run.close()
        try #require(!r.isError && run.text.has("PONG"), "\(r)")
        try #require(r.usage.input > 0, "no usage")
    }
}
