import Foundation
import Testing

@testable import AgentBinder

private struct Boom: Error, Equatable {}
private struct Other: Error, Equatable {}
private struct Late: Error, Equatable {}

@Suite("ReplyTableTests")
struct ReplyTableTests {
    @Test func resolveBeforeWait() async throws {
        let t = ReplyTable<Int>()
        try t.register("a")
        #expect(t.resolve("a", .success(1)))
        #expect(try await t.wait("a").get() == 1)
        #expect(t.count == 0)
    }

    @Test func resolveWakesTheWaiter() async throws {
        let t = ReplyTable<Int>()
        try t.register("a")
        let w = Task { try await t.wait("a").get() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(t.resolve("a", .success(7)))
        #expect(try await w.value == 7)
        #expect(!t.resolve("a", .success(8)))
    }

    @Test func firstOutcomeWins() async throws {
        let t = ReplyTable<Int>()
        try t.register("a")
        t.expire("a", after: .milliseconds(10), with: Late())
        let r = await t.wait("a")
        #expect(throws: Late.self) { try r.get() }
        #expect(!t.resolve("a", .success(1)))
    }

    @Test func cancelResolvesWithCancellationError() async throws {
        let t = ReplyTable<Int>()
        try t.register("a")
        let w = Task { await t.wait("a") }
        try await Task.sleep(for: .milliseconds(30))
        w.cancel()
        let r = await w.value
        #expect(throws: CancellationError.self) { try r.get() }
        #expect(t.count == 0)
    }

    @Test func failAllReleasesAndBlocks() async throws {
        let t = ReplyTable<Int>()
        try t.register("a")
        try t.register("b")
        try t.register("c")
        let a = Task { await t.wait("a") }
        let b = Task { await t.wait("b") }
        try await Task.sleep(for: .milliseconds(30))
        t.failAll(Boom())
        for task in [a, b] {
            let r = await task.value
            #expect(throws: Boom.self) { try r.get() }
        }
        let c = await t.wait("c")
        #expect(throws: Boom.self) { try c.get() }
        #expect(throws: Boom.self) { try t.register("d") }
        t.failAll(Other())
        #expect(t.dead is Boom)
    }

    @Test func missingSlotIsClosed() async {
        let t = ReplyTable<Int>()
        let r = await t.wait("none")
        #expect(throws: AgentBinderError.sessionClosed) { try r.get() }
    }

    @Test func tableIsReleasedBeforeTheTimer() async throws {
        let weak = WeakBox<ReplyTable<Int>>()
        do {
            let t = ReplyTable<Int>()
            weak.value = t
            try t.register("a")
            t.expire("a", after: .seconds(30), with: Late())
            t.resolve("a", .success(1))
        }
        try await eventually(timeout: .seconds(1)) { weak.value == nil }
    }
}
