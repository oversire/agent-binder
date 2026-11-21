import Foundation

/// A session that forwards the common calls to a ``WireSession``.
protocol WireBacked: Session, ProcessBacked, CloseObserving {
    var wire: WireSession { get }
}

extension WireBacked {
    var harness: Harness { wire.harness }
    var id: String? { wire.id }
    var pid: Int32? { wire.pid }
    var events: AsyncStream<Event> { wire.events }
    var lastError: WireError? { wire.lastError }
    var pgid: Int32? { wire.pgid }
    var argv: [String] { wire.argv }

    func prompt(_ p: Prompt) async throws { try await wire.prompt(p) }
    func send(_ p: Prompt) async throws -> Delivery { try await wire.send(p) }
    func interrupt() async throws { try await wire.interrupt() }
    func answer(_ permissionID: String, _ d: Decision) async throws { try await wire.answer(permissionID, d) }
    func close() async { await wire.close() }
    func kill() async { await wire.kill() }
    func onClose(_ hook: @escaping @Sendable () -> Void) { wire.onClose(hook) }
}

extension WireBacked where Self: Steerable {
    func steer(_ p: Prompt) async throws { try await wire.steer(p) }
}
