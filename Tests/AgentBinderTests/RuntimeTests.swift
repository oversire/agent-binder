import Darwin
import Foundation
import Testing

@testable import AgentBinder

private func workDir() -> URL { URL(fileURLWithPath: NSTemporaryDirectory()) }

/// A temp PATH with fake vendor binaries.
fileprivate struct FakeBin {
    let dir: TempDir
    let counter: URL

    init() throws {
        dir = try TempDir()
        counter = dir.url.appendingPathComponent("probes.count")
    }

    /// Writes `<name>` that prints `version` for `--version` and `auth` for the login command.
    @discardableResult
    func tool(_ name: String, version: String, auth: String = "", authArgs: String = "auth") throws -> URL {
        try dir.script(
            name,
            """
            case "$1" in
            --version) echo '\(version)' ;;
            \(authArgs)) echo x >> '\(counter.path)'; printf '%s' '\(auth)' ;;
            esac
            """)
    }

    var probes: Int { (try? String(contentsOf: counter, encoding: .utf8))?.split(separator: "\n").count ?? 0 }

    func runtime(environment: [String: String] = [:], now: @escaping Now = Date.init) -> Runtime {
        let o = Runtime.Options(
            binarySearchPaths: [dir.url, URL(fileURLWithPath: "/usr/bin"), URL(fileURLWithPath: "/bin")],
            useLoginShellPath: false, environment: environment)
        return Runtime(options: o, now: now, probeTimeout: .testProbe)
    }
}

@Suite("DetectTests")
struct DetectTests {
    fileprivate let bin: FakeBin

    init() throws { bin = try FakeBin() }

    private func runtime(
        _ env: [String: String] = [:], drivers: [Harness] = [.claude, .codex, .opencode]
    ) async
        -> Runtime
    {
        let rt = bin.runtime(environment: env)
        for h in drivers { await rt.setDriver(PlainDriver(), for: h) }
        return rt
    }

    @Test func missingBinary() async {
        let d = await runtime().detect(.claude)
        #expect(d.detail == .notInstalled)
        #expect(!d.supported && !d.ready)
        #expect(d.features == .builtIn(.claude))
    }

    @Test func belowFloor() async throws {
        try bin.tool("claude", version: "1.9.0 (Claude Code)")
        let d = await runtime().detect(.claude)
        #expect(d.detail == .belowFloor("2.0.0"))
        #expect(d.version == "1.9.0 (Claude Code)")
        #expect(!d.supported)
    }

