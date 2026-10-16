import Foundation
import Testing

@testable import AgentBinder

@Suite("SessionLiveTests", .serialized, .enabled(if: Live.on))
struct SessionLiveTests {
    @Test(arguments: Live.all) func oneTurn(_ h: Harness) async throws {
        try await Live.run(h, "one turn") { _, dir in
            let run = try await LiveRun.start(h, dir)
            let r = try await run.turn("Reply with the word PONG only.")
            await run.close()
            try #require(!r.isError, "\(r)")
            try #require(run.text.has("PONG"), "\(run.text)")
            try #require(run.results.count == 1)
            guard case .exit = run.events.last?.kind else { throw LiveFailure("no exit event after close") }
        }
    }

    @Test(arguments: Live.all) func permission(_ h: Harness) async throws {
        try await Live.run(h, "permission", needs: \.permissions) { _, dir in
            let run = try await LiveRun.start(h, dir) {
                $0.permissions = PermissionPolicy(mode: .ask)
                // Codex writes in a workspace-write sandbox with no question.
                if h == .codex { $0.raw = ["sandbox": .string("read-only")] }
            }
            let file = dir.appendingPathComponent("live.txt")
            let ask =
                "Create a file named live.txt in the current folder with the text hi. Use a tool. Do not ask me first."
            try await run.turn(ask) { _ in .deny("The user refuses file changes.") }
            let denied = run.permissions.count
            try #require(denied > 0, "no permission request")
            try #require(!FileManager.default.fileExists(atPath: file.path), "the file exists after a deny")
            try await run.turn("Try again now. I allow it.") { _ in .allow() }
            await run.close()
            try #require(run.permissions.count > denied, "no second permission request")
            try #require(FileManager.default.fileExists(atPath: file.path), "the file does not exist after an allow")
        }
    }
}
