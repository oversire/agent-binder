import Foundation
import Testing

@testable import AgentBinder

@Suite("ModelsLiveTests", .serialized, .enabled(if: Live.on))
struct ModelsLiveTests {
    @Test(arguments: Live.all) func models(_ h: Harness) async throws {
        try await Live.run(h, "models", needs: \.models) { d, dir in
            let rt = Live.runtime()
            let list = try await rt.models(h, query: ModelQuery(workingDirectory: dir))
            try #require(!list.isEmpty, "no models")
            try #require(list.filter(\.isDefault).count <= 1, "more than one default")
            // A model of the default provider: the login of another provider can be missing.
            let provider = list.first(where: \.isDefault)?.id.split(separator: "/").first.map { $0 + "/" }
            let others = list.filter { !$0.isDefault }
            let pick = others.first { m in provider.map { m.id.hasPrefix($0) } ?? false } ?? others.first ?? list.first
            guard d.features.setModel, let other = pick else {
                await rt.close()
                return
            }
            let run = try await LiveRun.start(h, dir, runtime: rt)
            let s = try #require(run.session as? any ModelSettable, "the session cannot set the model")
            try await s.setModel(other.id)
            let r = try await run.turn("Reply with the word PONG only.")
            await run.close()
            try #require(!r.isError && run.text.has("PONG"), "model \(other.id): \(r)")
        }
    }
}
