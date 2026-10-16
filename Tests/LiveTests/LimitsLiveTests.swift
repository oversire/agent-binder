import Foundation
import Testing

@testable import AgentBinder

@Suite("LimitsLiveTests", .serialized, .enabled(if: Live.on))
struct LimitsLiveTests {
    @Test func claudeLimitsEvent() async throws {
        try await Live.run(.claude, "limits") { _, dir in
            let run = try await LiveRun.start(.claude, dir)
            try await run.turn("Reply with the word PONG only.")
            await run.close()
            try #require(run.events.contains { if case .limits = $0.kind { true } else { false } }, "no limits event")
        }
    }

    @Test func codexLimits() async throws {
        try await Live.run(.codex, "limits") { _, dir in
            let rt = Live.runtime()
            let l = try await rt.limits(.codex, query: ModelQuery(workingDirectory: dir))
            await rt.close()
            try #require(!l.windows.isEmpty, "no limit windows: \(l)")
        }
    }
}
