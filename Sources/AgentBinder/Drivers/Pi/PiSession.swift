import Foundation

/// A pi session. A prompt during a turn goes to the running turn as a steer.
final class PiSession: WireBacked, ModelSettable, Steerable {
    let wire: WireSession
    private let adapter: PiAdapter

    init(wire: WireSession, adapter: PiAdapter) {
        self.wire = wire
        self.adapter = adapter
    }

    /// Takes a `provider/model` id, as ``PiDriver`` lists it.
    func setModel(_ id: String) async throws { try await adapter.setModel(id) }
}
