import Foundation

/// A Claude session. A second prompt during a turn goes to the CLI, which queues it.
final class ClaudeSession: WireBacked, ModelSettable, Steerable, SessionModelListing {
    let wire: WireSession
    private let adapter: ClaudeAdapter

    init(wire: WireSession, adapter: ClaudeAdapter) {
        self.wire = wire
        self.adapter = adapter
    }

    /// The models of the `initialize` reply. It is empty until the reply arrives.
    var offeredModels: [ModelInfo] { adapter.offeredModels }

    // The new model applies from the next API call. The running turn goes on.
    func setModel(_ id: String) async throws {
        _ = try await adapter.control(["subtype": "set_model", "model": .string(id)])
    }
}
