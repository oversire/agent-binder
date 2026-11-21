import Foundation

/// Runs work with a time limit.
enum Deadline {
    /// Returns the result of `body`, or throws `onTimeout` when `limit` passes first.
    ///
    /// It does not wait for a `body` that ignores cancellation, so a stuck peer cannot block the caller.
    static func run<T: Sendable>(
        _ limit: Duration, onTimeout: any Error, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let slot = Locked<CheckedContinuation<T, any Error>?>(nil)
        let work = Locked<Task<Void, Never>?>(nil)
        @Sendable func finish(_ r: Result<T, any Error>) {
            let c = slot.withLock { s -> CheckedContinuation<T, any Error>? in
                defer { s = nil }
                return s
            }
            c?.resume(with: r)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
                slot.withLock { $0 = cont }
                let t = Task {
                    do { finish(.success(try await body())) } catch { finish(.failure(error)) }
                    work.withLock { $0 = nil }
                }
                // A body that already finished must not leave its task in the box.
                work.withLock { if slot.value != nil { $0 = t } }
                // The timer takes the task out of the box. A finished task is not kept until the limit.
                DispatchQueue.global().asyncAfter(deadline: .now() + limit.timeInterval) {
                    let t = work.withLock { s -> Task<Void, Never>? in
                        defer { s = nil }
                        return s
                    }
                    finish(.failure(onTimeout))
                    t?.cancel()
                }
            }
        } onCancel: {
            work.value?.cancel()
            finish(.failure(CancellationError()))
        }
    }
}