    @Test func jsonLogin() async throws {
        let path = try bin.tool("claude", version: "2.1.0 (Claude Code)", auth: #"{"loggedIn":true,"email":"a@b.c"}"#)
        let d = await runtime().detect(.claude)
        #expect(d.path == path)
        #expect(d.supported && d.ready)
        #expect(d.auth == .ok)
        #expect(d.authDetail == "a@b.c")
        #expect(d.detail == nil)
    }

    @Test func jsonLoggedOut() async throws {
        try bin.tool("claude", version: "2.1.0", auth: #"{"loggedIn":false}"#)
        let d = await runtime().detect(.claude)
        #expect(d.supported && !d.ready)
        #expect(d.auth == .missing)
    }

    @Test func textLogin() async throws {
        try bin.tool("codex", version: "codex-cli 0.48.0", auth: "Logged in using ChatGPT", authArgs: "login")
        let d = await runtime().detect(.codex)
        #expect(d.auth == .ok && d.ready)

        try bin.tool("codex", version: "codex-cli 0.48.0", auth: "Not logged in", authArgs: "login")
        let rt = await runtime()
        #expect(await rt.detect(.codex).auth == .missing)
    }

    @Test func emptyAuthListIsMissing() async throws {
        try bin.tool("opencode", version: "1.0.0", auth: "")
        #expect(await runtime().detect(.opencode).auth == .missing)
    }

    @Test func environmentKeyWinsWithoutAProbe() async throws {
        try bin.tool("claude", version: "2.1.0", auth: #"{"loggedIn":false}"#)
        let d = await runtime(["ANTHROPIC_API_KEY": "sk-test"]).detect(.claude)
        #expect(d.auth == .ok)
        #expect(d.authDetail == "key ANTHROPIC_API_KEY")
        #expect(bin.probes == 0)
    }

    @Test func probeCacheAndInvalidate() async throws {
        try bin.tool("claude", version: "2.1.0", auth: #"{"loggedIn":true}"#)
        let rt = await runtime()
        _ = await rt.detect(.claude)
        _ = await rt.detect(.claude)
        #expect(bin.probes == 1)
        await rt.invalidateDetect(.claude)
        _ = await rt.detect(.claude)
        #expect(bin.probes == 2)
    }

    @Test func concurrentMissRunsOneProbe() async throws {
        try bin.tool("claude", version: "2.1.0", auth: #"{"loggedIn":true}"#)
        let rt = await runtime()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<8 { g.addTask { _ = await rt.detect(.claude) } }
        }
        #expect(bin.probes == 1)
    }

    @Test func noDriverAndFake() async {
        let rt = await runtime(drivers: [])
        #expect(await rt.detect(Harness("custom")).detail == .noDriver)
        let fake = await rt.detect(.fake)
        #expect(fake.supported && fake.ready && fake.auth == .ok)
    }

    @Test func selfDetectingDriver() async {
        let rt = await runtime(drivers: [])
        await rt.setDriver(InProcessDriver(), for: .native)
        let d = await rt.detect(.native)
        #expect(d.harness == .native)
        #expect(d.ready)
        #expect(d.features == .builtIn(.native))
    }

    @Test func detectAllKeepsTheOrder() async {
        let all = await runtime(drivers: []).detectAll()
        #expect(all.map(\.harness) == Harness.allBuiltIn)
    }

    @Test func featuresTable() {
        let claude = Features.builtIn(.claude)
        #expect(claude.mcpInject == .flags && claude.skillsInject == .native && claude.steer)
        let codex = Features.builtIn(.codex)
        #expect(codex.skillsInject == .overlay && codex.steer)
        #expect(!Features.builtIn(.opencode).steer)
        #expect(!Features.builtIn(.pi).attachments && !Features.builtIn(.pi).steer)
        for h in [Harness.copilot, .cursor, .gemini] {
            #expect(Features.builtIn(h).mcpInject == .session && Features.builtIn(h).fileSystem)
        }
        #expect(!Features.builtIn(.native).models)
        #expect(Features.builtIn(Harness("custom")) == Features(skillsInject: .instructions))
    }
}

@Suite("SandboxTests")
struct SandboxTests {
    @Test func startAndDetect() async throws {
        let rt = Runtime(options: .init(useLoginShellPath: false, environment: ["APP_SANDBOX_CONTAINER_ID": "x"]))
        await rt.setDriver(ShellDriver(), for: .claude)
        await #expect(throws: AgentBinderError.sandboxed) {
            try await rt.start(StartRequest(workingDirectory: workDir()))
        }
        #expect(await rt.detect(.claude).detail == .sandboxed)
    }
}

@Suite("ModelCacheTests")
struct ModelCacheTests {
    private func runtime(_ ttl: Duration = .seconds(600), now: @escaping Now = Date.init) -> Runtime {
        Runtime(options: .init(modelCacheTTL: ttl, useLoginShellPath: false, environment: [:]), now: now)
    }

    @Test func cacheKeysAndInvalidate() async throws {
        let rt = runtime()
        let d = CountingDriver()
        await rt.setDriver(d, for: .fake)
        var first = try await rt.models(.fake)
        #expect(first.map(\.id) == ["m1", "m2"])
        first[0].id = "changed"
        #expect(try await rt.models(.fake)[0].id == "m1")
        #expect(d.calls.value == 1)

        let home = try TempDir()
        _ = try await rt.models(.fake, query: ModelQuery(home: home.url))
        #expect(d.calls.value == 2)

        await rt.invalidateModels(.fake)
        _ = try await rt.models(.fake)
        #expect(d.calls.value == 3)
    }

    @Test func concurrentCallsRunOneProbe() async throws {
        let rt = runtime()
        let d = CountingDriver(open: false)
        await rt.setDriver(d, for: .fake)
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<20 { g.addTask { _ = try await rt.models(.fake) } }
            try await eventually { d.calls.value >= 1 }
            try await Task.sleep(for: .milliseconds(50))
            d.gate.open()
            try await g.waitForAll()
        }
        #expect(d.calls.value == 1)
    }

    @Test func errorTTL() async throws {
        let clock = TestClock()
        let rt = runtime(now: clock.now)
        let d = CountingDriver()
        d.failure.withLock { $0 = .unsupported("not logged in") }
        await rt.setDriver(d, for: .fake)
        for _ in 0..<2 {
            await #expect(throws: AgentBinderError.unsupported("not logged in")) { try await rt.models(.fake) }
        }
        #expect(d.calls.value == 1)
        clock.advance(31)
        d.failure.withLock { $0 = nil }
        #expect(try await rt.models(.fake).count == 2)
        #expect(d.calls.value == 2)
        clock.advance(500)
        _ = try await rt.models(.fake)
        #expect(d.calls.value == 2)
        clock.advance(101)
        _ = try await rt.models(.fake)
        #expect(d.calls.value == 3)
    }

    @Test func negativeTTLTurnsTheCacheOff() async throws {
        let rt = runtime(.seconds(-1))
        let d = CountingDriver()
        await rt.setDriver(d, for: .fake)
        _ = try await rt.models(.fake)
        _ = try await rt.models(.fake)
        #expect(d.calls.value == 2)
    }

    @Test func unsupportedAndNoDriver() async {
        let rt = runtime()
        await rt.setDriver(PlainDriver(), for: .fake)
        await #expect(throws: AgentBinderError.unsupported("fake lists no models")) { try await rt.models(.fake) }
        await #expect(throws: AgentBinderError.noDriver(Harness("none"))) { try await rt.models(Harness("none")) }
        await #expect(throws: AgentBinderError.unsupported("fake reads no limits")) { try await rt.limits(.fake) }
    }

    @Test func limitsAreNotCached() async throws {
        let rt = runtime()
        await rt.setDriver(CountingDriver(), for: .codex)
        let l = try await rt.limits(.codex)
        #expect(l.plan == "pro")
        #expect(l.windows.first?.key == .fiveHour)
    }
}

@Suite("RuntimeTests")
struct RuntimeTests {
    @Test func isolation() async throws {
        let a = Runtime(options: .init(useLoginShellPath: false, environment: [:]))
        let b = Runtime(options: .init(useLoginShellPath: false, environment: [:]))
        let da = CountingDriver()
        let db = CountingDriver()
        await a.setDriver(da, for: .fake)
        await b.setDriver(db, for: .fake)
        _ = try await a.models(.fake)
        _ = try await a.models(.fake)
        #expect(da.calls.value == 1)
        #expect(db.calls.value == 0)
        _ = try await b.models(.fake)
        #expect(db.calls.value == 1)

        #expect(a.context.nextID() == 1)
        #expect(a.context.nextID() == 2)
        #expect(b.context.nextID() == 1)
    }

    @Test func setDriverAndRestore() async throws {
        let rt = Runtime(options: .init(useLoginShellPath: false, environment: [:]))
        let custom = Harness("custom")
        await #expect(throws: AgentBinderError.noDriver(custom)) {
            try await rt.start(StartRequest(harness: custom, workingDirectory: workDir()))
        }
        await rt.setDriver(
            ShellDriver(script: #"echo '{"type":"init","id":"c-1"}'; read -r line || true"#), for: custom)
        let s = try await rt.start(StartRequest(harness: custom, workingDirectory: workDir()))
        #expect(s.harness == custom)
        #expect(s.pid != nil)
        await s.close()
        await rt.setDriver(nil, for: custom)
        #expect(await rt.driver(for: custom) == nil)
    }

    @Test func closeEndsEverySession() async throws {
        let rt = Runtime(options: .init(useLoginShellPath: false, environment: [:]))
        await rt.setDriver(ShellDriver(), for: .claude)
        var sessions: [any Session] = []
        for _ in 0..<5 { sessions.append(try await rt.start(StartRequest(workingDirectory: workDir()))) }
        let pids = sessions.compactMap(\.pid)
        #expect(pids.count == 5)
        #expect(rt.context.ledger.keys.count == 5)

        let readers = sessions.map { s in Task { await s.events.collect() } }
        try await withTimeout(.seconds(20)) { await rt.close() }
        for r in readers {
            let events = await r.value
            #expect(events.last?.isExit == true)
        }
        for pid in pids { #expect(!ProcessGroup.alive(pid)) }
        #expect(rt.context.ledger.keys.isEmpty)

        await rt.close()
        await #expect(throws: AgentBinderError.sessionClosed) {
            try await rt.start(StartRequest(workingDirectory: workDir()))
        }
    }

    @Test func sessionCloseDropsTheLedgerRow() async throws {
        let dir = try TempDir()
        let path = dir.url.appendingPathComponent("ledger.jsonl")
        let rt = Runtime(options: .init(ledger: path, useLoginShellPath: false, environment: [:]))
        await rt.setDriver(ShellDriver(), for: .claude)
        let s = try await rt.start(StartRequest(workingDirectory: workDir()))
        let rows = rt.context.ledger.rows
        #expect(rows.count == 1)
        #expect(rows.first?.key == "claude:\(s.pid!)")
        #expect(rows.first?.argv == ["/bin/sh", "-c", "read -r line || true"])
        await s.close()
        try await eventually { rt.context.ledger.rows.isEmpty }
        #expect(!FileManager.default.fileExists(atPath: path.path))
        await rt.close()
    }
}

@Suite("LedgerTests")
struct LedgerTests {
    let dir: TempDir
    var path: URL { dir.url.appendingPathComponent("state/ledger.jsonl") }

    init() throws { dir = try TempDir() }

    private func sleeper() throws -> ChildProcess {
        let p = try ChildProcess.spawn(
            SpawnOptions(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"]))
        return p
    }

    @Test func trackRecordsEvidence() throws {
        let l = Ledger(path: path)
        let pid = getpid()
        l.track(key: "helper:1", harness: .opencode, pid: pid, pgid: getpgrp(), argv: ["opencode", "serve"])
        let row = try #require(l.rows.first)
        #expect(row.key == "helper:1")
        #expect(row.harness == "opencode")
        #expect(row.pid == pid)
        #expect(row.pgid == getpgrp())
        #expect(row.argv == ["opencode", "serve"])
        #expect(row.startToken == StartToken.of(pid))
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        #expect(JSONValue.parse(text.trimmingCharacters(in: .newlines))?["start_token"]?.string == row.startToken)
    }

    @Test func removeDropsRowAndFile() {
        let l = Ledger(path: path)
        l.track(key: "a", harness: .codex, pid: getpid(), pgid: nil, argv: [])
        l.track(key: "b", harness: .codex, pid: getpid(), pgid: nil, argv: [])
        l.track(key: "b", harness: .codex, pid: getpid(), pgid: nil, argv: ["again"])
        #expect(l.rows.map(\.key) == ["a", "b"])
        #expect(l.rows.last?.argv == ["again"])
        l.remove("a")
        #expect(l.rows.map(\.key) == ["b"])
        l.remove("b")
        #expect(l.rows.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func reconcileKillsAMatchedChild() async throws {
        let p = try sleeper()
        let l = Ledger(path: path)
        l.track(key: "claude:\(p.pid)", harness: .claude, pid: p.pid, pgid: p.pgid, argv: p.argv)
        #expect(Ledger(path: path).reconcile() == ["claude:\(p.pid)"])
        #expect(await p.waitForExit(timeout: .seconds(5)))
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func reconcileSparesAReusedPID() async throws {
        let p = try sleeper()
        defer { p.signalGroup(SIGKILL) }
        try write([
            Ledger.Row(
                key: "claude:4242", harness: "claude", pid: p.pid, pgid: p.pgid, startToken: "not-this-process",
                startedAt: Date(), argv: [])
        ])
        #expect(Ledger(path: path).reconcile().isEmpty)
        #expect(ProcessGroup.alive(p.pid))
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func reconcileDropsADeadRow() async throws {
        let p = try ChildProcess.spawn(
            SpawnOptions(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"]))
        await p.waitForExit()
        try write([Ledger.Row(key: "codex:7", harness: "codex", pid: p.pid, pgid: p.pgid, startedAt: Date(), argv: [])])
        #expect(Ledger(path: path).reconcile().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func corruptLinesAreSkipped() throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json\n{\"key\":1}\n".utf8).write(to: path)
        let l = Ledger(path: path)
        #expect(l.rows.isEmpty)
        #expect(l.reconcile().isEmpty)
        l.track(key: "a", harness: .codex, pid: getpid(), pgid: nil, argv: [])
        #expect(l.rows.map(\.key) == ["a"])
    }

    @Test func noPathKeepsSessionsOnly() {
        let l = Ledger(path: nil)
        l.track(key: "a", harness: .codex, pid: getpid(), pgid: nil, argv: [])
        #expect(l.rows.isEmpty)
        #expect(l.reconcile().isEmpty)
    }

    private func write(_ rows: [Ledger.Row]) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var data = Data()
        for r in rows {
            data.append(try enc.encode(r))
            data.append(UInt8(ascii: "\n"))
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
    }
}
