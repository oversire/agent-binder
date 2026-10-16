import Foundation

/// A Claude session. A second prompt during a turn goes to the CLI, which queues it.
final class ClaudeSession: ModelSettable, Steerable, SessionModelListing {
    private let wire: WireSession
    private let adapter: ClaudeAdapter

    init(wire: WireSession, adapter: ClaudeAdapter) {
        self.wire = wire
        self.adapter = adapter
    }

    var harness: Harness { wire.harness }
    var id: String? { wire.id }
    var pid: Int32? { wire.pid }
    var events: AsyncStream<Event> { wire.events }
    var lastError: WireError? { wire.lastError }
    /// The models of the `initialize` reply. It is empty until the reply arrives.
    var offeredModels: [ModelInfo] { adapter.offeredModels }

    func prompt(_ p: Prompt) async throws { try await wire.prompt(p) }
    func send(_ p: Prompt) async throws -> Delivery { try await wire.send(p) }
    func steer(_ p: Prompt) async throws { try await wire.steer(p) }
    func interrupt() async throws { try await wire.interrupt() }
    func answer(_ permissionID: String, _ d: Decision) async throws { try await wire.answer(permissionID, d) }
    func close() async { await wire.close() }
    func kill() async { await wire.kill() }

    // The new model applies from the next API call. The running turn goes on.
    func setModel(_ id: String) async throws {
        _ = try await adapter.control(["subtype": "set_model", "model": .string(id)])
    }
}

extension ClaudeSession: ProcessBacked, CloseObserving {
    var pgid: Int32? { wire.pgid }
    var argv: [String] { wire.argv }
    func onClose(_ hook: @escaping @Sendable () -> Void) { wire.onClose(hook) }
}
