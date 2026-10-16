import Foundation
import Testing

@testable import AgentBinder

@Suite("ResumeLiveTests", .serialized, .enabled(if: Live.on))
struct ResumeLiveTests {
    @Test(arguments: Live.all) func resume(_ h: Harness) async throws {
        try await Live.run(h, "resume", needs: \.resume) { _, dir in
            let first = try await LiveRun.start(h, dir)
            try await first.turn("Remember the number 4172. Reply with OK only.")
            let id = first.session.id ?? first.results.last?.sessionID
            await first.close()
            guard let id else { throw LiveFailure("no session id") }
            let second = try await LiveRun.start(h, dir, resume: true) { $0.sessionID = id }
            let r = try await second.turn("What number did I ask you to remember? Reply with the number only.")
            await second.close()
            try #require(second.text.has("4172"), "\(r)")
        }
    }
}
