import Foundation

/// Makes a long history shorter before a model call.
public protocol Compactor: Sendable {
    /// Returns the new history. The model can write a summary.
    func compact(model: any Model, messages: [Message]) async throws -> [Message]
}

/// A compactor that folds the older messages into one summary message and keeps the last messages.
public struct SummaryCompactor: Compactor {
    /// The number of messages that stay as they are. The minimum is 1.
    public let keepLast: Int

    /// Makes a compactor.
    public init(keepLast: Int) { self.keepLast = max(1, keepLast) }

    /// Folds the head of the history into a summary.
    public func compact(model: any Model, messages: [Message]) async throws -> [Message] {
        guard messages.count > keepLast + 1 else { return messages }
        var cut = messages.count - keepLast
        // Fixed on purpose: a tail that starts with a tool result has no tool call, and the providers refuse it.
        while cut > 0 && messages[cut].role == .tool { cut -= 1 }
        guard cut > 0 else { return messages }
        let head = messages[..<cut]
        var text =
            "Summarize the conversation so far for a continuation. Keep the task, the decisions, the file paths, and the open questions. Be brief.\n\n"
        text += head.map { "\($0.role.rawValue): \($0.flatText)" }.joined(separator: "\n")
        var summary = ""
        do {
            for try await p in model.stream(ModelRequest(messages: [.user(text)])) {
                switch p {
                case .textDelta(let t): summary += t
                case .toolCallDone: throw NativeError("compaction_failed", "native: compaction summary called a tool")
                default: break
                }
            }
        } catch let e as NativeError {
            throw e
        } catch {
            throw NativeError("compaction_failed", "native: compaction summary: \(error)")
        }
        return [.user("Summary of the earlier conversation:\n" + summary)] + messages[cut...]
    }
}

extension [Message] {
    /// A rough token count: a quarter of the UTF-8 bytes of the text. Files do not count.
    var tokenEstimate: Int {
        var bytes = 0
        for m in self {
            for p in m.parts {
                switch p {
                case .text(let t): bytes += t.utf8.count
                case .reasoning(let r): bytes += r.text.utf8.count
                case .toolCall(let c): bytes += c.input?.count ?? 0
                case .toolResult(let r): bytes += r.content.map(\.flatText).joined(separator: " ").utf8.count
                case .file: break
                }
            }
        }
        return bytes / 4
    }
}
