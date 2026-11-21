import Foundation

/// A Codex session. A second prompt during a turn throws ``AgentBinderError/turnActive``.
final class CodexSession: WireBacked, ModelSettable, Steerable {
    let wire: WireSession
    private let adapter: CodexAdapter

    init(wire: WireSession, adapter: CodexAdapter) {
        self.wire = wire
        self.adapter = adapter
    }

    // The model applies from the next turn/start.
    func setModel(_ id: String) async throws { adapter.setModel(id) }
}
