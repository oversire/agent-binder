import Foundation

/// Reads the transcript file of an agent session and makes a ``TranscriptDigest``.
///
/// Only ``Harness/claude`` has a reader now. The other harnesses throw ``TranscriptError/unsupportedHarness(_:)``.
///
/// ```swift
/// let reader = TranscriptReader()
/// let file = try reader.newest(harness: .claude, cwd: repo.path)
/// let digest = try reader.digest(file: file)
/// ```
public struct TranscriptReader: Sendable {
    /// How much of the history the reader keeps.
    public var budget: TranscriptBudget
    /// The config folder of Claude Code. Claude keeps its transcripts in `<claudeHome>/projects`.
    public var claudeHome: URL

    /// Makes a reader.
    ///
    /// - Parameters:
    ///   - budget: How much of the history the reader keeps.
    ///   - claudeHome: The config folder of Claude Code. The default is `CLAUDE_CONFIG_DIR`, else `~/.claude`.
    public init(budget: TranscriptBudget = TranscriptBudget(), claudeHome: URL? = nil) {
        self.budget = budget
        if let claudeHome {
            self.claudeHome = claudeHome
        } else if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            self.claudeHome = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            self.claudeHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }
    }

    /// Makes the digest of a transcript file.
    ///
    /// When no line has a session id, the session id is the file name without its extension.
    /// - Throws: ``TranscriptError/notFound(_:)`` when the file does not exist, or the read error of the file.
    public func digest(file: URL, harness: Harness = .claude) throws -> TranscriptDigest {
        try Self.require(harness)
        let data: Data
        do {
            data = try Data(contentsOf: file, options: .alwaysMapped)
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile {
            throw TranscriptError.notFound(file.path)
        }
        let name = file.lastPathComponent.unicodeScalars
        let stem =
            name.lastIndex(of: ".").map { String(String.UnicodeScalarView(name[..<$0])) } ?? file.lastPathComponent
        return digest(ClaudeTranscriptScan(data), harness: harness, fallbackSessionId: stem)
    }

    /// Makes the digest of transcript bytes, one JSON object on each line.
    ///
    /// - Parameter sessionId: The session id when no line has one.
    public func digest(data: Data, harness: Harness = .claude, sessionId: String) throws -> TranscriptDigest {
        try Self.require(harness)
        return digest(ClaudeTranscriptScan(data), harness: harness, fallbackSessionId: sessionId)
    }

    /// Finds the transcript file of a session.
    ///
    /// The reader looks first in the project folder of `cwd`. Then it looks in all project folders,
    /// and it takes the file with the newest modification time.
    /// - Throws: ``TranscriptError/notFound(_:)`` when no file has the session id.
    public func locate(harness: Harness, sessionId: String, cwd: String? = nil) throws -> URL {
        try Self.require(harness)
        let fm = FileManager.default
        let name = sessionId + ".jsonl"
        guard !sessionId.isEmpty, !sessionId.contains("/"), sessionId != ".", sessionId != ".." else {
            throw TranscriptError.notFound(sessionId)
        }
        if let cwd {
            let url = projects.appendingPathComponent(Self.projectFolderName(cwd: cwd)).appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        let folders = (try? fm.contentsOfDirectory(atPath: projects.path)) ?? []
        let hits = folders.map { projects.appendingPathComponent($0).appendingPathComponent(name) }
            .filter { fm.fileExists(atPath: $0.path) }
        guard let url = Self.newestFile(hits) else { throw TranscriptError.notFound(sessionId) }
        return url
    }

    /// Finds the transcript file with the newest modification time in the project folder of `cwd`.
    ///
    /// - Throws: ``TranscriptError/notFound(_:)`` when the folder has no transcript.
    public func newest(harness: Harness, cwd: String) throws -> URL {
        try Self.require(harness)
        let folder = projects.appendingPathComponent(Self.projectFolderName(cwd: cwd))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let files = names.filter { $0.hasSuffix(".jsonl") }.map { folder.appendingPathComponent($0) }
        guard let url = Self.newestFile(files) else {
            throw TranscriptError.notFound(cwd)
        }
        return url
    }

    /// The name of the Claude project folder for a working directory.
    ///
    /// Claude replaces each UTF-16 code unit that is not an ASCII letter or digit with `-`.
    /// Thus a character outside the Basic Multilingual Plane gives `--`.
    public static func projectFolderName(cwd: String) -> String {
        String(
            decoding: cwd.utf16.map { u -> UInt8 in
                switch u {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return UInt8(u)
                default: return 0x2D
                }
            }, as: UTF8.self)
    }

    private var projects: URL { claudeHome.appendingPathComponent("projects") }

    private static func require(_ harness: Harness) throws {
        guard harness == .claude else { throw TranscriptError.unsupportedHarness(harness) }
    }

    private static func newestFile(_ urls: [URL]) -> URL? {
        func mtime(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return urls.max { mtime($0) < mtime($1) }
    }

    private func digest(_ scan: ClaudeTranscriptScan, harness: Harness, fallbackSessionId: String) -> TranscriptDigest {
        let turns = scan.turns.filter { !$0.text.isEmpty }
        let full = min(max(budget.full, 0), turns.count)
        let earlierCount = max(budget.earlier, 0)
        let maxChars = max(budget.maxChars, 1)
        let head = turns[..<(turns.count - full)]
        let tail = turns[(turns.count - full)...]
        var truncated = head.count > earlierCount
        let earlier = head.suffix(earlierCount).map { t in
            TranscriptDigest.EarlierTurn(
                prompt: t.prompt.scalarPrefix(120), closing: t.text[t.text.count - 1].scalarPrefix(700),
                interrupted: t.interrupted)
        }
        let last = tail.map { t -> TranscriptDigest.LastTurn in
            var text = t.text.joined(separator: "\n\n")
            if text.unicodeScalars.count > maxChars {
                text = String(String.UnicodeScalarView(text.unicodeScalars.suffix(maxChars)))
                truncated = true
            }
            return TranscriptDigest.LastTurn(
                prompt: t.prompt.scalarPrefix(1500), text: text, tools: t.tools, interrupted: t.interrupted)
        }
        return TranscriptDigest(
            harness: harness, sessionId: scan.sessionId ?? fallbackSessionId, turns: turns.count, earlier: earlier,
            last: last, truncated: truncated)
    }
}

/// The turns of a Claude Code transcript (`~/.claude/projects/<folder>/<session>.jsonl`).
struct ClaudeTranscriptScan {
    struct Turn {
        var prompt: String
        var text: [String] = []
        var tools = 0
        var interrupted = false
    }

    private(set) var sessionId: String?
    private(set) var turns: [Turn] = []

    init(_ data: Data) {
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var start = 0
            while start < buf.count {
                let rest = buf.count - start
                let nl =
                    memchr(base + start, 0x0A, rest).map { $0 - UnsafeMutableRawPointer(mutating: base) } ?? buf.count
                // Python reads with universal newlines: a lone CR also ends a line.
                var s = start
                while s < nl {
                    let cr = memchr(base + s, 0x0D, nl - s).map { $0 - UnsafeMutableRawPointer(mutating: base) } ?? nl
                    if cr > s { line(UnsafeRawBufferPointer(rebasing: buf[s..<cr])) }
                    s = cr + 1
                }
                start = nl + 1
            }
        }
    }

    private static let userTag = Array(#""user""#.utf8)
    private static let assistantTag = Array(#""assistant""#.utf8)
    private static let escapeTag = Array(#"\u"#.utf8)

    /// A line can change the turns only when its `type` is `user` or `assistant`.
    /// Each such line holds one of the tags, or a `\u` escape that can spell them.
    private static func mayMatter(_ line: UnsafeRawBufferPointer) -> Bool {
        func has(_ tag: [UInt8]) -> Bool {
            tag.withUnsafeBytes { memmem(line.baseAddress, line.count, $0.baseAddress, $0.count) != nil }
        }
        return has(userTag) || has(assistantTag) || has(escapeTag)
    }

    private mutating func line(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress else { return }
        if sessionId != nil && !Self.mayMatter(bytes) { return }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
        guard let e = Self.object(data) else { return }
        if Self.truthy(e["isSidechain"]) { return }
        if sessionId == nil, let s = e["sessionId"] as? String, !s.isEmpty { sessionId = s }
        if let p = Self.promptText(e) {
            if p.hasScalarPrefix("[Request interrupted") {
                if !turns.isEmpty { turns[turns.count - 1].interrupted = true }
            } else if !p.isEmpty && !Self.isNotice(p) && !p.hasScalarPrefix("Caveat:") {
                turns.append(Turn(prompt: p))
            }
        } else if e["type"] as? String == "assistant", !turns.isEmpty,
            let blocks = (e["message"] as? [String: Any])?["content"] as? [Any]
        {
            for case let b as [String: Any] in blocks {
                switch b["type"] as? String {
                case "text":
                    let t = (b["text"] as? String ?? "").pythonStripped
                    if !t.isEmpty { turns[turns.count - 1].text.append(t) }
                case "tool_use": turns[turns.count - 1].tools += 1
                default: break
                }
            }
        }
    }

    /// Decodes one line. Invalid UTF-8 becomes U+FFFD, as with Python `errors="replace"`.
    /// Python rejects a line with a byte order mark. Python takes the last of two equal keys; Foundation takes the first.
    private static func object(_ data: Data) -> [String: Any]? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return nil }
        if let o = try? JSONSerialization.jsonObject(with: data) { return o as? [String: Any] }
        guard String(data: data, encoding: .utf8) == nil else { return nil }
        let fixed = Data(String(decoding: data, as: UTF8.self).utf8)
        return (try? JSONSerialization.jsonObject(with: fixed)) as? [String: Any]
    }

    /// The text of a human prompt, or nil for each other line.
    private static func promptText(_ e: [String: Any]) -> String? {
        guard e["type"] as? String == "user", !truthy(e["isMeta"]), !truthy(e["isCompactSummary"]) else { return nil }
        var content = (e["message"] as? [String: Any])?["content"]
        if let blocks = content as? [Any] {
            let dicts = blocks.compactMap { $0 as? [String: Any] }
            if dicts.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            content = dicts.filter { $0["type"] as? String == "text" }.map { $0["text"] as? String ?? "" }
                .joined(separator: "\n")
        }
        return (content as? String)?.pythonStripped
    }

    /// Harness notices (task, artifact, command output) start with a tag. Pasted content is a prompt.
    private static func isNotice(_ p: String) -> Bool {
        p.hasScalarPrefix("<") && !p.hasScalarPrefix("<pasted")
    }

    /// The truth value of a JSON value, as in Python.
    private static func truthy(_ v: Any?) -> Bool {
        guard let v, !(v is NSNull) else { return false }
        switch v {
        case let n as NSNumber: return n.doubleValue != 0
        case let s as String: return !s.isEmpty
        case let a as [Any]: return !a.isEmpty
        case let d as [String: Any]: return !d.isEmpty
        default: return true
        }
    }
}

extension String {
    /// The first `n` Unicode code points.
    fileprivate func scalarPrefix(_ n: Int) -> String {
        String(String.UnicodeScalarView(unicodeScalars.prefix(n)))
    }

    /// Compares code points, not characters, so a combining mark after the prefix does not change the result.
    fileprivate func hasScalarPrefix(_ p: String) -> Bool {
        unicodeScalars.starts(with: p.unicodeScalars)
    }

    /// Removes the white space at the two ends, with the set of Python `str.isspace`.
    fileprivate var pythonStripped: String {
        let u = unicodeScalars
        guard let lo = u.firstIndex(where: { !$0.isPythonSpace }), let hi = u.lastIndex(where: { !$0.isPythonSpace })
        else { return "" }
        return String(String.UnicodeScalarView(u[lo...hi]))
    }
}

extension Unicode.Scalar {
    fileprivate var isPythonSpace: Bool {
        switch value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default: return false
        }
    }
}
