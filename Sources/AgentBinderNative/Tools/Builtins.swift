import AgentBinder
import Darwin
import Foundation

/// The built-in tool set `fs`: `bash`, `read`, `write`, `edit`, `glob` and `grep` in one workspace root.
///
/// A path must stay inside the root. An absolute path, a `..` that leaves the root, the root itself
/// and a symlink that leads out of the root are refused.
public struct FileTools: ToolSet {
    /// The default size limit of a file.
    public static let defaultMaxFileBytes: Int64 = 10 << 20
    static let bashOutputMax = 8000
    static let globMax = 200
    static let grepMax = 100
    static let grepFileMax: Int64 = 1 << 20
    static let grepLineMax = 200

    /// The name of the set.
    public let name = "fs"
    let workspace: Workspace
    let environment: [String: String]
    let bashTimeout: Duration
    let maxFileBytes: Int64

    /// Makes the set.
    /// - Parameters:
    ///   - root: The workspace root.
    ///   - environment: The full environment of a `bash` command.
    ///   - bashTimeout: The time limit of one command.
    ///   - maxFileBytes: The size limit of a file that `read`, `write` and `edit` touch.
    public init(
        root: URL, environment: [String: String], bashTimeout: Duration = .seconds(60),
        maxFileBytes: Int64 = FileTools.defaultMaxFileBytes
    ) {
        workspace = Workspace(root: root)
        self.environment = environment
        self.bashTimeout = bashTimeout
        self.maxFileBytes = maxFileBytes > 0 ? maxFileBytes : Self.defaultMaxFileBytes
    }

    /// The six tools.
    public func tools() async throws -> [any Tool] {
        [bash, read, write, edit, glob, grep]
    }

    /// Does nothing.
    public func close() async {}

    // MARK: tools

    struct Command: Decodable, Sendable { var command: String }
    struct PathInput: Decodable, Sendable { var path: String }
    struct WriteInput: Decodable, Sendable {
        var path: String
        var content: String
    }
    struct EditInput: Decodable, Sendable {
        var path: String
        var old_string: String
        var new_string: String
    }
    struct Pattern: Decodable, Sendable {
        var pattern: String?
        var path: String?
    }

    var bash: some Tool {
        FuncTool(
            ToolSpec(
                name: "bash", title: "Run a command",
                description: "Run a shell command in the workspace root. No login shell.",
                inputSchema: ToolSpec.strings(["command"], required: ["command"]),
                annotations: ToolAnnotations(destructive: true, openWorld: true, kind: .exec))
        ) { [self] (i: Command) -> String in try await runBash(i.command) }
    }

    var read: some Tool {
        FuncTool(
            ToolSpec(
                name: "read", title: "Read a file", description: "Read a workspace file.",
                inputSchema: ToolSpec.strings(["path"], required: ["path"]),
                annotations: ToolAnnotations(readOnly: true, kind: .read))
        ) { [self] (i: PathInput) -> String in
            try Task.checkCancellation()
            return String(decoding: try readCapped(try workspace.resolve(i.path)), as: UTF8.self)
        }
    }

    var write: some Tool {
        FuncTool(
            ToolSpec(
                name: "write", title: "Write a file", description: "Write a workspace file (create or replace).",
                inputSchema: ToolSpec.strings(["path", "content"], required: ["path", "content"]),
                annotations: ToolAnnotations(destructive: true, kind: .edit))
        ) { [self] (i: WriteInput) -> String in
            try Task.checkCancellation()
            let url = try workspace.resolve(i.path)
            try writeCapped(Data(i.content.utf8), to: url)
            return "wrote \(i.path)"
        }
    }

