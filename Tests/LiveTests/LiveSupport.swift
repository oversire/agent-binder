import Darwin
import Foundation
import Testing

@testable import AgentBinder

struct LiveFailure: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

/// The gate, the limits and the report of the live tier.
enum Live {
    static let all: [Harness] = [.claude, .codex, .opencode, .opencode2, .pi, .copilot, .cursor, .gemini]
    static let detectTimeout: Duration = .seconds(90)
    static let startTimeout: Duration = .seconds(180)
    static let turnTimeout: Duration = .seconds(300)
    static let skillTimeout: Duration = .seconds(360)
    static let closeTimeout: Duration = .seconds(45)

    static let env = ProcessInfo.processInfo.environment

    /// `AGENTBINDER_LIVE` names the harnesses, for example `claude,codex`, or `all`.
    static var gate: Set<String> {
        Set((env["AGENTBINDER_LIVE"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            .subtracting([""])
    }

    static var on: Bool { !gate.isEmpty }
    static func on(_ h: Harness) -> Bool { gate.contains("all") || gate.contains(h.rawValue) }

    /// The tier proves the login of the CLI. An API key in the environment would hide a broken login.
    static let forbiddenKeys = ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY"]

    /// The environment of the children: no API keys, and no markers of a parent Claude Code session.
    static var childEnvironment: [String: String] {
        env.filter { k, _ in !forbiddenKeys.contains(k) && !k.hasPrefix("CLAUDE_CODE_") && k != "CLAUDECODE" }
    }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static var resultsDir: URL { root.appendingPathComponent(".build/live-results") }

    static var helper: URL { root.appendingPathComponent(".build/debug/agentbinder-mcp-helper") }

    private static let detections = Locked<[Harness: Detection]>([:])

    /// The runs that are not closed. A failed case closes them, so its servers do not leak into the next case.
    static let open = Locked<[LiveRun]>([])

    static func closeOpen() async {
        let runs = open.withLock { l in
            defer { l = [] }
            return l
        }
        for r in runs { await r.close() }
    }

    static func detect(_ h: Harness) async throws -> Detection {
        if let d = detections.value[h] { return d }
        let rt = runtime()
        let d = try await Deadline.run(detectTimeout, onTimeout: LiveFailure("detect timed out")) { await rt.detect(h) }
        await rt.close()
        detections.withLock { $0[h] = d }
        return d
    }

    static func runtime() -> Runtime {
        var o = Runtime.Options(clientName: "agentbinder-live", environment: childEnvironment)
        o.authCacheTTL = .seconds(600)
        return Runtime(options: o)
    }

    static func record(_ h: Harness, _ name: String, _ status: String, version: String?) {
        try? FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        let file = resultsDir.appendingPathComponent(
            "\(h.rawValue)--\(name.replacingOccurrences(of: " ", with: "_")).txt")
        let line = [h.rawValue, version ?? "", name, status.replacingOccurrences(of: "\n", with: " ")]
            .joined(separator: "\t")
        try? Data((line + "\n").utf8).write(to: file)
    }

    /// Runs one case for one harness. It skips when the gate is off, the harness is not ready, or
    /// the harness lacks the feature. It records the outcome for the report.
    static func run(
        _ h: Harness, _ name: String, needs: (Features) -> Bool = { _ in true },
        _ body: (Detection, URL) async throws -> Void
    ) async throws {
        guard on(h) else { return }
        for k in forbiddenKeys {
            try #require(env[k] == nil, "unset \(k): the live tier tests the login of the CLI")
        }
        let d = try await detect(h)
        // `ready` needs a conclusive login probe. Some CLIs have none, so the tier tries a session.
        guard d.supported, d.auth != .missing else {
            record(
                h, name, "skip: not ready (\(d.detail.map { "\($0)" } ?? d.authDetail ?? "auth \(d.auth.rawValue)"))",
                version: d.version)
            return
        }
        guard needs(d.features) else {
            record(h, name, "skip: not supported", version: d.version)
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentbinder-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try await body(d, dir.resolvingSymlinksInPath())
            await closeOpen()
            try await noOrphans()
            record(h, name, "pass", version: d.version)
        } catch AgentBinderError.homeRequired(let feature) {
            // The tier uses the login of the operator home, so it cannot give an isolated home.
            await closeOpen()
            record(h, name, "skip: \(feature) needs StartRequest.home", version: d.version)
        } catch let e as ExpectationFailedError {
            await closeOpen()
            let at = e.expectation.sourceLocation
            record(h, name, "fail: check at \(at.fileName):\(at.line)", version: d.version)
            throw e
        } catch {
            await closeOpen()
            record(h, name, "fail: \(error)", version: d.version)
            throw error
        }
    }

    /// No child of the test process is alive.
    static func noOrphans() async throws {
        let end = ContinuousClock.now + .seconds(10)
        while true {
            let kids = children()
            if kids.isEmpty { return }
            if ContinuousClock.now > end { throw LiveFailure("children still alive: \(kids)") }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    static func children() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 256)
        let n = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        // proc_listchildpids returns a count of pids.
        return n > 0 ? Array(pids.prefix(Int(n))).filter { $0 > 0 && kill($0, 0) == 0 && !zombie($0) } : []
    }

    private static func zombie(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n > 0 && info.pbi_status == SZOMB
    }
}

/// One live session and its events.
final class LiveRun: Sendable {
    let runtime: Runtime
    let session: any Session
    private let all = Locked<[Event]>([])
    private let pump: Task<Void, Never>

    private init(runtime: Runtime, session: any Session) {
        self.runtime = runtime
        self.session = session
        let all = all
        let stream = session.events
        pump = Task { for await e in stream { all.withLock { $0.append(e) } } }
    }

    static func start(
        _ h: Harness, _ dir: URL, resume: Bool = false, runtime: Runtime? = nil,
        _ edit: (inout StartRequest) -> Void = { _ in }
    ) async throws -> LiveRun {
        let rt = runtime ?? Live.runtime()
        var r = StartRequest(harness: h, workingDirectory: dir)
        edit(&r)
        let req = r
        let s = try await Deadline.run(Live.startTimeout, onTimeout: LiveFailure("start timed out")) {
            resume ? try await rt.resume(req) : try await rt.start(req)
        }
        let run = LiveRun(runtime: rt, session: s)
        Live.open.withLock { $0.append(run) }
        return run
    }

    var events: [Event] { all.value }

    var results: [TurnResult] {
        events.compactMap {
            if case .result(let r) = $0.kind { return r }
            return nil
        }
    }

    var permissions: [PermissionRequest] {
        events.compactMap {
            if case .permission(let p) = $0.kind { return p }
            return nil
        }
    }

    /// The answer text of the turns so far: the assistant messages and the results. Deltas join with no separator.
    var text: String {
        var out = ""
        for e in events {
            switch e.kind {
            case .assistant(let t, true): out += t
            case .assistant(let t, false): out += "\n" + t
            case .result(let r): out += "\n" + r.text
            default: break
            }
        }
        return out
    }

    /// Waits until the events meet the condition.
    func wait(
        _ what: String, timeout: Duration = Live.turnTimeout, _ cond: @escaping @Sendable ([Event]) -> Bool
    ) async throws {
        let all = all
        try await Deadline.run(timeout, onTimeout: LiveFailure("timed out: \(what)")) {
            while !cond(all.value) { try await Task.sleep(for: .milliseconds(100)) }
        }
    }

    /// Runs one turn and returns its result. `onPermission` answers each permission request.
    @discardableResult
    func turn(
        _ text: String, timeout: Duration = Live.turnTimeout,
        onPermission: (@Sendable (PermissionRequest) -> Decision)? = nil
    ) async throws -> TurnResult {
        let before = results.count
        let start = events.count
        let answered = Locked<Set<String>>([])
        try await session.prompt(Prompt(text))
        let s = session
        let all = all
        try await Deadline.run(timeout, onTimeout: LiveFailure("turn timed out: \(text)")) {
            while true {
                let evs = all.value
                let rs = evs.compactMap { e -> TurnResult? in
                    if case .result(let r) = e.kind { return r }
                    return nil
                }
                if rs.count > before { return }
                for e in evs.dropFirst(start) {
                    guard case .permission(let p) = e.kind, !answered.value.contains(p.id) else { continue }
                    answered.withLock { _ = $0.insert(p.id) }
                    try await s.answer(p.id, onPermission?(p) ?? .deny("live test: no answer"))
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        return results[before]
    }

    func close() async {
        Live.open.withLock { $0.removeAll { $0 === self } }
        let s = session
        _ = try? await Deadline.run(Live.closeTimeout, onTimeout: LiveFailure("close timed out")) { await s.close() }
        await session.kill()
        await pump.value
        await runtime.close()
    }
}

extension String {
    func has(_ s: String) -> Bool { range(of: s, options: .caseInsensitive) != nil }
}
