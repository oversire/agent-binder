import Foundation

/// One vendor protocol codec. A driver owns parse and encode; ``WireSession`` owns the rest.
///
/// An adapter keeps its mutable state behind a lock, because the read loop and the callers of the
/// session use it at the same time.
protocol WireAdapter: AnyObject, Sendable {
    /// Writes the protocol start frames and returns the events that are known at once.
    /// It runs inside the session start. An error fails the start and kills the child.
    func handshake(_ w: FrameWriter) async throws -> [Event]
    /// Renders one user turn as one frame.
    func encodePrompt(_ p: Prompt) throws -> Data
    /// Maps one stdout line to zero or more events.
    func parse(_ line: Data) -> [Event]
    /// Renders the answer to a permission request.
    func encodeDecision(id: String, _ d: Decision) throws -> Data
    /// Classifies the death of the child, after stdout EOF.
    func exitEvents(code: Int32, stderr: String) -> [Event]
}

/// An adapter with a protocol interrupt frame.
protocol InterruptEncoding {
    func encodeInterrupt() throws -> Data
}

/// An adapter whose prompt is a request with a reply, for example Codex `turn/start`.
/// It owns the reply and the busy-turn fallback.
protocol RequestPrompting {
    func promptSession(_ p: Prompt) async throws
}

/// An adapter that knows when a turn runs.
protocol TurnStateReporting {
    var turnActive: Bool { get }
}

/// An adapter that can add input to the running turn.
protocol SteerSupporting {
    func steer(_ p: Prompt) async throws
}

/// An adapter whose vendor queues a second prompt during a turn.
protocol ConcurrentPrompting {
    var concurrentPrompt: Bool { get }
}
