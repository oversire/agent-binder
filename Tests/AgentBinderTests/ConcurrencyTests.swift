import Foundation
import Testing

@testable import AgentBinder

private final class Payload: Sendable {}

/// A weak reference that a polling closure can capture.
final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T? = nil) { self.value = value }
}

@Suite("LatchTests")
struct LatchTests {
    @Test func releasedBeforeTheTimeout() async throws {
        let weak = WeakBox<Latch>()
        do {
            let latch = Latch()
            weak.value = latch
            let waiter = Task { await latch.wait(timeout: .seconds(30)) }
            try await Task.sleep(for: .milliseconds(50))
            latch.open()
            #expect(await waiter.value)
        }
        try await eventually(timeout: .seconds(1)) { weak.value == nil }
    }
}

@Suite("DeadlineTests")
struct DeadlineTests {
    @Test func resultIsReleasedBeforeTheLimit() async throws {
        let weak = WeakBox<Payload>()
        do {
            let r = try await Deadline.run(.seconds(30), onTimeout: AgentBinderError.sessionClosed) { Payload() }
            weak.value = r
        }
        try await eventually(timeout: .seconds(1)) { weak.value == nil }
    }
}
