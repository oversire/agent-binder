import Foundation

/// The command channel of `pi --mode rpc`. Each command has an `aw-<n>` id, and pi answers with a
/// `response` frame that has the same id.
final class PiCommands: Sendable {
    static let replyWait: Duration = .seconds(10)

    private struct State {
        var writer: FrameWriter?
        var next = 0
    }

    private let state = Locked(State())
    private let replies = ReplyTable<JSONValue>()

    func attach(_ w: FrameWriter) { state.withLock { $0.writer = w } }

    var writer: FrameWriter? { state.value.writer }

    /// A fresh id. The prompt frame takes one too, so its ack is not mistaken for a command reply.
    func nextID() -> String {
        state.withLock { s in
            s.next += 1
            return "aw-\(s.next)"
        }
    }

    /// Sends a command and waits for its response. It returns the `data` of a success.
    @discardableResult
    func request(_ command: [String: JSONValue], timeout: Duration = replyWait) async throws -> JSONValue {
        let type = command["type"].stringValue
        let id = nextID()
        try replies.register(id)
        guard let w = writer else {
            replies.remove(id)
            throw AgentBinderError.sessionClosed
        }
        replies.expire(id, after: timeout, with: AgentBinderError.timeout("pi \(type)"))
        var frame = command
        frame["id"] = .string(id)
        do {
            try await w.write(.object(frame))
        } catch {
            replies.remove(id)
            throw error
        }
        return try await replies.wait(id).get()
    }

    /// Gives a `response` frame to its caller. It returns false when no caller waits for the id.
    @discardableResult
    func deliver(_ m: JSONValue) -> Bool {
        let id = m["id"].stringValue
        guard !id.isEmpty else { return false }
        return replies.resolve(id, Self.reply(m))
    }

    /// The data of a success, or the error of a `success: false` response.
    static func reply(_ m: JSONValue) -> Result<JSONValue, any Error> {
        if m["success"]?.bool == true { return .success(m["data"] ?? .null) }
        let text = m["error"].stringValue
        return .failure(
            AgentBinderError.vendor(
                code: 0, message: "pi \(m["command"].stringValue): \(text.isEmpty ? "failed" : text)"))
    }

    /// Stops the channel. Each waiting caller and each later call throws `error`.
    func failAll(_ error: any Error = AgentBinderError.sessionClosed) {
        replies.failAll(error)
    }
}
