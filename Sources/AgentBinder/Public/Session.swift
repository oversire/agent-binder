import Foundation

/// One vendor conversation.
///
/// Read ``events`` with one consumer. The stream ends after ``Event/Kind/exit(code:error:errorCode:)``.
/// When the consumer task is cancelled, the session closes.
public protocol Session: AnyObject, Sendable {
    /// The harness of the session.
    var harness: Harness { get }
    /// The vendor session id. It can be nil until the vendor sends it.
    var id: String? { get }
    /// The child process id. It is nil for an in-process session.
    var pid: Int32? { get }
    /// The event stream. It has one consumer.
    var events: AsyncStream<Event> { get }
    /// The first failure that the session recorded.
    var lastError: WireError? { get }
    /// Writes one user turn. It throws ``AgentBinderError/turnActive`` while a turn runs,
    /// unless the vendor queues a second prompt itself.
    func prompt(_ p: Prompt) async throws
    /// Steers the running turn, else prompts, else holds the prompt until the turn ends.
    func send(_ p: Prompt) async throws -> Delivery
    /// Asks the harness to stop the current turn.
    func interrupt() async throws
    /// Sends a decision for a permission request.
    func answer(_ permissionID: String, _ d: Decision) async throws
    /// Closes the session gracefully: close stdin, wait 5 s, SIGTERM, wait 5 s, SIGKILL.
    /// It returns after the event stream ends.
    func close() async
    /// Kills the process tree at once.
    func kill() async
}

/// How ``Session/send(_:)`` delivered a prompt.
public enum Delivery: String, Sendable, Codable {
    /// The prompt joined the running turn.
    case steered
    /// A new turn starts now, or the vendor queues it.
    case prompted
    /// The prompt starts a new turn when the running turn ends.
    case held
}

/// A session that can change the model during the session. It does not stop the running turn.
public protocol ModelSettable: Session {
    /// Changes the model.
    func setModel(_ id: String) async throws
}

/// A session that knows the models that its handshake offered.
public protocol SessionModelListing: Session {
    /// The models of the handshake. It is empty when the handshake offered none.
    var offeredModels: [ModelInfo] { get async }
}

/// A session that can add input to the running turn.
public protocol Steerable: Session {
    /// Adds input to the running turn. It throws ``AgentBinderError/noActiveTurn`` when no turn runs,
    /// and ``AgentBinderError/unsupported(_:)`` when the vendor refuses the input.
    func steer(_ p: Prompt) async throws
}
