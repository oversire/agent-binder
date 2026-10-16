import Foundation
import Testing

@testable import AgentBinder

@Suite("InterruptLiveTests", .serialized, .enabled(if: Live.on))
struct InterruptLiveTests {
    static let long = "Write the numbers from 1 to 400 in words, one on each line. Do not use tools."

    static func started(_ evs: [Event]) -> Bool {
        evs.contains {
            switch $0.kind {
            case .assistant, .thought: return true
            default: return false
            }
        }
    }

    @Test(arguments: Live.all) func interrupt(_ h: Harness) async throws {
        try await Live.run(h, "interrupt") { _, dir in
            let run = try await LiveRun.start(h, dir)
            try await run.session.prompt(Prompt(Self.long))
            try await run.wait("first delta", Self.started)
            try await run.session.interrupt()
            try await run.wait("result after interrupt", timeout: .seconds(30)) { evs in
                evs.contains { if case .result = $0.kind { true } else { false } }
            }
            let r = try await run.turn("Reply with the word PONG only.")
            await run.close()
            try #require(r.text.has("PONG") || run.text.has("PONG"), "the session is not usable after the interrupt")
        }
    }

    @Test(arguments: [Harness.claude, .codex]) func steer(_ h: Harness) async throws {
        try await Live.run(h, "steer", needs: \.steer) { _, dir in
            let run = try await LiveRun.start(h, dir)
            try await run.session.prompt(Prompt(Self.long))
            try await run.wait("first delta", Self.started)
            let d = try await run.session.send(Prompt("Stop now. Reply with the word STEERED only."))
            try await run.wait("result after steer") { evs in
                evs.contains { if case .result = $0.kind { true } else { false } }
            }
            try? await run.wait("idle", timeout: .seconds(60)) { evs in
                evs.last.map { if case .status(.idle, _) = $0.kind { true } else { false } } ?? false
            }
            await run.close()
            try #require(d == .steered, "delivery \(d)")
            try #require(run.text.has("STEERED"), "\(run.text.suffix(300))")
        }
    }
}
