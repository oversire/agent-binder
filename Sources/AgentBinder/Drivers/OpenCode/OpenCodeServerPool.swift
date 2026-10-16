import Foundation

/// The shared `opencode serve` children of one runtime.
///
/// Sessions with the same fingerprint share one server. A server with no session stops after the
/// idle window. ``Runtime/close()`` stops every server at once.
actor OpenCodeServerPool {
    static let idleWindow: Duration = .seconds(60)

    typealias Starter =
        @Sendable (
            _ wire: OpenCodeWire, _ binary: URL, _ environment: [String: String], _ arguments: [String],
            _ context: RuntimeContext
        ) async throws -> OpenCodeServer

    private struct Entry {
        let server: OpenCodeServer
        var refs: Int
        var idle: Task<Void, Never>?
    }

    private let idle: Duration
    private let starter: Starter
    private var entries: [String: Entry] = [:]
    private var starting: [String: Task<OpenCodeServer, any Error>] = [:]

    init(idle: Duration = idleWindow, starter: @escaping Starter = OpenCodeServer.launch) {
        self.idle = idle
        self.starter = starter
    }

    /// A live server for the fingerprint, with one more reference. It starts one when needed.
    /// Concurrent calls for one fingerprint share one start.
    func acquire(
        _ wire: OpenCodeWire, binary: URL, environment: [String: String], arguments: [String],
        context ctx: RuntimeContext
    ) async throws -> OpenCodeServer {
        let key = Self.fingerprint(
            wire, binary: binary, environment: environment, arguments: arguments,
            ignore: ctx.fingerprintIgnoreEnvironment)
        if let e = entries[key], e.server.alive { return retain(key, e.server) }
        let t: Task<OpenCodeServer, any Error>
        if let running = starting[key] {
            t = running
        } else {
            let starter = starter
            t = Task { try await starter(wire, binary, environment, arguments, ctx) }
            starting[key] = t
        }
        let s: OpenCodeServer
        do {
            s = try await t.value
        } catch {
            if starting[key] == t { starting[key] = nil }
            throw error
        }
        if starting[key] == t { starting[key] = nil }
        return retain(key, s)
    }

    private func retain(_ key: String, _ s: OpenCodeServer) -> OpenCodeServer {
        if var e = entries[key], e.server === s {
            e.refs += 1
            e.idle?.cancel()
            e.idle = nil
            entries[key] = e
            return s
        }
        // The old server is dead.
        if let old = entries[key] {
            old.idle?.cancel()
            Task { await old.server.stop() }
        }
        entries[key] = Entry(server: s, refs: 1)
        return s
    }

    /// Drops one reference. The last one starts the idle window.
    func release(_ s: OpenCodeServer) {
        guard let (key, found) = entries.first(where: { $0.value.server === s }) else { return }
        var e = found
        e.refs -= 1
        if e.refs <= 0 && e.idle == nil {
            let window = idle
            e.idle = Task { [weak self] in
                try? await Task.sleep(for: window)
                if Task.isCancelled { return }
                await self?.expire(key, s)
            }
        }
        entries[key] = e
    }

    private func expire(_ key: String, _ s: OpenCodeServer) async {
        guard let e = entries[key], e.server === s, e.refs <= 0 else { return }
        entries[key] = nil
        await s.stop()
    }

    /// Stops every server at once.
    func stopAll() async {
        let all = entries.values
        entries = [:]
        await withTaskGroup(of: Void.self) { g in
            for e in all {
                e.idle?.cancel()
                g.addTask { await e.server.stop() }
            }
        }
    }

    /// The servers in the pool, for tests and diagnostics.
    var servers: [OpenCodeServer] { entries.values.map(\.server) }

    func refs(_ s: OpenCodeServer) -> Int { entries.values.first { $0.server === s }?.refs ?? 0 }

    /// The key of a shared server: the wire, the binary, the environment and the arguments.
    ///
    /// The server auth keys and the keys in `ignore` are left out. The match is case-insensitive,
    /// and `"*"` leaves out every key. The working directory is not in the key.
    static func fingerprint(
        _ wire: OpenCodeWire, binary: URL, environment: [String: String], arguments: [String], ignore: [String]
    ) -> String {
        let skip = Set(ignore.map { $0.uppercased() })
        let keys = environment.keys.filter { k in
            if k == "OPENCODE_SERVER_PASSWORD" || k == "OPENCODE_SERVER_USERNAME" { return false }
            return !skip.contains("*") && !skip.contains(k.uppercased())
        }.sorted()
        var parts = [wire.harness.rawValue, binary.path]
        parts += keys.map { "\($0)=\(environment[$0]!)" }
        parts += arguments
        return parts.joined(separator: "\u{0}")
    }
}
