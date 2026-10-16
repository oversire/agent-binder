import Foundation

/// The bytes and the media type of one attachment.
struct LoadedAttachment: Sendable, Equatable {
    var data: Data
    var mime: String

    var isImage: Bool { mime.hasPrefix("image/") }
    var base64: String { data.base64EncodedString() }
}

extension PromptAttachment {
    /// The explicit media type, else the type of the file extension.
    var resolvedMIME: String? {
        if let mime, !mime.isEmpty { return mime }
        if case .file(let url) = source { return PromptAttachment.mime(forExtension: url.pathExtension) }
        return nil
    }

    var isImage: Bool { resolvedMIME?.hasPrefix("image/") ?? false }

    /// Reads the bytes. A type that is not known is `application/octet-stream`.
    func load() throws -> LoadedAttachment {
        let data: Data
        switch source {
        case .data(let d): data = d
        case .file(let url):
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw AgentBinderError.invalidRequest("attachment \(url.path): \(error.localizedDescription)")
            }
        }
        guard !data.isEmpty else { throw AgentBinderError.invalidRequest("attachment with no data") }
        return LoadedAttachment(data: data, mime: resolvedMIME ?? "application/octet-stream")
    }

    /// The images first, so a vendor that takes an image only before text gets a valid prompt.
    /// Each group keeps its order.
    static func sorted(_ items: [PromptAttachment]) -> [PromptAttachment] {
        items.filter(\.isImage) + items.filter { !$0.isImage }
    }

    static func mime(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "txt", "md", "log": return "text/plain"
        case "json": return "application/json"
        default: return nil
        }
    }
}
