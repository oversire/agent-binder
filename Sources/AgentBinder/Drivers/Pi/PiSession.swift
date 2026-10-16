import Foundation

/// A pi session. A prompt during a turn goes to the running turn as a steer.
final class PiSession: ModelSettable, Steerable {
    private let wire: WireSession
    private let adapter: PiAdapter

    init(wire: WireSession, adapter: PiAdapter) {
        self.wire = wire
        self.adapter = adapter
    }

    var harness: Harness { wire.harness }
    var id: String? { wire.id }
    var pid: Int32? { wire.pid }
    var events: AsyncStream<Event> { wire.events }
    var lastError: WireError? { wire.lastError }

    func prompt(_ p: Prompt) async throws { try await wire.prompt(p) }
    func send(_ p: Prompt) async throws -> Delivery { try await wire.send(p) }
    func steer(_ p: Prompt) async throws { try await wire.steer(p) }
    func interrupt() async throws { try await wire.interrupt() }
    func answer(_ permissionID: String, _ d: Decision) async throws { try await wire.answer(permissionID, d) }
    func close() async { await wire.close() }
    func kill() async { await wire.kill() }

    /// Takes a `provider/model` id, as ``PiDriver`` lists it.
    func setModel(_ id: String) async throws { try await adapter.setModel(id) }
}

extension PiSession: ProcessBacked, CloseObserving {
    var pgid: Int32? { wire.pgid }
    var argv: [String] { wire.argv }
    func onClose(_ hook: @escaping @Sendable () -> Void) { wire.onClose(hook) }
}
