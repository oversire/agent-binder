import Foundation

/// A bounded event buffer between the read loop and the one consumer.
///
/// A full buffer suspends the sender, so a slow consumer slows the read loop instead of growing memory.
/// After ``beginClosing()`` a full buffer drops the event instead, so the read loop can end.
/// `.exit` always goes in.
final class EventChannel: Sendable {
    static let defaultCapacity = 256

    private struct State {
        var buffer: [Event] = []
        var head = 0
        var closing = false
        var finished = false
        var receiver: CheckedContinuation<Event?, Never>?
        var senders: [UInt64: (Event, CheckedContinuation<Void, Never>)] = [:]
        var senderOrder: [UInt64] = []
        var nextSender: UInt64 = 0

        var count: Int { buffer.count - head }

        mutating func pop() -> Event? {
            guard head < buffer.count else { return nil }
            let e = buffer[head]
            head += 1
            if head > 64 && head * 2 > buffer.count {
                buffer.removeFirst(head)
                head = 0
            }
            return e
        }
    }

    let capacity: Int
    private let state = Locked(State())

    init(capacity: Int = EventChannel.defaultCapacity) {
        self.capacity = capacity
    }

    /// Puts an event in the buffer. It waits while the buffer is full.
    func send(_ e: Event) async {
        let isExit: Bool
        if case .exit = e.kind { isExit = true } else { isExit = false }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            enum Step {
                case done
                case deliver(CheckedContinuation<Event?, Never>)
                case wait
            }
            let step = state.withLock { s -> Step in
                if s.finished { return .done }
                if let r = s.receiver {
                    s.receiver = nil
                    return .deliver(r)
                }
                if s.count < capacity || isExit {
                    s.buffer.append(e)
                    return .done
                }
                if s.closing { return .done }
                s.nextSender += 1
                s.senders[s.nextSender] = (e, cont)
                s.senderOrder.append(s.nextSender)
                return .wait
            }
            switch step {
            case .done: cont.resume()
            case .deliver(let r):
                r.resume(returning: e)
                cont.resume()
            case .wait: break
            }
        }
    }

    /// Takes the next event. It returns nil after ``finish()`` and an empty buffer, or on a task cancel.
    func receive() async -> Event? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Event?, Never>) in
                let (value, release, ready) = state.withLock {
                    s -> (Event?, CheckedContinuation<Void, Never>?, Bool) in
                    if let e = s.pop() {
                        var release: CheckedContinuation<Void, Never>?
                        if let first = s.senderOrder.first, let (pending, c) = s.senders.removeValue(forKey: first) {
                            s.senderOrder.removeFirst()
                            s.buffer.append(pending)
                            release = c
                        }
                        return (e, release, true)
                    }
                    if s.finished || Task.isCancelled { return (nil, nil, true) }
                    s.receiver = cont
                    return (nil, nil, false)
                }
                release?.resume()
                if ready { cont.resume(returning: value) }
            }
        } onCancel: {
            state.withLock { s -> CheckedContinuation<Event?, Never>? in
                defer { s.receiver = nil }
                return s.receiver
            }?.resume(returning: nil)
        }
    }

    /// Stops the wait of the senders. A full buffer then drops all events except `.exit`.
    func beginClosing() {
        let released = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.closing = true
            var out: [CheckedContinuation<Void, Never>] = []
            for k in s.senderOrder {
                guard let (e, c) = s.senders.removeValue(forKey: k) else { continue }
                if case .exit = e.kind { s.buffer.append(e) }
                out.append(c)
            }
            s.senderOrder.removeAll()
            return out
        }
        for c in released { c.resume() }
    }

    /// Ends the stream after the buffered events.
    func finish() {
        let (receiver, released) = state.withLock {
            s -> (CheckedContinuation<Event?, Never>?, [CheckedContinuation<Void, Never>]) in
            s.finished = true
            defer {
                s.receiver = nil
                s.senders.removeAll()
                s.senderOrder.removeAll()
            }
            return (s.receiver, s.senders.values.map(\.1))
        }
        receiver?.resume(returning: nil)
        for c in released { c.resume() }
    }

    /// The events in the buffer.
    var count: Int { state.withLock { $0.count } }
}
