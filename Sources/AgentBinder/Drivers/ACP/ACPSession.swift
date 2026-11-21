import Foundation

/// An ACP session. It has no steer, so a prompt during a turn waits in the outbox.
final class ACPSession: WireBacked, ModelSettable, SessionModelListing {
    let wire: WireSession
    private let adapter: ACPAdapter

    init(wire: WireSession, adapter: ACPAdapter) {
        self.wire = wire
        self.adapter = adapter
    }

    /// The models of the session open, with the default on the current model.
    var offeredModels: [ModelInfo] { adapter.offeredModels }

    func setModel(_ id: String) async throws {
        guard !adapter.offeredModels.isEmpty else {
            throw AgentBinderError.unsupported("\(adapter.config.variant.rawValue) offered no models")
        }
        try await adapter.applyModel(id)
    }
}
