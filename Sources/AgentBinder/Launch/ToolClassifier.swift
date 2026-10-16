import Foundation

/// Maps vendor tool names to a coarse ``ToolKind``, so a consumer needs no table for each vendor.
enum ToolClassifier {
    private static let tokens: [String: ToolKind] = {
        var m: [String: ToolKind] = [:]
        for t in ["mcp", "mcptoolcall"] { m[t] = .mcp }
        for t in ["read", "view", "cat", "open", "fetch", "readfile", "readtextfile", "notebookread"] { m[t] = .read }
        for t in [
            "edit", "write", "multiedit", "patch", "applypatch", "apply", "create", "replace", "notebookedit",
            "filechange", "change", "writefile", "writetextfile", "save",
        ] { m[t] = .edit }
        for t in ["bash", "shell", "exec", "execute", "command", "terminal", "cmd", "run", "commandexecution"] {
            m[t] = .exec
        }
        for t in ["grep", "glob", "search", "find", "list", "ls", "websearch", "web"] { m[t] = .search }
        return m
    }()

    /// The kind of a tool name. The first token that is in a table decides.
    static func kind(for name: String) -> ToolKind {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n.isEmpty { return .other }
        if n.hasPrefix("mcp__") || n.hasPrefix("mcp_") { return .mcp }
        let words = n.split { c in !(c.isASCII && (c.isLetter || c.isNumber)) }
        for w in words {
            if let k = tokens[String(w)] { return k }
        }
        return .other
    }

    /// The files that an edit input names. Read paths are not changes, so other kinds give none.
    static func paths(kind: ToolKind, input: String) -> [String] {
        guard kind == .edit, let m = JSONValue.parse(input)?.object else { return [] }
        var out: [String] = []
        for key in ["file_path", "filePath", "path", "notebook_path", "target_file", "file"] {
            guard let s = m[key]?.string, !s.isEmpty, !out.contains(s) else { continue }
            out.append(s)
        }
        return out
    }

    /// The kind of a permission request. A generic name falls back to the keys of the input.
    static func permissionKind(name: String, input: String) -> ToolKind {
        let k = kind(for: name)
        if k != .other { return k }
        guard let m = JSONValue.parse(input)?.object else { return .other }
        for key in m.keys {
            switch key.lowercased() {
            case "file_path", "filepath", "path", "notebook_path", "new_string", "old_string": return .edit
            case "command", "cmd": return .exec
            default: continue
            }
        }
        return .other
    }
}