    var edit: some Tool {
        FuncTool(
            ToolSpec(
                name: "edit", title: "Edit a file",
                description: "Replace one unique occurrence of old_string in a workspace file.",
                inputSchema: ToolSpec.strings(
                    ["path", "old_string", "new_string"], required: ["path", "old_string", "new_string"]),
                annotations: ToolAnnotations(destructive: true, kind: .edit))
        ) { [self] (i: EditInput) -> String in
            try Task.checkCancellation()
            let url = try workspace.resolve(i.path)
            let text = String(decoding: try readCapped(url), as: UTF8.self)
            let n =
                i.old_string.isEmpty
                ? (text.isEmpty ? 1 : text.count + 1) : text.components(separatedBy: i.old_string).count - 1
            if n == 0 { throw ToolFailure("old_string not found") }
            if n > 1 { throw ToolFailure("old_string matched \(n) times; must be unique") }
            let out =
                i.old_string.isEmpty ? i.new_string : text.replacingOccurrences(of: i.old_string, with: i.new_string)
            try writeCapped(Data(out.utf8), to: url)
            return "edited \(i.path)"
        }
    }

    var glob: some Tool {
        FuncTool(
            ToolSpec(
                name: "glob", title: "List files", description: "List workspace files matching a glob pattern.",
                inputSchema: ToolSpec.strings(["pattern"], required: ["pattern"]),
                annotations: ToolAnnotations(readOnly: true, kind: .search))
        ) { [self] (i: Pattern) -> String in
            try Task.checkCancellation()
            let pattern = Glob(i.pattern.flatMap { $0.isEmpty ? nil : $0 } ?? "**/*")
            var hits: [String] = []
            workspace.walk(workspace.root) { rel, _ in
                if pattern.matches(rel) { hits.append(rel) }
                return hits.count < Self.globMax
            }
            return hits.isEmpty ? "(no matches)" : hits.joined(separator: "\n")
        }
    }

    var grep: some Tool {
        FuncTool(
            ToolSpec(
                name: "grep", title: "Search files", description: "Search workspace files for a regular expression.",
                inputSchema: ToolSpec.strings(["pattern", "path"], required: ["pattern"]),
                annotations: ToolAnnotations(readOnly: true, kind: .search))
        ) { [self] (i: Pattern) -> String in
            try Task.checkCancellation()
            let re: NSRegularExpression
            do {
                re = try NSRegularExpression(pattern: i.pattern ?? "")
            } catch {
                throw ToolFailure("bad pattern: \(error.localizedDescription)")
            }
            let start = try i.path.flatMap { $0.isEmpty ? nil : $0 }.map(workspace.resolve) ?? workspace.root
            var hits: [String] = []
            workspace.walk(start) { rel, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                guard size <= Self.grepFileMax, let data = try? Data(contentsOf: url) else { return true }
                for (n, line) in String(decoding: data, as: UTF8.self).components(separatedBy: "\n").enumerated() {
                    let ns = line as NSString
                    guard re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil else {
                        continue
                    }
                    hits.append("\(rel):\(n + 1):\(Part.cut(line, Self.grepLineMax))")
                    if hits.count >= Self.grepMax { return false }
                }
                return true
            }
            return hits.isEmpty ? "(no matches)" : hits.joined(separator: "\n")
        }
    }

    // MARK: work

    private func readCapped(_ url: URL) throws -> Data {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size > maxFileBytes { throw ToolFailure("file exceeds the size limit") }
        return try Data(contentsOf: url)
    }

