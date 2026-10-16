import Foundation

/// The prompts that wait for the running turn to end.
final class Outbox: Sendable {
    /// The error code of held prompts that the session dropped.
    static let droppedCode = "held_prompt_dropped"

    /// The session calls that one ``send(_:_:)`` uses.
    struct Ops: Sendable {
        var active: @Sendable () -> Bool
        var prompt: @Sendable (Prompt) async throws -> Void
        /// Nil when the session cannot steer.
        var steer: (@Sendable (Prompt) async throws -> Void)?
        /// True when a prompt is safe during a turn.
        var concurrent: Bool
    }

    private struct State {
        var held: [Prompt] = []
        var flushing = false
    }

    private let state = Locked(State())

    init() {}

    /// Steers the running turn, else prompts, else holds the prompt until the turn ends.
    func send(_ ops: Ops, _ p: Prompt) async throws -> Delivery {
        if ops.active() {
            if let steer = ops.steer {
                do {
                    try await steer(p)
                    return .steered
                } catch AgentBinderError.unsupported {
                    return try await hold(ops, p)
                } catch AgentBinderError.noActiveTurn {
                    // The turn ended in between: prompt or hold below.
                }
            } else if ops.concurrent {
                try await ops.prompt(p)
                return .prompted
            }
        }
        return try await hold(ops, p)
    }

    // Holds the prompt while a turn runs or a flush is in progress. Else it prompts.
    private func hold(_ ops: Ops, _ p: Prompt) async throws -> Delivery {
        let held = state.withLock { s -> Bool in
            if !s.flushing && !ops.active() { return false }
            s.held.append(p)
            return true
        }
        if held { return .held }
        try await ops.prompt(p)
        return .prompted
    }

    /// True when prompts wait for the turn to end.
    var pending: Bool { state.withLock { !$0.held.isEmpty } }

    /// Sends the held prompts as one followup turn. It returns the prompts that it could not send.
    func flush(_ prompt: @Sendable (Prompt) async throws -> Void) async -> [Prompt] {
        let held = state.withLock { s -> [Prompt] in
            defer {
                s.flushing = !s.held.isEmpty
                s.held = []
            }
            return s.held
        }
        guard !held.isEmpty else { return [] }
        let failed: Bool
        do {
            try await prompt(Outbox.join(held))
            failed = false
        } catch {
            failed = true
        }
        state.withLock { $0.flushing = false }
        return failed ? held : []
    }

    /// Empties the queue and returns what it held.
    func drop() -> [Prompt] {
        state.withLock { s in
            defer { s.held = [] }
            return s.held
        }
    }

    /// Joins held prompts with a blank line into one followup prompt.
    static func join(_ held: [Prompt]) -> Prompt {
        Prompt(held.map(\.text).joined(separator: "\n\n"), kind: "followup", attachments: held.flatMap(\.attachments))
    }

    /// The error of held prompts that never reached the vendor.
    static func droppedError(_ held: [Prompt]) -> WireError {
        WireError(
            message: "the session ended before a held prompt was sent", code: droppedCode,
            text: held.map(\.text).joined(separator: "\n\n"))
    }
}
