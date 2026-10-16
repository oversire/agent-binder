import Foundation

/// The activity state of one session, from its events.
///
/// Feed each event to ``observe(_:)`` and read the ``Snapshot``. A consumer reads snapshots; it does
/// not scrape a terminal. The tracker is thread-safe.
public final class Tracker: Sendable {
    /// A turn that is active with no events and no tool in flight for this time is stalled. A stall is
    /// for observation only; it stops nothing.
    public static let stallThreshold: TimeInterval = 300

    /// The derived state of a session.
    public struct Snapshot: Sendable, Equatable {
        /// Running, waiting for an approval, or idle.
        public var state: SessionStatus
        /// A turn runs.
        public var turnActive: Bool
        /// The active turn has a tool in flight or a recent event.
        public var progressing: Bool
        /// The active turn has no tool in flight and no event for ``Tracker/stallThreshold``.
        public var stalled: Bool
        /// The time at which the stall started.
        public var stallSince: Date?
        /// The number of tools without a completion.
        public var inflightTools: Int
        /// The number of approvals without a decision.
        public var openApprovals: Int
        /// The time of the last event.
        public var lastEventAt: Date
        /// The ``Event/Kind/name`` of the last event.
        public var lastEventKind: String?
        /// The name of the last tool.
        public var lastToolName: String?
        /// The time at which the session became idle.
        public var idleSince: Date?
        /// The time at which the first open approval arrived.
        public var waitingSince: Date?
        /// The last turn result.
        public var lastResult: TurnResult?
        /// The process of the session ended.
        public var exited: Bool
        /// The time of the exit event.
        public var exitedAt: Date?
    }

    private struct State {
        var lastEventAt: Date
        var turnActive = false
        var inflight: [String: Date] = [:]
        var openApprovals: [String: Date] = [:]
        var lastResult: TurnResult?
        var idleSince: Date?
        var waitingSince: Date?
        var stallSince: Date?
        var lastEventKind: String?
        var lastToolName: String?
        var exited = false
        var autoSeq = 0
        var pendingAuto: [String] = []
    }

    private let state: Locked<State>
    private let now: @Sendable () -> Date

    /// Makes an idle tracker. Tests inject `now`.
    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        state = Locked(State(lastEventAt: now()))
    }

    /// Marks the turn as running when a prompt is written: model latency is not idleness.
    public func promptWritten() {
        let t = now()
        state.withLock { s in
            s.turnActive = true
            s.lastEventAt = t
            s.lastResult = nil
            s.idleSince = nil
            s.stallSince = nil
        }
    }

    /// Adds one event and returns the new state.
    @discardableResult
    public func observe(_ e: Event) -> Snapshot {
        let t = now()
        return state.withLock { s in
            s.lastEventAt = e.at
            s.lastEventKind = e.kind.name
            switch e.kind {
            case .assistant, .thought, .user, .usage, .status:
                s.stallSince = nil
            case .permission(let p):
                s.openApprovals[p.id] = t
                s.waitingSince = t
            case .tool(let tool):
                Self.observeTool(&s, tool, t)
            case .result(let r):
                s.turnActive = false
                s.stallSince = nil
                // The turn is over, so no tool can still run. A leaked id must not hold the stall off.
                s.inflight = [:]
                s.pendingAuto = []
                s.lastResult = r
                s.idleSince = t
            case .exit:
                s.exited = true
                s.turnActive = false
                s.inflight = [:]
                s.pendingAuto = []
                s.idleSince = t
            case .error:
                // A classified failure ends the turn.
                s.turnActive = false
            case .initialized, .limits:
                break
            }
            return Self.snapshot(&s, t)
        }
    }

    /// Clears an open approval. An empty id clears the oldest one.
    @discardableResult
    public func permissionDecided(id: String) -> Snapshot {
        let t = now()
        return state.withLock { s in
            if id.isEmpty {
                if let oldest = s.openApprovals.min(by: { $0.value < $1.value })?.key {
                    s.openApprovals[oldest] = nil
                }
            } else {
                s.openApprovals[id] = nil
            }
            if s.openApprovals.isEmpty { s.waitingSince = nil }
            return Self.snapshot(&s, t)
        }
    }

    /// Adds an approval that the wire did not open, for example from a hook.
    @discardableResult
    public func permissionAdded(id: String) -> Snapshot {
        let t = now()
        return state.withLock { s in
            s.openApprovals[id] = t
            s.waitingSince = t
            return Self.snapshot(&s, t)
        }
    }

    /// The oldest open approval id. An approval without a wire id does not count.
    public var oldestApprovalID: String? {
        state.withLock { s in s.openApprovals.filter { !$0.key.isEmpty }.min(by: { $0.value < $1.value })?.key }
    }

    /// The number of tools without a completion.
    public var inflightCount: Int { state.withLock { $0.inflight.count } }

    /// The current state.
    public var snapshot: Snapshot {
        let t = now()
        return state.withLock { Self.snapshot(&$0, t) }
    }

    // A tool with no wire id gets its own id, so a second tool without an id cannot replace it.
    private static func observeTool(_ s: inout State, _ tool: ToolEvent, _ t: Date) {
        s.lastToolName = tool.name
        var id = tool.id
        switch tool.status {
        case .completed, .failed, .cancelled:
            if id.isEmpty {
                if s.pendingAuto.isEmpty {
                    // A completion with no start gets its own slot, so it cannot clear a named tool.
                    s.autoSeq += 1
                    id = "auto-\(s.autoSeq)"
                } else {
                    id = s.pendingAuto.removeFirst()
                }
            }
            s.inflight[id] = nil
        case .started:
            if id.isEmpty {
                s.autoSeq += 1
                id = "auto-\(s.autoSeq)"
                s.pendingAuto.append(id)
            }
            s.inflight[id] = t
        }
    }

    private static func snapshot(_ s: inout State, _ t: Date) -> Snapshot {
        let state: SessionStatus = !s.openApprovals.isEmpty ? .waiting : (s.turnActive ? .running : .idle)
        var snap = Snapshot(
            state: state, turnActive: s.turnActive, progressing: false, stalled: false, stallSince: nil,
            inflightTools: s.inflight.count, openApprovals: s.openApprovals.count, lastEventAt: s.lastEventAt,
            lastEventKind: s.lastEventKind, lastToolName: s.lastToolName, idleSince: s.idleSince,
            waitingSince: s.waitingSince, lastResult: s.lastResult, exited: s.exited,
            exitedAt: s.exited ? s.lastEventAt : nil)
        if s.turnActive {
            if !s.inflight.isEmpty || t.timeIntervalSince(s.lastEventAt) < stallThreshold {
                snap.progressing = true
                if !s.inflight.isEmpty { s.stallSince = nil }
            } else {
                if s.stallSince == nil { s.stallSince = s.lastEventAt.addingTimeInterval(stallThreshold) }
                snap.stalled = true
                snap.stallSince = s.stallSince
            }
        }
        if state == .idle && s.idleSince == nil { snap.idleSince = s.lastEventAt }
        return snap
    }
}
