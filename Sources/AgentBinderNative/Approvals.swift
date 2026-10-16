import AgentBinder
import Foundation

/// One tool call that needs a decision before it runs.
public struct ApprovalRequest: Sendable, Equatable {
    /// The id of the call.
    public var callID: String
    /// The spec of the tool.
    public var spec: ToolSpec
    /// The input as raw JSON.
    public var input: Data?

    /// Makes a request.
    public init(callID: String, spec: ToolSpec, input: Data?) {
        self.callID = callID
        self.spec = spec
        self.input = input
    }
}

/// Decides whether a tool call runs.
///
/// A custom approver replaces the permission events of the session.
public protocol Approver: Sendable {
    /// Returns the decision. A throw fails the call; a cancel gives a `cancelled` result.
    func approve(_ r: ApprovalRequest) async throws -> Decision
}

/// An approver that applies a `PermissionPolicy` and denies each call that the policy
/// does not allow.
public struct PolicyApprover: Approver {
    /// The policy.
    public var policy: PermissionPolicy

    /// Makes an approver.
    public init(policy: PermissionPolicy) { self.policy = policy }

    /// Applies the policy.
    public func approve(_ r: ApprovalRequest) async throws -> Decision {
        policy.answer(kind: r.spec.annotations.kind, tool: r.spec.name) ?? .deny("no approver configured")
    }
}

/// The approver of a session with no custom approver: the policy first, then a permission event.
struct AskingApprover: Approver {
    let policy: PermissionPolicy
    let ask: @Sendable (ApprovalRequest) async throws -> Decision

    func approve(_ r: ApprovalRequest) async throws -> Decision {
        if let d = policy.answer(kind: r.spec.annotations.kind, tool: r.spec.name) { return d }
        return try await ask(r)
    }
}

/// The open permission requests of one session. An answer resumes the waiting tool call.
final class PermissionQueue: Sendable {
    private struct State {
        var seq = 0
        var waiting: [String: CheckedContinuation<Decision, any Error>] = [:]
    }

    private let state = Locked(State())

    func nextID() -> String {
        state.withLock { s -> String in
            s.seq += 1
            return "perm-\(s.seq)"
        }
    }

    /// Waits for the answer to `id`. A cancel of the task ends the wait with a `CancellationError`.
    func wait(_ id: String) async throws -> Decision {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Decision, any Error>) in
                let cancelled = state.withLock { s -> Bool in
                    if Task.isCancelled { return true }
                    s.waiting[id] = c
                    return false
                }
                if cancelled { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            cancel(id)
        }
    }

    func answer(_ id: String, _ d: Decision) throws {
        guard let c = state.withLock({ $0.waiting.removeValue(forKey: id) }) else {
            throw AgentBinderError.invalidRequest("native: unknown or answered permission")
        }
        c.resume(returning: d)
    }

    private func cancel(_ id: String) {
        state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(throwing: CancellationError())
    }

    /// Ends each wait, for the end of a turn.
    func cancelAll() {
        let all = state.withLock { s -> [CheckedContinuation<Decision, any Error>] in
            defer { s.waiting = [:] }
            return Array(s.waiting.values)
        }
        for c in all { c.resume(throwing: CancellationError()) }
    }
}
