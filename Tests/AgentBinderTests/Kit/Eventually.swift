import Foundation
import Testing

struct TimeoutError: Error, CustomStringConvertible {
    var description: String
}

/// Polls `condition` until it is true, or fails after `timeout`.
func eventually(
    timeout: Duration = .seconds(5), interval: Duration = .milliseconds(20),
    _ sourceLocation: SourceLocation = #_sourceLocation, _ condition: @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: interval)
    }
    if try await condition() { return }
    Issue.record("condition not met in \(timeout)", sourceLocation: sourceLocation)
    throw TimeoutError(description: "condition not met in \(timeout)")
}

/// Runs `body` with a time limit.
func withTimeout<T: Sendable>(
    _ timeout: Duration = .seconds(10), _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError(description: "timeout after \(timeout)")
        }
        let v = try await group.next()!
        group.cancelAll()
        return v
    }
}