    private func writeCapped(_ data: Data, to url: URL) throws {
        if data.count > maxFileBytes { throw ToolFailure("file exceeds the size limit") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Runs `sh -c` in the root with stdout and stderr merged. A failure is a normal result: the model reads it.
    func runBash(_ command: String) async throws -> String {
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ToolFailure("empty command") }
        try Task.checkCancellation()
        let child: ChildProcess
        do {
            child = try ChildProcess.spawn(
                SpawnOptions(
                    executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec 2>&1\n" + command],
                    directory: workspace.root, environment: environment))
        } catch {
            return "\n\(error)"
        }
        child.closeStdin()
        let timedOut = Locked(false)
        // Fixed on purpose: a timeout kills the process group, so a grandchild cannot hold the pipe open.
        let timer = Task { [bashTimeout] in
            guard (try? await Task.sleep(for: bashTimeout)) != nil else { return }
            timedOut.withLock { $0 = true }
            child.signalGroup(SIGKILL)
        }
        defer { timer.cancel() }
        var out = Data()
        var cut = false
        while true {
            if Task.isCancelled {
                child.signalGroup(SIGKILL)
                break
            }
            guard case .data(let d) = await child.readStdout() else { break }
            if out.count < Self.bashOutputMax { out.append(d) } else { cut = true }
        }
        await child.waitForExit()
        if out.count > Self.bashOutputMax {
            out = out.prefix(Self.bashOutputMax)
            cut = true
        }
        var text = String(decoding: out, as: UTF8.self)
        if cut { text += "…" }
        if timedOut.value { return text + "\ncommand timed out after \(bashTimeout)" }
        let code = child.exitStatus?.code ?? -1
        return code == 0 ? text : text + "\nexit code \(code)"
    }
}

/// A tool failure with a text for the model.
struct ToolFailure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// The root of the built-in tools.
struct Workspace: Sendable {
    let root: URL

    init(root: URL) { self.root = root.standardizedFileURL }

    /// Joins a relative path to the root. It refuses each path that leaves the root.
    func resolve(_ path: String) throws -> URL {
        let escape = ToolFailure("path escapes the workspace root")
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !p.hasPrefix("/") else { throw escape }
        var parts: [Substring] = []
        for seg in p.split(separator: "/") where seg != "." {
            if seg == ".." {
                guard !parts.isEmpty else { throw escape }
                parts.removeLast()
            } else {
                parts.append(seg)
            }
        }
        guard !parts.isEmpty else { throw escape }
        let url = root.appendingPathComponent(parts.joined(separator: "/"))
        // Changed on purpose: a symlink must not lead out of the root.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path.count > root.path.count {
            probe.deleteLastPathComponent()
        }
        let real = probe.resolvingSymlinksInPath().path
        let realRoot = root.resolvingSymlinksInPath().path
        guard real == realRoot || real.hasPrefix(realRoot + "/") else { throw escape }
        return url
    }

    /// Walks the regular files under a folder in lexical order, and skips `.git`.
    /// The visitor gets the path relative to the root. It returns false to stop.
    func walk(_ start: URL, _ visit: (String, URL) -> Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: start.path, isDirectory: &isDir) else { return }
        let prefix = root.path.count + 1
        if !isDir.boolValue {
            _ = visit(String(start.path.dropFirst(prefix)), start)
            return
        }
        func go(_ dir: URL) -> Bool {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return true }
            for name in names.sorted() where name != ".git" {
                let url = dir.appendingPathComponent(name)
                guard
                    let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                else { continue }
                if v.isDirectory == true && v.isSymbolicLink != true {
                    if !go(url) { return false }
                } else if v.isRegularFile == true {
                    if !visit(String(url.path.dropFirst(prefix)), url) { return false }
                }
            }
            return true
        }
        _ = go(start.standardizedFileURL)
    }
}

/// A glob pattern. `*`, `?` and `[...]` match inside one path segment, and a `**` segment matches
/// zero or more segments. A file matches with its relative path or its base name.
struct Glob: Sendable {
    let segments: [String]

    init(_ pattern: String) { segments = pattern.split(separator: "/").map(String.init) }

    func matches(_ rel: String) -> Bool {
        let path = rel.split(separator: "/").map(String.init)
        return Self.match(segments[...], path[...]) || (path.count > 1 && Self.match(segments[...], [path.last!]))
    }

    // Fixed on purpose: `**` is zero or more segments, so `**/*.go` matches root files and deep files.
    private static func match(_ p: ArraySlice<String>, _ s: ArraySlice<String>) -> Bool {
        guard let head = p.first else { return s.isEmpty }
        if head == "**" {
            let rest = p.dropFirst()
            for i in s.startIndex...s.endIndex where match(rest, s[i...]) { return true }
            return false
        }
        guard let seg = s.first, fnmatch(head, seg, 0) == 0 else { return false }
        return match(p.dropFirst(), s.dropFirst())
    }
}
