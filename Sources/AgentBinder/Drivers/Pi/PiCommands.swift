import Foundation

/// The command channel of `pi --mode rpc`. Each command has an `aw-<n>` id, and pi answers with a
/// `response` frame that has the same id.
final class PiCommands: Sendable {
    static let replyWait: Duration = .seconds(10)

    private typealias Reply = Result<JSONValue, any Error>

    private enum Slot {
        case registered
        case waiting(CheckedContinuation<Reply, Never>)
        case done(Reply)
    }

    private struct State {
        var writer: FrameWriter?
        var next = 0
        var slots: [String: Slot] = [:]
        var dead: (any Error)?
    }

    private let state = Locked(State())

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
        let w = try state.withLock { s -> FrameWriter in
            if let d = s.dead { throw d }
            guard let w = s.writer else { throw AgentBinderError.sessionClosed }
            s.slots[id] = .registered
            return w
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) { [self] in
            resume(id, .failure(AgentBinderError.timeout("pi \(type)")))
        }
        var frame = command
        frame["id"] = .string(id)
        do {
            try await w.write(.object(frame))
        } catch {
            _ = state.withLock { $0.slots.removeValue(forKey: id) }
            throw error
        }
        let reply: Reply = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Reply, Never>) in
                let ready = state.withLock { s -> Reply? in
                    switch s.slots[id] {
                    case .done(let r):
                        s.slots[id] = nil
                        return r
                    case .registered:
                        s.slots[id] = .waiting(cont)
                        return nil
                    case .waiting, nil:
                        return .failure(s.dead ?? AgentBinderError.sessionClosed)
                    }
                }
                if let ready { cont.resume(returning: ready) }
            }
        } onCancel: {
            resume(id, .failure(CancellationError()))
        }
        return try reply.get()
    }

    /// Gives a `response` frame to its caller. It returns false when no caller waits for the id.
    @discardableResult
    func deliver(_ m: JSONValue) -> Bool {
        let id = m["id"].stringValue
        guard !id.isEmpty else { return false }
        return resume(id, Self.reply(m))
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
        let waiters = state.withLock { s -> [CheckedContinuation<Reply, Never>] in
            if s.dead == nil { s.dead = error }
            var out: [CheckedContinuation<Reply, Never>] = []
            for (k, slot) in s.slots {
                if case .waiting(let c) = slot { out.append(c) }
                s.slots[k] = nil
            }
            return out
        }
        for w in waiters { w.resume(returning: .failure(error)) }
    }

    @discardableResult
    private func resume(_ id: String, _ r: Reply) -> Bool {
        let (c, hit) = state.withLock { s -> (CheckedContinuation<Reply, Never>?, Bool) in
            switch s.slots[id] {
            case .registered:
                s.slots[id] = .done(r)
                return (nil, true)
            case .waiting(let c):
                s.slots[id] = nil
                return (c, true)
            case .done, nil:
                return (nil, false)
            }
        }
        c?.resume(returning: r)
        return hit
    }
}
