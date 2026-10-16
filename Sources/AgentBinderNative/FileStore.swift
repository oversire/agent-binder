import AgentBinder
import Darwin
import Foundation

/// Keeps the message history of each session, so a resume can continue it.
public protocol MessageStore: Sendable {
    /// Loads the history. It throws ``NativeError/notFound`` when the store has none.
    func load(_ sessionID: String) async throws -> [Message]
    /// Adds messages to the end of the history.
    func append(_ sessionID: String, _ messages: [Message]) async throws
    /// Replaces the history.
    func replace(_ sessionID: String, _ messages: [Message]) async throws
}

/// A store with one JSONL file for each session: `<directory>/<id>.messages.jsonl`, mode 0600.
///
/// Each character of the id that is not a letter, a digit, `_` or `-` becomes `_`.
public struct FileStore: MessageStore {
    static let maxLine = 16 << 20

    /// The folder of the files.
    public let directory: URL

    /// Makes a store. The folder is made on the first write.
    public init(directory: URL) { self.directory = directory }

    /// The file of a session.
    public func file(_ sessionID: String) -> URL {
        let safe = String(
            sessionID.unicodeScalars.map { c -> Character in
                CharacterSet.alphanumerics.contains(c) && c.isASCII || c == "_" || c == "-" ? Character(c) : "_"
            })
        return directory.appendingPathComponent("\(safe).messages.jsonl")
    }

    /// Loads the history. Blank lines and lines that do not parse are skipped.
    public func load(_ sessionID: String) async throws -> [Message] {
        let url = file(sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { throw NativeError.notFound }
        let data = try Data(contentsOf: url)
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard line.count <= Self.maxLine, let v = JSONValue.parse(Data(line)) else { return nil }
            return Message(line: v)
        }
    }

