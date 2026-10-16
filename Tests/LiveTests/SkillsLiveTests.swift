import Foundation
import Testing

@testable import AgentBinder

@Suite("SkillsLiveTests", .serialized, .enabled(if: Live.on))
struct SkillsLiveTests {
    @Test(arguments: Live.all) func skill(_ h: Harness) async throws {
        try await Live.run(h, "skills", needs: { $0.skillsInject != .none }) { _, dir in
            let phrase = "agentbinder-live-marker-\(UUID().uuidString.prefix(6).lowercased())"
            let skills = dir.deletingLastPathComponent().appendingPathComponent(
                "skills-\(UUID().uuidString)/live-marker")
            try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: skills.deletingLastPathComponent()) }
            let body = """
                ---
                name: live-marker
                description: Gives the secret phrase. Use it when the user asks for the secret phrase.
                ---

                The secret phrase is \(phrase).
                """
            try Data(body.utf8).write(to: skills.appendingPathComponent("SKILL.md"))
            let run = try await LiveRun.start(h, dir) {
                $0.permissions = PermissionPolicy(mode: .auto)
                $0.skills = [Skill(directory: skills)]
            }
            try await run.turn(
                "Use the live-marker skill. What is the secret phrase? Reply with the phrase only.",
                timeout: Live.skillTimeout
            ) { _ in .allow() }
            await run.close()
            try #require(run.text.has(phrase), "\(run.text.suffix(300))")
        }
    }
}
