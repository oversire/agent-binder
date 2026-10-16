import Foundation
import Testing

@testable import AgentBinder

@Suite("TrackerTests")
struct TrackerTests {
    let clock = TestClock()
    var tracker: Tracker { Tracker(now: clock.now) }

    private func tool(_ id: String, _ name: String, _ status: ToolStatus, at: Date? = nil) -> Event {
        Event(.tool(ToolEvent(id: id, name: name, status: status)), at: at ?? clock.now())
    }

    private func event(_ k: Event.Kind) -> Event { Event(k, at: clock.now()) }

    @Test func idleThenRunningThenExit() {
        let t = tracker
        #expect(t.snapshot.state == .idle)
        t.promptWritten()
        #expect(t.snapshot.state == .running && t.snapshot.turnActive)
        var s = t.observe(event(.assistant(text: "working", delta: false)))
        #expect(s.state == .running && s.progressing && !s.stalled)
        #expect(s.lastEventKind == "assistant")
        s = t.observe(event(.exit(code: 0, error: nil, errorCode: nil)))
        #expect(s.exited)
        #expect(s.exitedAt != nil)
        #expect(s.state == .idle && !s.turnActive)
    }

    @Test func unnamedToolsKeepSeparateSlots() {
        let t = tracker
        t.promptWritten()
        t.observe(tool("", "read", .started))
        t.observe(tool("", "grep", .started))
        #expect(t.inflightCount == 2)
        let s = t.observe(tool("", "read", .completed))
        #expect(s.inflightTools == 1 && s.progressing)
        t.observe(tool("t1", "Bash", .started))
        #expect(t.inflightCount == 2)
        t.observe(tool("t1", "Bash", .completed))
        #expect(t.inflightCount == 1)
        t.observe(tool("", "grep", .completed))
        #expect(t.inflightCount == 0)
        #expect(t.snapshot.lastToolName == "grep")
    }

    @Test func stallBoundary() {
        let t = tracker
        t.promptWritten()
        let stale = clock.now().addingTimeInterval(-2 * Tracker.stallThreshold)
        let s = t.observe(Event(.assistant(text: "slow", delta: false), at: stale))
        #expect(s.stalled && !s.progressing)
        #expect(s.stallSince == stale.addingTimeInterval(Tracker.stallThreshold))
        let again = t.snapshot
        #expect(again.stalled && again.stallSince == s.stallSince)
    }

    @Test func stallStartsAtTheThreshold() {
        let t = tracker
        t.promptWritten()
        clock.advance(Tracker.stallThreshold - 1)
        #expect(!t.snapshot.stalled)
        clock.advance(1)
        #expect(t.snapshot.stalled)
    }

    @Test func inflightToolSuppressesTheStall() {
        let t = tracker
        t.promptWritten()
        let stale = clock.now().addingTimeInterval(-2 * Tracker.stallThreshold)
        t.observe(tool("t1", "Bash", .started, at: stale))
        #expect(!t.snapshot.stalled && t.snapshot.progressing)
        var s = t.observe(tool("t1", "Bash", .completed, at: stale))
        #expect(s.inflightTools == 0 && s.stalled)
        s = t.observe(event(.usage(Usage(input: 10))))
        #expect(!s.stalled && s.progressing)
    }

    @Test func permissionLifecycle() {
        let t = tracker
        t.promptWritten()
        var s = t.observe(event(.permission(PermissionRequest(id: "p1", tool: "Bash"))))
        #expect(s.state == .waiting && s.openApprovals == 1)
        #expect(s.waitingSince != nil)
        #expect(t.oldestApprovalID == "p1")
        s = t.permissionDecided(id: "p1")
        #expect(s.state == .running && s.openApprovals == 0)
        #expect(s.waitingSince == nil)
    }

    @Test func emptyDecisionClearsTheOldest() {
        let t = tracker
        t.promptWritten()
        t.observe(event(.permission(PermissionRequest(id: "p1"))))
        clock.advance(1)
        t.observe(event(.permission(PermissionRequest(id: "p2"))))
        #expect(t.permissionDecided(id: "").openApprovals == 1)
        #expect(t.oldestApprovalID == "p2")
    }

    @Test func addedApproval() {
        let t = tracker
        t.promptWritten()
        t.observe(event(.permission(PermissionRequest(id: "wire-1"))))
        t.permissionAdded(id: "hook-1")
        #expect(t.snapshot.openApprovals == 2)
        var s = t.permissionDecided(id: "wire-1")
        #expect(s.openApprovals == 1 && s.state == .waiting)
        s = t.permissionDecided(id: "hook-1")
        #expect(s.openApprovals == 0 && s.state == .running)
    }

    @Test func resultAndExitClearInflight() {
        let t = tracker
        t.promptWritten()
        t.observe(tool("ok", "Bash", .started))
        t.observe(tool("phantom", "mcp__x__job", .started))
        t.observe(tool("ok", "Bash", .completed))
        #expect(t.inflightCount == 1)
        let s = t.observe(event(.result(TurnResult())))
        #expect(s.inflightTools == 0 && !s.progressing && !s.stalled)
        #expect(s.lastResult == TurnResult())
        #expect(s.idleSince != nil)

        let t2 = tracker
        t2.promptWritten()
        t2.observe(tool("x", "Bash", .started))
        let e = t2.observe(event(.exit(code: 1, error: "boom", errorCode: "process_exited")))
        #expect(e.inflightTools == 0 && !e.turnActive)
    }

    @Test func errorEndsTheTurn() {
        let t = tracker
        t.promptWritten()
        let s = t.observe(event(.error(WireError(message: "x", code: "rate_limited"))))
        #expect(!s.turnActive && s.state == .idle)
    }
}
