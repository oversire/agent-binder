import Foundation

/// One extra skill for a session: a folder that holds `SKILL.md`.
public struct Skill: Sendable, Equatable {
    /// A name that replaces the name in the `SKILL.md` frontmatter.
    public var name: String?
    /// The folder that holds `SKILL.md`.
    public var directory: URL

    /// Makes a skill.
    public init(name: String? = nil, directory: URL) {
        self.name = name
        self.directory = directory
    }
}

/// How a harness takes extra skills for one session.
public enum SkillSupport: String, Sendable, Codable {
    /// The harness gets no extra skills.
    case none
    /// The harness loads the skills from a folder that the library makes or names.
    case native
    /// The library links the skills into a config folder that the harness reads.
    case overlay
    /// The session instructions list the skills, and the agent reads them from disk.
    case instructions
}
