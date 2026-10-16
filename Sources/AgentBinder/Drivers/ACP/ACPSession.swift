import Foundation

/// An ACP session. It has no steer, so a prompt during a turn waits in the outbox.
final class ACPSession: ModelSettable, SessionModelListing {
    private let wire: WireSession
    private let adapter: ACPAdapter

    init(wire: WireSession, adapter: ACPAdapter) {
        self.wire = wire
        self.adapter = adapter
    }

    var harness: Harness { wire.harness }
    var id: String? { wire.id }
    var pid: Int32? { wire.pid }
    var events: AsyncStream<Event> { wire.events }
    var lastError: WireError? { wire.lastError }
    /// The models of the session open, with the default on the current model.
    var offeredModels: [ModelInfo] { adapter.offeredModels }

    func prompt(_ p: Prompt) async throws { try await wire.prompt(p) }
    func send(_ p: Prompt) async throws -> Delivery { try await wire.send(p) }
    func interrupt() async throws { try await wire.interrupt() }
    func answer(_ permissionID: String, _ d: Decision) async throws { try await wire.answer(permissionID, d) }
    func close() async { await wire.close() }
    func kill() async { await wire.kill() }

    func setModel(_ id: String) async throws {
        guard !adapter.offeredModels.isEmpty else {
            throw AgentBinderError.unsupported("\(adapter.config.variant.rawValue) offered no models")
        }
        try await adapter.applyModel(id)
    }
}

extension ACPSession: ProcessBacked, CloseObserving {
    var pgid: Int32? { wire.pgid }
    var argv: [String] { wire.argv }
    func onClose(_ hook: @escaping @Sendable () -> Void) { wire.onClose(hook) }
}
