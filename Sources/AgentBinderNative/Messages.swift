import Foundation

/// The author of one message in the history.
public enum Role: String, Sendable, Codable {
    /// The user, or the session on behalf of the user.
    case user
    /// The model.
    case assistant
    /// The results of tool calls.
    case tool
}

/// One message of the history that goes to the model.
public struct Message: Sendable, Equatable {
    /// The author.
    public var role: Role
    /// The content, in order.
    public var parts: [Part]

    /// Makes a message.
    public init(role: Role, parts: [Part]) {
        self.role = role
        self.parts = parts
    }

    /// A user message with one text part.
    public static func user(_ text: String) -> Message { Message(role: .user, parts: [.text(text)]) }
}

/// One piece of a message.
public enum Part: Sendable, Equatable {
    /// Text.
    case text(String)
    /// An image or a document.
    case file(FilePart)
    /// Model reasoning. The provider can need it again on the next call.
    case reasoning(ReasoningPart)
    /// A tool call of the model.
    case toolCall(ToolCall)
    /// The result of a tool call.
    case toolResult(ToolResult)
}

/// An image or a document in a message. Exactly one of ``data`` and ``url`` is set.
public struct FilePart: Sendable, Equatable {
    /// The media type, for example `"image/png"`.
    public var mediaType: String
    /// The bytes.
    public var data: Data?
    /// A URL that the provider reads.
    public var url: String?

    /// Makes a file part.
    public init(mediaType: String, data: Data? = nil, url: String? = nil) {
        self.mediaType = mediaType
        self.data = data
        self.url = url
    }
}

/// Model reasoning with the provider signature that proves it.
public struct ReasoningPart: Sendable, Equatable {
    /// The reasoning text.
    public var text: String
    /// The provider signature. Anthropic needs it on a later call that has tool results.
    public var signature: String?

    /// Makes a reasoning part.
    public init(text: String, signature: String? = nil) {
        self.text = text
        self.signature = signature
    }
}

/// A tool call of the model.
public struct ToolCall: Sendable, Equatable {
    /// The provider call id.
    public var id: String
    /// The tool name.
    public var name: String
    /// The input as raw JSON. Nil means an empty object.
    public var input: Data?

    /// Makes a tool call.
    public init(id: String, name: String, input: Data? = nil) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// The result of one tool call.
public struct ToolResult: Sendable, Equatable {
    /// The id of the call.
    public var callID: String
    /// The tool name.
    public var name: String
    /// The content, usually text parts.
    public var content: [Part]
    /// True when the tool failed. The model sees the content.
    public var isError: Bool

    /// Makes a tool result.
    public init(callID: String = "", name: String = "", content: [Part], isError: Bool = false) {
        self.callID = callID
        self.name = name
        self.content = content
        self.isError = isError
    }

    /// A result with one text part.
    public static func text(_ text: String, isError: Bool = false) -> ToolResult {
        ToolResult(content: [.text(text)], isError: isError)
    }
}

extension Message {
    /// The text of the message for a summary: each part gives one piece, and the pieces are joined with spaces.
    var flatText: String {
        parts.map(\.flatText).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension Part {
    var flatText: String {
        switch self {
        case .text(let t): return t
        case .toolCall(let c):
            return "[tool call \(c.name)(\(Self.cut(String(decoding: c.input ?? Data(), as: UTF8.self), 200)))]"
        case .toolResult(let r):
            let texts = r.content.compactMap { p -> String? in
                if case .text(let t) = p { return t }
                return nil
            }
            return "[tool \(r.name) -> \(Self.cut(texts.joined(separator: " "), 300))]"
        case .reasoning, .file: return ""
        }
    }

    /// Cuts on a UTF-8 boundary and adds an ellipsis only when it cuts.
    static func cut(_ s: String, _ maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var end = s.utf8.index(s.utf8.startIndex, offsetBy: maxBytes)
        while String.Index(end, within: s) == nil { end = s.utf8.index(before: end) }
        return String(s[..<end]) + "…"
    }
}

extension [Part] {
    /// The text parts, joined with a newline.
    var text: String {
        compactMap { p -> String? in
            if case .text(let t) = p { return t }
            return nil
        }.joined(separator: "\n")
    }
}
