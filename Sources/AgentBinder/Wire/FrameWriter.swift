import Foundation

/// The handle of an adapter on the stdin of the child, plus the session id.
///
/// Writes keep their order. One frame never interleaves with another.
final class FrameWriter: Sendable {
    typealias Sink = @Sendable (Data) async throws -> Void

    /// The harness of the session.
    let harness: Harness
    private let sink: Sink
    private let log: FrameLog?
    private let onSessionID: @Sendable (String) -> Void
    private let closed = Locked(false)

    init(harness: Harness, log: FrameLog?, onSessionID: @escaping @Sendable (String) -> Void, sink: @escaping Sink) {
        self.harness = harness
        self.log = log
        self.onSessionID = onSessionID
        self.sink = sink
    }

    /// Writes one frame and adds the newline when it is missing.
    func write(_ frame: Data) async throws {
        guard !closed.value else { throw AgentBinderError.sessionClosed }
        var f = frame
        if f.last != 0x0A { f.append(0x0A) }
        log?.write(.out, f.dropLast())
        try await sink(f)
    }

    /// Writes one JSON value as a frame.
    func write(_ value: JSONValue) async throws {
        try await write(value.frame)
    }

    /// Records the vendor session id that the adapter learned on the wire.
    func setSessionID(_ id: String) {
        if !id.isEmpty { onSessionID(id) }
    }

    /// Stops all later writes.
    func close() { closed.withLock { $0 = true } }
}
