import Foundation

/// One user turn for a live session.
public struct Prompt: Sendable, Equatable {
    /// The text of the turn.
    public var text: String
    /// The origin of the turn, for consumer logs. The library does not read it.
    public var kind: String?
    /// Images or files for the turn. The library sends images before text.
    public var attachments: [PromptAttachment]

    /// Makes a prompt.
    public init(_ text: String, kind: String? = nil, attachments: [PromptAttachment] = []) {
        self.text = text
        self.kind = kind
        self.attachments = attachments
    }
}

/// One image or file that goes with a prompt.
public struct PromptAttachment: Sendable, Equatable {
    /// The media type, for example `"image/png"`. Nil uses the file extension.
    public var mime: String?
    /// The bytes or the file.
    public var source: Source

    /// Makes an attachment.
    public init(mime: String? = nil, source: Source) {
        self.mime = mime
        self.source = source
    }

    /// An attachment from a file.
    public static func file(_ url: URL, mime: String? = nil) -> PromptAttachment {
        PromptAttachment(mime: mime, source: .file(url))
    }

    /// An attachment from bytes.
    public static func data(_ data: Data, mime: String) -> PromptAttachment {
        PromptAttachment(mime: mime, source: .data(data))
    }

    /// Where the bytes of an attachment come from.
    public enum Source: Sendable, Equatable {
        /// A file on disk. The library reads it.
        case file(URL)
        /// The bytes themselves.
        case data(Data)
    }
}
