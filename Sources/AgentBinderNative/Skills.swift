import AgentBinder
import Foundation

/// The skills of one session: the catalog for the system prompt and the `activate_skill` tool.
struct SkillCatalog: Sendable {
    struct Entry: Sendable, Equatable {
        var name: String
        var description: String
        var allowedTools: [String]
        var directory: URL
        var body: String
    }

    let entries: [Entry]

    init(_ skills: [Skill]) throws {
        entries = try skills.map { s in
            let file = s.directory.appendingPathComponent("SKILL.md")
            let body: String
            do {
                body = try String(contentsOf: file, encoding: .utf8)
            } catch {
                throw NativeError.config(
                    "native: skill \(s.name ?? s.directory.lastPathComponent): \(error.localizedDescription)")
            }
            let fm = Frontmatter(body)
            let name =
                s.name.flatMap { $0.isEmpty ? nil : $0 } ?? fm["name"].flatMap { $0.isEmpty ? nil : $0 }
                ?? s.directory.lastPathComponent
            let tools = (fm["allowed-tools"] ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            return Entry(
                name: name, description: (fm["description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                allowedTools: tools, directory: s.directory, body: body)
        }
    }

    /// The catalog block of the system prompt. It is empty when there are no skills.
    var prompt: String {
        guard !entries.isEmpty else { return "" }
        var out = "<available_skills>\n"
        out +=
            "Each entry names a task area. Before you work in that area, activate the skill with the activate_skill tool and follow it.\n"
        for e in entries {
            out += "<skill>\n<name>\(e.name)</name>\n<description>\(e.description)</description>\n</skill>\n"
        }
        return out + "</available_skills>\n"
    }

    /// The `activate_skill` tool, or nil when there are no skills.
    var tool: (any Tool)? {
        guard !entries.isEmpty else { return nil }
        struct Input: Decodable, Sendable { var name: String }
        let entries = entries
        let schema =
            #"{"type":"object","properties":{"name":{"type":"string","description":"The skill name"}},"required":["name"]}"#
        return FuncTool(
            ToolSpec(
                name: "activate_skill", title: "Activate a skill",
                description: "Load the full SKILL.md of one skill. Activate a skill before you work in its task area.",
                inputSchema: Data(schema.utf8), annotations: ToolAnnotations(readOnly: true, kind: .read))
        ) { (i: Input) -> String in
            guard let e = entries.first(where: { $0.name == i.name }) else {
                throw ToolFailure("unknown skill \(JSONValue.quote(i.name))")
            }
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: e.directory.path)) ?? [])
                .filter { $0 != "SKILL.md" }.sorted()
            var out: [String: JSONValue] = ["content": .string(e.body)]
            if !files.isEmpty { out["resources"] = .array(files.map(JSONValue.string)) }
            return JSONValue.object(out).jsonString
        }
    }
}
