import Foundation

/// A skill with its resolved name and description.
struct LoadedSkill: Sendable, Equatable {
    var name: String
    var directory: URL
    var description: String

    var file: URL { directory.appendingPathComponent("SKILL.md") }

    /// Reads the frontmatter of a skill. The name is the explicit name, else the frontmatter name,
    /// else the folder name.
    init(_ s: Skill) throws {
        var isDir: ObjCBool = false
        let path = s.directory.appendingPathComponent("SKILL.md").path
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw AgentBinderError.invalidRequest("skill \(s.directory.path): SKILL.md not found")
        }
        if isDir.boolValue {
            throw AgentBinderError.invalidRequest("skill \(s.directory.path): SKILL.md is a directory")
        }
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw AgentBinderError.invalidRequest("skill \(s.directory.path): \(error.localizedDescription)")
        }
        let front = Frontmatter(text)
        var name = s.name ?? ""
        if name.isEmpty { name = front["name"] ?? "" }
        if name.isEmpty { name = s.directory.standardizedFileURL.lastPathComponent }
        self.name = name
        directory = s.directory
        description = (front["description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Makes skills visible to a harness: a plugin folder, links in a config home, or an index text.
enum SkillOverlay {
    static let pluginName = "agentbinder-session"

    /// The index for the instructions fallback: enough for the agent to find each skill, and the
    /// rule to read it first.
    static func index(_ skills: [LoadedSkill]) -> String {
        var out = "Skills available for this session. Each entry names a task area. "
        out += "Read the file before you do a task that matches it.\n"
        for s in skills {
            out += "\n- " + s.name
            if !s.description.isEmpty {
                out += ": " + s.description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            out += "\n  file: " + s.file.path + "\n"
        }
        return out
    }

    /// Writes a Claude Code plugin whose skills are links to the skill folders.
    /// The plugin loads next to the skills of the user; it does not replace them.
    static func writeClaudePlugin(at dir: URL, _ skills: [LoadedSkill]) throws {
        try ConfigFiles.writeJSON(
            [
                "name": .string(pluginName),
                "description": "Skills injected by agentbinder for this session.",
                "version": "0.0.0",
            ], to: dir.appendingPathComponent(".claude-plugin/plugin.json"))
        try link(skills, into: dir.appendingPathComponent("skills"))
    }

    /// Links name → skill folder in a folder that the harness reads.
    /// It replaces an entry that exists, so a repeated session gives the same result.
    static func link(_ skills: [LoadedSkill], into root: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for s in skills {
                let target = root.appendingPathComponent(s.name)
                // A dangling link is not "existing" to fileExists, so remove it on its own.
                if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil || fm.fileExists(atPath: target.path)
                {
                    try fm.removeItem(at: target)
                }
                try fm.createSymbolicLink(at: target, withDestinationURL: s.directory)
            }
        } catch {
            throw AgentBinderError.launch("link skills in \(root.path): \(error.localizedDescription)")
        }
    }
}
