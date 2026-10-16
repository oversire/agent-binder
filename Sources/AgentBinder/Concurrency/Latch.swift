import Foundation

/// A one-way gate. Waiters resume when it opens. It never closes again.
package final class Latch: Sendable {
    private struct State {
        var open = false
        var waiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
        var next: UInt64 = 0
    }

    private let state = Locked(State())

    package init() {}

    package var isOpen: Bool { state.withLock { $0.open } }

    /// Opens the gate. A second call does nothing.
    package func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Bool, Never>] in
            if s.open { return [] }
            s.open = true
            defer { s.waiters.removeAll() }
            return Array(s.waiters.values)
        }
        for w in waiters { w.resume(returning: true) }
    }

    /// Waits for the gate to open. It also returns when the task is cancelled.
    package func wait() async {
        _ = await wait(timeout: nil)
    }

    /// Waits up to `timeout` for the gate. It returns false on a timeout or a task cancel.
    package func wait(timeout: Duration?) async -> Bool {
        let id = Locked<UInt64?>(nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let key = state.withLock { s -> UInt64? in
                    if s.open { return nil }
                    s.next += 1
                    s.waiters[s.next] = cont
                    return s.next
                }
                guard let key else {
                    cont.resume(returning: true)
                    return
                }
                id.withLock { $0 = key }
                if Task.isCancelled { resume(key, false) }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) { [self] in
                        resume(key, false)
                    }
                }
            }
        } onCancel: {
            if let key = id.value { resume(key, false) }
        }
    }

    private func resume(_ key: UInt64, _ value: Bool) {
        state.withLock { $0.waiters.removeValue(forKey: key) }?.resume(returning: value)
    }
}