    /// Adds one line for each message.
    public func append(_ sessionID: String, _ messages: [Message]) async throws {
        guard !messages.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = file(sessionID)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw NativeError("store_failed", "native: store \(url.path): \(String(cString: strerror(errno)))")
        }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try h.write(contentsOf: Self.lines(messages))
        try h.close()
    }

    /// Writes a temporary file, then renames it over the history.
    public func replace(_ sessionID: String, _ messages: [Message]) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = file(sessionID)
        let tmp = url.appendingPathExtension("tmp")
        do {
            guard
                FileManager.default.createFile(
                    atPath: tmp.path, contents: Self.lines(messages), attributes: [.posixPermissions: 0o600])
            else { throw NativeError("store_failed", "native: store \(tmp.path): write failed") }
            if rename(tmp.path, url.path) != 0 {
                throw NativeError("store_failed", "native: store \(url.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    static func lines(_ messages: [Message]) -> Data {
        Data(messages.map { $0.line.jsonString + "\n" }.joined().utf8)
    }
}

/// A store in memory, for tests and short-lived apps.
public actor MemoryStore: MessageStore {
    private var logs: [String: [Message]] = [:]

    /// Makes an empty store.
    public init() {}

    /// Loads a copy of the history.
    public func load(_ sessionID: String) async throws -> [Message] {
        guard let m = logs[sessionID] else { throw NativeError.notFound }
        return m
    }

    /// Adds messages.
    public func append(_ sessionID: String, _ messages: [Message]) async throws {
        logs[sessionID, default: []] += messages
    }

    /// Replaces the history.
    public func replace(_ sessionID: String, _ messages: [Message]) async throws {
        logs[sessionID] = messages
    }
}

// MARK: line format

extension Message {
    /// One store line: `{"role":…,"parts":[{"text":{"text":…}}, …]}`. Each part has exactly one key.
    var line: JSONValue {
        ["role": .string(role.rawValue), "parts": .array(parts.map(\.line))]
    }

    /// Reads a store line, or a legacy line with `Role` and `Content`.
    init?(line v: JSONValue) {
        if v["parts"] != nil, let r = v["role"]?.string.flatMap(Role.init(rawValue:)) {
            self.init(role: r, parts: (v["parts"]?.array ?? []).compactMap(Part.init(line:)))
            return
        }
        self.init(legacy: v)
    }

    // Lines of an older format. The keys match without regard to case.
    private init?(legacy v: JSONValue) {
        guard let o = v.object else { return nil }
        func key(_ k: String, in o: [String: JSONValue]) -> JSONValue? {
            o.first { $0.key.caseInsensitiveCompare(k) == .orderedSame }?.value
        }
        let content = key("Content", in: o)?.string ?? ""
        switch key("Role", in: o)?.string {
        case "user", "assistant":
            var parts: [Part] = content.isEmpty ? [] : [.text(content)]
            for c in key("ToolCalls", in: o)?.array ?? [] {
                guard let co = c.object else { continue }
                let args = key("Arguments", in: co)
                parts.append(
                    .toolCall(
                        ToolCall(
                            id: key("ID", in: co)?.string ?? "", name: key("Name", in: co)?.string ?? "",
                            input: args.map { $0.isNull ? nil : $0.jsonData } ?? nil)))
            }
            self.init(role: key("Role", in: o)?.string == "user" ? .user : .assistant, parts: parts)
        case "tool":
            self.init(
                role: .tool,
                parts: [
                    .toolResult(
                        ToolResult(
                            callID: key("ToolCallID", in: o)?.string ?? "", name: key("Name", in: o)?.string ?? "",
                            content: [.text(content)]))
                ])
        default:
            return nil
        }
    }
}

extension Part {
    var line: JSONValue {
        switch self {
        case .text(let t): return ["text": ["text": .string(t)]]
        case .file(let f):
            var o: [String: JSONValue] = [:]
            if !f.mediaType.isEmpty { o["media_type"] = .string(f.mediaType) }
            if let d = f.data, !d.isEmpty { o["data"] = .string(d.base64EncodedString()) }
            if let u = f.url, !u.isEmpty { o["url"] = .string(u) }
            return ["file": .object(o)]
        case .reasoning(let r):
            var o: [String: JSONValue] = ["text": .string(r.text)]
            if let s = r.signature, !s.isEmpty { o["provider_meta"] = ["signature": .string(s)] }
            return ["reasoning": .object(o)]
        case .toolCall(let c):
            var o: [String: JSONValue] = ["id": .string(c.id), "name": .string(c.name)]
            if let i = c.input, let v = JSONValue.parse(i) { o["input"] = v }
            return ["tool_call": .object(o)]
        case .toolResult(let r):
            var o: [String: JSONValue] = ["call_id": .string(r.callID), "content": .array(r.content.map(\.line))]
            if !r.name.isEmpty { o["name"] = .string(r.name) }
            if r.isError { o["is_error"] = true }
            return ["tool_result": .object(o)]
        }
    }

    init?(line v: JSONValue) {
        if let t = v["text"] {
            self = .text(t["text"].stringValue)
        } else if let f = v["file"] {
            self = .file(
                FilePart(
                    mediaType: f["media_type"].stringValue, data: f["data"]?.string.flatMap { Data(base64Encoded: $0) },
                    url: f["url"]?.string))
        } else if let r = v["reasoning"] {
            self = .reasoning(
                ReasoningPart(text: r["text"].stringValue, signature: r.at("provider_meta", "signature")?.string))
        } else if let c = v["tool_call"] {
            let input = c["input"].flatMap { $0.isNull ? nil : $0.jsonData }
            self = .toolCall(ToolCall(id: c["id"].stringValue, name: c["name"].stringValue, input: input))
        } else if let r = v["tool_result"] {
            self = .toolResult(
                ToolResult(
                    callID: r["call_id"].stringValue, name: r["name"].stringValue,
                    content: (r["content"]?.array ?? []).compactMap(Part.init(line:)),
                    isError: r["is_error"]?.bool ?? false
                ))
        } else {
            return nil
        }
    }
}
