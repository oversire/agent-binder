import Foundation

/// Matches replies to callers that wait for them. The first outcome of a key wins.
///
/// A caller does `register`, then optionally `expire`, then writes its frame, then `wait`. A reply
/// that comes before `wait` stays in its slot.
final class ReplyTable<Value: Sendable>: Sendable {
    typealias Reply = Result<Value, any Error>

    private enum Slot {
        case registered
        case waiting(CheckedContinuation<Reply, Never>)
        case done(Reply)
    }

    private struct State {
        var slots: [String: Slot] = [:]
        var dead: (any Error)?
    }

    private let state = Locked(State())

    /// The number of slots.
    var count: Int { state.withLock { $0.slots.count } }

    /// The error of the first ``failAll(_:)``.
    var dead: (any Error)? { state.withLock { $0.dead } }

    /// Adds a slot for `key`. It throws the dead error after ``failAll(_:)``.
    func register(_ key: String) throws {
        try state.withLock { s in
            if let d = s.dead { throw d }
            s.slots[key] = .registered
        }
    }

    /// Fails `key` with `error` after `limit`. A zero or negative limit does nothing.
    /// The timer does not keep the table alive.
    func expire(_ key: String, after limit: Duration, with error: any Error) {
        guard limit > .zero else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit.timeInterval) { [weak self] in
            self?.resolve(key, .failure(error))
        }
    }

    /// Waits for the reply of `key`. A task cancel gives a `CancellationError` reply.
    func wait(_ key: String) async -> Reply {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Reply, Never>) in
                let ready = state.withLock { s -> Reply? in
                    switch s.slots[key] {
                    case .done(let r):
                        s.slots[key] = nil
                        return r
                    case .registered:
                        s.slots[key] = .waiting(cont)
                        return nil
                    case .waiting, nil:
                        return .failure(s.dead ?? AgentBinderError.sessionClosed)
                    }
                }
                if let ready { cont.resume(returning: ready) }
            }
        } onCancel: {
            resolve(key, .failure(CancellationError()))
        }
    }

    /// Gives a reply to `key`. It returns false when the slot is missing or has an outcome already.
    @discardableResult
    func resolve(_ key: String, _ r: Reply) -> Bool {
        let (found, cont) = state.withLock { s -> (Bool, CheckedContinuation<Reply, Never>?) in
            switch s.slots[key] {
            case .registered:
                s.slots[key] = .done(r)
                return (true, nil)
            case .waiting(let c):
                s.slots[key] = nil
                return (true, c)
            case .done, nil:
                return (false, nil)
            }
        }
        cont?.resume(returning: r)
        return found
    }

    /// Drops the slot of `key`.
    func remove(_ key: String) {
        _ = state.withLock { $0.slots.removeValue(forKey: key) }
    }

    /// Stops the table. Each waiter and each later `register` gets the first error.
    func failAll(_ error: any Error) {
        let (waiters, dead) = state.withLock { s -> ([CheckedContinuation<Reply, Never>], any Error) in
            if s.dead == nil { s.dead = error }
            let dead = s.dead!
            var out: [CheckedContinuation<Reply, Never>] = []
            for (k, slot) in s.slots {
                if case .waiting(let c) = slot {
                    out.append(c)
                    s.slots[k] = nil
                } else {
                    s.slots[k] = .done(.failure(dead))
                }
            }
            return (out, dead)
        }
        for w in waiters { w.resume(returning: .failure(dead)) }
    }
}
