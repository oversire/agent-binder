import Foundation

/// A session that runs a child process, with the evidence that the ledger needs.
protocol ProcessBacked {
    var pgid: Int32? { get }
    var argv: [String] { get }
}

/// A session on a child that other sessions share. The owner of the child tracks its row.
protocol SharedChildBacked {}

/// A session that runs hooks after it ends.
package protocol CloseObserving {
    func onClose(_ hook: @escaping @Sendable () -> Void)
}

extension WireSession: ProcessBacked, CloseObserving {}

/// The live sessions of a runtime, and the crash ledger of their children.
///
/// After a crash, ``reconcile()`` kills the children that a previous process left. The start token
/// guards against a reused pid. Without a path, the ledger keeps the live sessions only.
final class Ledger: Sendable {
    struct Row: Codable, Equatable, Sendable {
        var key: String
        var harness: String
        var pid: Int32
        var pgid: Int32?
        var startToken: String?
        var startedAt: Date
        var argv: [String]

        enum CodingKeys: String, CodingKey {
            case key, harness, pid, pgid, argv
            case startToken = "start_token"
            case startedAt = "started_at"
        }
    }

    private struct State {
        var sessions: [String: any Session] = [:]
        var closers: [@Sendable () async -> Void] = []
        var seq = 0
    }

    let path: URL?
    private let state = Locked(State())

    init(path: URL?) { self.path = path }

    /// Registers a live session and records its child. The row goes away when the session ends.
    /// It returns the key.
    // Fixed on purpose: sessions on a shared child get their own key, so one close does not drop the others.
    @discardableResult
    func add(_ s: any Session) -> String {
        let shared = s is SharedChildBacked
        let key = state.withLock { st -> String in
            st.seq += 1
            if shared { return "\(s.harness):shared-\(st.seq)" }
            return "\(s.harness):\(s.pid.map(String.init) ?? "mem-\(st.seq)")"
        }
        state.withLock { $0.sessions[key] = s }
        if !shared, let pid = s.pid {
            let p = s as? ProcessBacked
            track(key: key, harness: s.harness, pid: pid, pgid: p?.pgid, argv: p?.argv ?? [])
        }
        (s as? CloseObserving)?.onClose { [weak self] in self?.remove(key) }
        return key
    }

    /// Records a child that has no session, for example a shared server.
    func track(key: String, harness: Harness, pid: Int32, pgid: Int32?, argv: [String]) {
        guard pid > 0, !key.isEmpty else { return }
        let row = Row(
            key: key, harness: harness.rawValue, pid: pid, pgid: pgid, startToken: StartToken.of(pid),
            startedAt: Date(), argv: argv)
        rewrite { rows in
            rows.removeAll { $0.key == key }
            rows.append(row)
        }
    }

    /// Adds a hook that ``closeAll()`` runs, for a shared resource such as a server pool.
    func onCloseAll(_ hook: @escaping @Sendable () async -> Void) {
        state.withLock { $0.closers.append(hook) }
    }

    func remove(_ key: String) {
        state.withLock { _ = $0.sessions.removeValue(forKey: key) }
        rewrite { $0.removeAll { $0.key == key } }
    }

    var keys: [String] { state.withLock { Array($0.sessions.keys) } }

    func session(_ key: String) -> (any Session)? { state.withLock { $0.sessions[key] } }

    /// Closes every live session and runs the close hooks, in parallel, and waits.
    func closeAll() async {
        let (sessions, closers) = state.withLock { st in
            defer {
                st.sessions = [:]
                st.closers = []
            }
            return (Array(st.sessions), st.closers)
        }
        await withTaskGroup(of: Void.self) { g in
            for (_, s) in sessions { g.addTask { await s.close() } }
            for c in closers { g.addTask { await c() } }
        }
        for (k, _) in sessions { remove(k) }
    }

    /// The rows in the file. A file that does not parse gives no rows.
    var rows: [Row] { state.withLock { _ in readRows() } }

    /// Kills each child that a row matches: the pid is alive and the start token is the same.
    /// It then drops every row. It returns the keys of the killed children.
    @discardableResult
    func reconcile() -> [String] {
        guard let path else { return [] }
        return state.withLock { _ in
            var killed: [String] = []
            for r in readRows() where ProcessGroup.alive(r.pid) {
                // A different token means that the pid now belongs to another process.
                if let want = r.startToken, let got = StartToken.of(r.pid), got != want { continue }
                ProcessGroup.kill(pgid: r.pgid ?? 0, pid: r.pid)
                killed.append(r.key)
            }
            try? FileManager.default.removeItem(at: path)
            return killed
        }
    }

    // MARK: file

    private func rewrite(_ change: @Sendable (inout [Row]) -> Void) {
        guard let path else { return }
        state.withLock { _ in
            var rows = readRows()
            change(&rows)
            writeRows(rows, to: path)
        }
    }

    // JSON lines. A line that does not parse is skipped.
    private func readRows() -> [Row] {
        guard let path, let data = try? Data(contentsOf: path) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? dec.decode(Row.self, from: Data($0)) }
    }

    private func writeRows(_ rows: [Row], to path: URL) {
        let fm = FileManager.default
        guard !rows.isEmpty else {
            try? fm.removeItem(at: path)
            return
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .sortedKeys
        var data = Data()
        for r in rows {
            guard let line = try? enc.encode(r) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try? fm.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let tmp = path.appendingPathExtension("tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        _ = rename(tmp.path, path.path)
    }
}
