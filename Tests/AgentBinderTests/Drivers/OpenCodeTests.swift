import Foundation
import Testing

@testable import AgentBinder

/// Reads every event of a session in the background.
private final class EventSink: Sendable {
    private let all = Locked<[Event]>([])
    private let task: Task<Void, Never>

    init(_ s: any Session) {
        let all = all
        let stream = s.events
        task = Task {
            for await e in stream { all.withLock { $0.append(e) } }
        }
    }

    var events: [Event] { all.value }

    func names() -> [String] { events.map(\.kind.name) }

    var exit: (code: Int32?, error: String?, errorCode: String?)? {
        for e in events {
            if case .exit(let c, let err, let code) = e.kind { return (c, err, code) }
        }
        return nil
    }

    func waitEnd() async { await task.value }
}

/// A test server and a server object that points at it, with no child.
private struct Rig {
    let srv: TestHTTPServer
    let server: OpenCodeServer
    let released: Locked<Int>

    static func make(_ wire: OpenCodeWire) async throws -> Rig {
        let srv = try await TestHTTPServer.start()
        return Rig(srv: srv, server: OpenCodeServer(http: srv.http(wire)), released: Locked(0))
    }

    var lease: OpenCodeLease {
        let r = released
        let once = Locked(false)
        return OpenCodeLease(server: server) {
            if once.withLock({ d -> Bool in
                defer { d = true }
                return !d
            }) {
                r.withLock { $0 += 1 }
            }
        }
    }

    func v1(
        _ id: String = "ses_1", policy: PermissionPolicy = PermissionPolicy(), model: String? = nil
    )
        async throws -> OpenCodeV1Session
    {
        try await server.ensureStreamReady("/w")
        let s = OpenCodeV1Session(
            id: id,
            dialect: OpenCodeV1Dialect(
                sessionID: id, directory: "/w", model: model, effort: nil, instructions: "rules"),
            server: server, policy: policy, release: lease.release)
        s.markLive()
        return s
    }

    func v2(_ id: String = "ses_2", policy: PermissionPolicy = PermissionPolicy()) async throws -> OpenCodeV2Session {
        try await server.ensureStreamReady("/w")
        let s = OpenCodeV2Session(
            id: id, dialect: OpenCodeV2Dialect(sessionID: id, directory: "/w", variant: "high"), server: server,
            policy: policy, release: lease.release)
        s.markLive()
        return s
    }

    func push1(_ type: String, _ props: String) { srv.push(#"{"type":"\#(type)","properties":\#(props)}"#) }
    func push2(_ type: String, _ data: String) { srv.push(#"{"id":"e","type":"\#(type)","data":\#(data)}"#) }
}

private func request(_ dir: URL, _ h: Harness = .opencode) -> StartRequest {
    StartRequest(harness: h, workingDirectory: dir)
}

// MARK: HTTP

@Suite("OpenCodeHTTPTests")
struct OpenCodeHTTPTests {
    @Test func v1Call() async throws {
        let srv = try await TestHTTPServer.start()
        srv.route("POST", "/session", .json(#"{"id":"s1"}"#))
        let v = try await srv.http(.v1).call("POST", "/session", directory: "/w d", body: [:])
        #expect(v["id"] == "s1")
        let r = try #require(srv.requests.first)
        #expect(r.query["directory"] == "/w d" && r.headers["x-opencode-directory"] == "/w d")
        #expect(r.headers["content-type"] == "application/json" && r.json == [:])
        #expect(r.headers["authorization"] == "Basic " + Data("u:p".utf8).base64EncodedString())
    }

    @Test func v2CallHasPrefixAndNoDirectory() async throws {
        let srv = try await TestHTTPServer.start()
        srv.route("POST", "/api/session/s/interrupt", .json(#"{"data":{"ok":true}}"#))
        let v = try await srv.http(.v2).call("POST", "/session/s/interrupt", directory: "/w")
        #expect(v["ok"] == true)
        let r = try #require(srv.requests.first)
        #expect(r.query.isEmpty && r.headers["x-opencode-directory"] == nil && r.headers["content-type"] == nil)
        #expect(r.body.isEmpty)
    }

    @Test func errorStatus() async throws {
        let srv = try await TestHTTPServer.start()
        srv.route("GET", "/session/x", TestHTTPServer.Reply(status: 400, #"{"error":"no such session"}"#))
        await #expect(throws: AgentBinderError.vendor(code: 400, message: "opencode GET /session/x: no such session")) {
            try await srv.http(.v1).call("GET", "/session/x")
        }
    }

    @Test func connectionFailure() async throws {
        let http = OpenCodeHTTP(
            base: URL(string: "http://127.0.0.1:\(try OpenCodeServer.freePort())")!, username: "u", password: "p",
            wire: .v1, maxBytes: 1024)
        await #expect(throws: AgentBinderError.self) { try await http.call("GET", "/config") }
        #expect(await http.health() == .notYet)
    }

    @Test func health() async throws {
        let srv = try await TestHTTPServer.start()
        #expect(await srv.http(.v1).health() == .wrongWire("/global/health answers HTTP 404 text/plain"))
        srv.route("GET", "/global/health", .json(#"{"healthy":false}"#))
        #expect(await srv.http(.v1).health() == .notYet)
        srv.route("GET", "/global/health", .json(#"{"healthy":true,"version":"1.14.3"}"#))
        #expect(await srv.http(.v1).health() == .ready)
        srv.route("GET", "/api/info", TestHTTPServer.Reply(contentType: "text/html; charset=utf-8", "<html/>"))
        guard case .wrongWire = await srv.http(.v2).health() else {
            Issue.record("html is not a wrong wire")
            return
        }
    }
}

// MARK: server

@Suite("OpenCodeServerTests")
struct OpenCodeServerTests {
    // Quirk: 2.x serves its web UI on unknown paths. A wrong wire fails at once, not after 30 s.
    @Test func wrongWireFailsFast() async throws {
        let srv = try await TestHTTPServer.start()
        srv.route("GET", "/global/health", TestHTTPServer.Reply(contentType: "text/html", "<html/>"))
        let dir = try TempDir()
        let child = try ChildProcess.spawn(SpawnOptions(executable: try dir.script("serve", "sleep 30")))
        let s = OpenCodeServer(http: srv.http(.v1), child: child)
        let start = ContinuousClock.now
        await #expect(throws: OpenCodeServer.ReadyFailure.self) { try await s.waitReady() }
        #expect(ContinuousClock.now - start < .seconds(5))
        await child.killTree()
    }

    @Test func readyAndEarlyExit() async throws {
        let srv = try await TestHTTPServer.start()
        srv.route("GET", "/api/info", .json(#"{"version":"2.0.26","pid":1}"#))
        try await OpenCodeServer(http: srv.http(.v2)).waitReady()
        let dir = try TempDir()
        let child = try ChildProcess.spawn(
            SpawnOptions(executable: try dir.script("serve", "echo 'bad config' >&2; exit 2")))
        _ = await child.waitForExit()
        let dead = OpenCodeServer(http: srv.http(.v1), child: child)
        await #expect(throws: OpenCodeServer.ReadyFailure.failed("opencode serve exited early: bad config")) {
            try await dead.waitReady()
        }
        #expect(!dead.alive)
    }

    @Test func healthTimeout() async throws {
        let srv = try await TestHTTPServer.start()
        srv.route("GET", "/global/health", .json(#"{"healthy":false}"#))
        await #expect(throws: OpenCodeServer.ReadyFailure.failed("opencode serve: health timeout")) {
            try await OpenCodeServer(http: srv.http(.v1)).waitReady(timeout: .milliseconds(300))
        }
    }

    @Test func v1StreamIsDirectoryScoped() async throws {
        let rig = try await Rig.make(.v1)
        try await rig.server.ensureStreamReady("/a")
        try await rig.server.ensureStreamReady("/b")
        try await rig.server.ensureStreamReady("/a")
        #expect(rig.server.streamCount == 2)
        #expect(Set(rig.srv.requests("GET", "/event").map { $0.query["directory"] ?? "" }) == ["/a", "/b"])
        await rig.server.stop()
    }

    @Test func v2StreamIsNotDirectoryScoped() async throws {
        let rig = try await Rig.make(.v2)
        for d in ["/a", "/b", "/c"] { try await rig.server.ensureStreamReady(d) }
        #expect(rig.server.streamCount == 1 && rig.srv.requests("GET", "/api/event").count == 1)
        #expect(rig.srv.requests("GET", "/api/event").first?.query.isEmpty == true)
        await rig.server.stop()
    }

    @Test func streamThatDoesNotConnectTimesOut() async throws {
        let srv = try await TestHTTPServer.start(eventPaths: [])
        let s = OpenCodeServer(http: srv.http(.v2))
        await #expect(throws: AgentBinderError.timeout("opencode2 event stream")) {
            try await s.ensureStreamReady("/w", timeout: .milliseconds(300))
        }
        await s.stop()
        await #expect(throws: AgentBinderError.sessionClosed) { try await s.ensureStreamReady("/w") }
        #expect(s.ensureStream("/w") == nil)
    }

    @Test func routingByID() async throws {
        let rig = try await Rig.make(.v1)
        rig.srv.route("POST", "/session/ses_a/prompt_async", .empty)
        rig.srv.route("POST", "/session/ses_b/prompt_async", .empty)
        let a = try await rig.v1("ses_a")
        let b = try await rig.v1("ses_b")
        let sa = EventSink(a)
        let sb = EventSink(b)
        try await a.prompt(Prompt("x"))
        try await b.prompt(Prompt("y"))
        rig.push1("message.part.updated", #"{"part":{"id":"p","sessionID":"ses_b","type":"text","text":"for b"}}"#)
        rig.push1("message.part.updated", #"{"part":{"id":"p","sessionID":"ses_a","type":"text","text":"for a"}}"#)
        rig.push1("message.part.updated", #"{"part":{"id":"p","sessionID":"ses_z","type":"text","text":"nobody"}}"#)
        try await eventually { sa.events.count("assistant") == 1 && sb.events.count("assistant") == 1 }
        #expect(sa.events.compactMap(\.assistantText) == ["for a"])
        #expect(sb.events.compactMap(\.assistantText) == ["for b"])
        #expect(Set(rig.server.routeIDs) == ["ses_a", "ses_b"])
        await a.close()
        #expect(rig.server.routeIDs == ["ses_b"])
        await rig.server.stop()
    }

    @Test func reconnectAfterADroppedStream() async throws {
        let rig = try await Rig.make(.v2)
        rig.srv.route("POST", "/api/session/ses_2/prompt", .json("{}"))
        let s = try await rig.v2()
        let sink = EventSink(s)
        try await s.prompt(Prompt("x"))
        rig.srv.dropStreams()
        try await eventually { rig.srv.requests("GET", "/api/event").count == 2 && rig.srv.openStreams == 1 }
        rig.push2("session.text.delta", #"{"sessionID":"ses_2","assistantMessageID":"m","ordinal":0,"delta":"back"}"#)
        try await eventually { sink.events.compactMap(\.assistantText) == ["back"] }
        await rig.server.stop()
    }

    @Test func stopEndsSessions() async throws {
        let rig = try await Rig.make(.v2)
        rig.srv.route("POST", "/api/session/ses_2/prompt", .json("{}"))
        let s = try await rig.v2()
        let sink = EventSink(s)
        try await s.prompt(Prompt("x"))
        await rig.server.stop()
        await sink.waitEnd()
        let exit = try #require(sink.exit)
        #expect(exit.code == -1 && exit.errorCode == "server_exited" && exit.error == "opencode serve stopped")
        #expect(sink.events.errors.first?.message == "opencode serve stopped")
        #expect(s.lastError != nil && rig.released.value == 1)
        await rig.server.stop()
        await s.close()
    }

    @Test func childDeathEndsSessions() async throws {
        let rig = try await Rig.make(.v1)
        let dir = try TempDir()
        let child = try ChildProcess.spawn(
            SpawnOptions(executable: try dir.script("serve", "sleep 0.5; echo 'panic: boom' >&2; exit 3")))
        let server = OpenCodeServer(http: rig.srv.http(.v1), child: child)
        let s = OpenCodeV1Session(
            id: "ses_1",
            dialect: OpenCodeV1Dialect(sessionID: "ses_1", directory: "/w", model: nil, effort: nil, instructions: nil),
            server: server, policy: PermissionPolicy())
        s.markLive()
        #expect(s.pid == child.pid)
        let sink = EventSink(s)
        try await withTimeout { await sink.waitEnd() }
        let exit = try #require(sink.exit)
        #expect(exit.errorCode == "server_exited" && exit.error == "opencode serve exited with code 3: panic: boom")
        #expect(!server.alive)
    }

    @Test func launchRetriesAnEarlyExit() async throws {
        let dir = try TempDir()
        let bin = try dir.script(
            "opencode",
            "echo \"$OPENCODE_SERVER_USERNAME $@\" >> \"\(dir.path)/calls\"; echo 'no serve' >&2; exit 1")
        let rt = Runtime(options: .init(useLoginShellPath: false), now: Date.init, probeTimeout: .testProbe)
        await #expect(throws: AgentBinderError.launch("opencode serve exited early: no serve")) {
            _ = try await OpenCodeServer.launch(
                wire: .v1, binary: bin, environment: ["A": "1"], arguments: ["--print-logs"], context: rt.context)
        }
        let calls = (dir.read("calls") ?? "").split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        #expect(calls.count == 3)
        for c in calls {
            #expect(c.first == "opencode" && c.dropFirst().first == "serve" && c.last == "--print-logs")
            #expect(c.contains("--hostname") && c.contains("127.0.0.1"))
        }
        #expect(rt.context.ledger.keys.isEmpty)
    }
}

// MARK: session

@Suite("OpenCodeSessionTests")
struct OpenCodeSessionTests {
    @Test func v1Turn() async throws {
        let rig = try await Rig.make(.v1)
        rig.srv.route("POST", "/session/ses_1/prompt_async", .empty)
        let s = try await rig.v1(model: "opencode-go/kimi-k3")
        let sink = EventSink(s)
        try await s.prompt(Prompt("hi"))
        await #expect(throws: AgentBinderError.turnActive) { try await s.prompt(Prompt("again")) }
        #expect(s.busy)
        rig.push1(
            "message.part.updated",
            #"{"part":{"id":"p","messageID":"m","sessionID":"ses_1","type":"text","text":"po"}}"#)
        rig.push1(
            "message.part.updated",
            #"{"part":{"id":"p","messageID":"m","sessionID":"ses_1","type":"text","text":"pong"}}"#)
        rig.push1("session.idle", #"{"sessionID":"ses_1"}"#)
        try await eventually { sink.events.count("result") == 1 }
        #expect(sink.names() == ["init", "assistant", "assistant", "result"])
        #expect(sink.events.allSatisfy { $0.sessionID == "ses_1" })
        #expect(sink.events.last?.turn == 1)
        let bodies = rig.srv.requests("POST", "/session/ses_1/prompt_async").compactMap(\.json)
        #expect(bodies.count == 1 && bodies[0]["system"] == "rules")
        #expect(bodies[0]["model"] == ["providerID": "opencode-go", "modelID": "kimi-k3"])
        try await s.setModel("opencode-go/deepseek-v4.1-flash")
        try await s.prompt(Prompt("next"))
        try await eventually { rig.srv.requests("POST", "/session/ses_1/prompt_async").count == 2 }
        let next = rig.srv.requests("POST", "/session/ses_1/prompt_async")[1].json
        #expect(next?["system"] == nil && next?.at("model", "modelID") == "deepseek-v4.1-flash")
        await rig.server.stop()
    }

    @Test func failedPromptLeavesNoTurn() async throws {
        let rig = try await Rig.make(.v1)
        rig.srv.route("POST", "/session/ses_1/prompt_async", TestHTTPServer.Reply(status: 500, #"{"error":"down"}"#))
        let s = try await rig.v1()
        await #expect(throws: AgentBinderError.self) { try await s.prompt(Prompt("hi")) }
        #expect(!s.busy)
        await s.close()
        await #expect(throws: AgentBinderError.sessionClosed) { try await s.prompt(Prompt("hi")) }
        await rig.server.stop()
    }

    @Test func sendHoldsUntilTheTurnEnds() async throws {
        let rig = try await Rig.make(.v2)
        rig.srv.route("POST", "/api/session/ses_2/prompt", .json(#"{"data":{"id":"msg_1"}}"#))
        let s = try await rig.v2()
        let sink = EventSink(s)
        #expect(try await s.send(Prompt("first")) == .prompted)
        #expect(try await s.send(Prompt("second")) == .held)
        #expect(try await s.send(Prompt("third")) == .held)
        rig.push2("session.execution.succeeded", #"{"sessionID":"ses_2"}"#)
        try await eventually { rig.srv.requests("POST", "/api/session/ses_2/prompt").count == 2 }
        let texts = rig.srv.requests("POST", "/api/session/ses_2/prompt").compactMap { $0.json?["text"]?.string }
        #expect(texts == ["first", "second\n\nthird"])
        try await eventually { s.busy }
        #expect(sink.events.results.count == 1)
        await rig.server.stop()
    }

    @Test func heldPromptsDropOnEnd() async throws {
        let rig = try await Rig.make(.v2)
        rig.srv.route("POST", "/api/session/ses_2/prompt", .json("{}"))
        let s = try await rig.v2()
        let sink = EventSink(s)
        _ = try await s.send(Prompt("first"))
        _ = try await s.send(Prompt("later"))
        await s.kill()
        await sink.waitEnd()
        let dropped = sink.events.errors.first { $0.code == Outbox.droppedCode }
        #expect(dropped?.text == "later")
        #expect(sink.exit?.errorCode == nil && rig.released.value == 1)
        await rig.server.stop()
    }

    @Test func permissionForwardedAndAnswered() async throws {
        let rig = try await Rig.make(.v2)
        rig.srv.route("POST", "/api/session/ses_2/permission/p1/reply", .json("{}"))
        let s = try await rig.v2()
        let sink = EventSink(s)
        rig.push2("permission.asked", #"{"sessionID":"ses_2","id":"p1","action":"write","message":"Write it?"}"#)
        try await eventually { sink.events.permissions.count == 1 }
        let p = sink.events.permissions[0]
        #expect(p.id == "p1" && p.tool == "write" && p.kind == .edit && p.question == "Write it?")
        try await s.answer("p1", .allow())
        #expect(rig.srv.requests("POST", "/api/session/ses_2/permission/p1/reply").first?.json == ["reply": "once"])
        await rig.server.stop()
    }

    @Test func policyAnswersWithoutAnEvent() async throws {
        let rig = try await Rig.make(.v1)
        rig.srv.route("POST", "/session/ses_1/permissions/p1", .json("true"))
        let s = try await rig.v1(policy: PermissionPolicy(mode: .auto))
        let sink = EventSink(s)
        rig.push1("permission.updated", #"{"id":"p1","sessionID":"ses_1","type":"bash"}"#)
        try await eventually { !rig.srv.requests("POST", "/session/ses_1/permissions/p1").isEmpty }
        let r = rig.srv.requests("POST", "/session/ses_1/permissions/p1")[0]
        #expect(r.json == ["response": "once"] && r.query["directory"] == "/w")
        #expect(sink.events.permissions.isEmpty)
        await rig.server.stop()
    }

    @Test func interruptRoutes() async throws {
        let rig = try await Rig.make(.v2)
        rig.srv.route("POST", "/api/session/ses_2/interrupt", .json("{}"))
        let s = try await rig.v2()
        try await s.interrupt()
        try await s.interrupt()
        #expect(rig.srv.requests("POST", "/api/session/ses_2/interrupt").count == 2)
        let v1 = try await Rig.make(.v1)
        v1.srv.route("POST", "/session/ses_1/abort", .json("true"))
        try await v1.v1().interrupt()
        #expect(v1.srv.requests("POST", "/session/ses_1/abort").first?.json == [:])
        await rig.server.stop()
        await v1.server.stop()
    }

    @Test func setModelV2PostsAtOnce() async throws {
        let rig = try await Rig.make(.v2)
        rig.srv.route("POST", "/api/session/ses_2/model", .json("{}"))
        let s = try await rig.v2()
        try await s.setModel("opencode-go/kimi-k3")
        #expect(
            rig.srv.requests("POST", "/api/session/ses_2/model").first?.json
                == ["model": ["providerID": "opencode-go", "id": "kimi-k3", "variant": "high"]])
        await rig.server.stop()
    }

    @Test func closeInterruptsARunningTurn() async throws {
        let rig = try await Rig.make(.v1)
        rig.srv.route("POST", "/session/ses_1/prompt_async", .empty)
        rig.srv.route("POST", "/session/ses_1/abort", .json("true"))
        let s = try await rig.v1()
        var hooked = false
        let hook = Locked(false)
        s.onClose { hook.withLock { $0 = true } }
        let sink = EventSink(s)
        try await s.prompt(Prompt("x"))
        await s.close()
        await s.close()
        await sink.waitEnd()
        hooked = hook.value
        #expect(hooked && rig.released.value == 1)
        #expect(rig.srv.requests("POST", "/session/ses_1/abort").count == 1)
        #expect(sink.exit.map { $0.code == nil && $0.errorCode == nil } == true)
        let late = Locked(false)
        s.onClose { late.withLock { $0 = true } }
        #expect(late.value)
        rig.push1("session.idle", #"{"sessionID":"ses_1"}"#)
        await rig.server.stop()
    }

    @Test func deletedEndsTheSession() async throws {
        let rig = try await Rig.make(.v1)
        let s = try await rig.v1()
        let sink = EventSink(s)
        rig.push1("session.deleted", #"{"sessionID":"ses_1","info":{"id":"ses_1"}}"#)
        await sink.waitEnd()
        #expect(sink.exit?.code == 0 && sink.exit?.errorCode == "session_deleted")
        #expect(sink.names() == ["init", "exit"])
        await rig.server.stop()
    }

    @Test func cancelledConsumerCloses() async throws {
        let rig = try await Rig.make(.v1)
        let s = try await rig.v1()
        let t = Task { for await _ in s.events {} }
        try await Task.sleep(for: .milliseconds(50))
        t.cancel()
        try await eventually { rig.released.value == 1 }
        await rig.server.stop()
    }

    // Fixed on purpose: sessions on one shared server keep their own ledger keys.
    @Test func sharedSessionsKeepTheirLedgerKeys() async throws {
        let rig = try await Rig.make(.v1)
        let ledger = Ledger(path: nil)
        let a = try await rig.v1("ses_a")
        let b = try await rig.v1("ses_b")
        let ka = ledger.add(a)
        let kb = ledger.add(b)
        #expect(ka != kb && ka.hasPrefix("opencode:shared-"))
        await a.close()
        #expect(ledger.keys == [kb])
        await ledger.closeAll()
        #expect(ledger.keys.isEmpty)
        await rig.server.stop()
    }
}

// MARK: pool

private final class FakeStarter: Sendable {
    let srv: TestHTTPServer
    let calls = Locked<[(OpenCodeWire, [String: String], [String])]>([])
    let fail = Locked(false)
    let delay: Duration

    init(_ srv: TestHTTPServer, delay: Duration = .zero) {
        self.srv = srv
        self.delay = delay
    }

    var starter: OpenCodeServerPool.Starter {
        { [self] w, _, env, args, _ in
            calls.withLock { $0.append((w, env, args)) }
            if delay > .zero { try await Task.sleep(for: delay) }
            if fail.value { throw AgentBinderError.launch("opencode serve: no") }
            return OpenCodeServer(http: srv.http(w))
        }
    }
}

@Suite("OpenCodePoolTests")
struct OpenCodePoolTests {
    private func context(_ ignore: [String] = []) -> RuntimeContext {
        Runtime(options: .init(fingerprintIgnoreEnvironment: ignore, useLoginShellPath: false), now: Date.init).context
    }

    private let bin = URL(fileURLWithPath: "/bin/opencode")

    @Test func sameFingerprintSharesOneServer() async throws {
        let f = FakeStarter(try await TestHTTPServer.start())
        let pool = OpenCodeServerPool(starter: f.starter)
        let ctx = context(["RUN_ID"])
        let a = try await pool.acquire(
            .v1, binary: bin, environment: ["A": "1", "RUN_ID": "1"], arguments: [], context: ctx)
        let b = try await pool.acquire(
            .v1, binary: bin, environment: ["A": "1", "RUN_ID": "2"], arguments: [], context: ctx)
        let c = try await pool.acquire(
            .v1, binary: bin, environment: ["A": "1", "OPENCODE_CONFIG_CONTENT": "{}"], arguments: [], context: ctx)
        let d = try await pool.acquire(.v2, binary: bin, environment: ["A": "1"], arguments: [], context: ctx)
        #expect(a === b && a !== c && c !== d)
        #expect(f.calls.value.count == 3 && f.calls.value.map(\.0) == [.v1, .v1, .v2])
        let refs = await pool.refs(a)
        let count = await pool.servers.count
        #expect(refs == 2 && count == 3)
        await pool.stopAll()
        #expect(!a.alive)
        #expect((await pool.servers).isEmpty)
    }

    @Test func concurrentAcquiresShareOneStart() async throws {
        let f = FakeStarter(try await TestHTTPServer.start(), delay: .milliseconds(100))
        let pool = OpenCodeServerPool(starter: f.starter)
        let ctx = context()
        let bin = bin
        let servers = try await withThrowingTaskGroup(of: OpenCodeServer.self) { g in
            for _ in 0..<4 {
                g.addTask { try await pool.acquire(.v2, binary: bin, environment: [:], arguments: [], context: ctx) }
            }
            var out: [OpenCodeServer] = []
            for try await s in g { out.append(s) }
            return out
        }
        #expect(f.calls.value.count == 1 && servers.allSatisfy { $0 === servers[0] })
        #expect(await pool.refs(servers[0]) == 4)
        await pool.stopAll()
    }

    @Test func idleWindowStopsAndReacquireCancels() async throws {
        let f = FakeStarter(try await TestHTTPServer.start())
        let pool = OpenCodeServerPool(idle: .milliseconds(100), starter: f.starter)
        let ctx = context()
        let a = try await pool.acquire(.v1, binary: bin, environment: [:], arguments: [], context: ctx)
        await pool.release(a)
        let again = try await pool.acquire(.v1, binary: bin, environment: [:], arguments: [], context: ctx)
        #expect(again === a)
        try await Task.sleep(for: .milliseconds(250))
        #expect(a.alive)
        #expect(await pool.refs(a) == 1)
        await pool.release(a)
        try await eventually { !a.alive }
        #expect(await pool.servers.isEmpty)
        await pool.release(a)
    }

    @Test func deadServerIsReplaced() async throws {
        let f = FakeStarter(try await TestHTTPServer.start())
        let pool = OpenCodeServerPool(starter: f.starter)
        let ctx = context()
        let a = try await pool.acquire(.v1, binary: bin, environment: [:], arguments: [], context: ctx)
        await a.stop()
        let b = try await pool.acquire(.v1, binary: bin, environment: [:], arguments: [], context: ctx)
        #expect(a !== b)
        #expect((await pool.servers).count == 1)
        f.fail.withLock { $0 = true }
        await #expect(throws: AgentBinderError.launch("opencode serve: no")) {
            _ = try await pool.acquire(.v1, binary: bin, environment: ["B": "2"], arguments: [], context: ctx)
        }
        await pool.stopAll()
    }
}

// MARK: driver

@Suite("OpenCodeDriverTests")
struct OpenCodeDriverTests {
    /// A runtime with a fake `opencode` binary for `--version` and `models`, and a pool on the test server.
    private func runtime(
        version: String, _ f: FakeStarter, _ dir: TempDir, models: String = ""
    )
        throws -> (Runtime, URL)
    {
        let body = """
            case "$1" in
              --version) echo '\(version)' ;;
              models) printf '\(models)' ;;
              *) exit 1 ;;
            esac
            """
        let bin = try dir.script("opencode", body)
        _ = try dir.script("opencode2", body)
        let rt = Runtime(
            options: .init(binarySearchPaths: [dir.url], useLoginShellPath: false), now: Date.init,
            probeTimeout: .testProbe, openCodePool: OpenCodeServerPool(starter: f.starter))
        return (rt, bin)
    }

    @Test func v1Start() async throws {
        let srv = try await TestHTTPServer.start()
        srv.route("POST", "/session", .json(#"{"id":"ses_new"}"#))
        srv.route("POST", "/session/ses_new/prompt_async", .empty)
        let dir = try TempDir()
        let f = FakeStarter(srv)
        let (rt, _) = try runtime(version: "1.14.3", f, dir)
        var r = request(dir.url)
        r.instructions = "be brief"
        r.extraArguments = ["--print-logs"]
        let s = try await rt.start(r)
        #expect(s.harness == .opencode && s.id == "ses_new" && s is OpenCodeV1Session)
        let sink = EventSink(s)
        try await eventually { sink.names() == ["init"] }
        try await s.prompt(Prompt("hi"))
        #expect(srv.requests("POST", "/session/ses_new/prompt_async").first?.json?["system"] == "be brief")
        #expect(f.calls.value.first?.2 == ["--print-logs"])
        #expect(srv.requests("GET", "/event").first?.query["directory"] == dir.path)
        await rt.close()
        await sink.waitEnd()
    }

    @Test func v2BinaryRoutesToV2() async throws {
        let srv = try await TestHTTPServer.start()
        srv.route("POST", "/api/session", .json(#"{"data":{"id":"ses_v2"}}"#))
        srv.route("PUT", "/api/session/ses_v2/instructions/entries/agentbinder.instructions", .json("{}"))
        let dir = try TempDir()
        let f = FakeStarter(srv)
        let (rt, _) = try runtime(version: "opencode v2.0.26", f, dir)
        var r = request(dir.url)
        r.model = "opencode-go/kimi-k3"
        r.effort = Effort(rawValue: "high")
        r.instructions = "be brief"
        let s = try await rt.start(r)
        // Quirk: an opencode request on a 2.x binary reports opencode2.
        #expect(s.harness == .opencode2 && s.id == "ses_v2")
        let create = try #require(srv.requests("POST", "/api/session").first?.json)
        #expect(create.at("location", "directory")?.string == dir.path)
        #expect(create["model"] == ["providerID": "opencode-go", "id": "kimi-k3", "variant": "high"])
        let put = srv.requests("PUT", "/api/session/ses_v2/instructions/entries/agentbinder.instructions")
        #expect(put.first?.json == ["value": "be brief"])
        #expect(f.calls.value.map(\.0) == [.v2])
        await rt.close()
    }

    @Test func v2Resume() async throws {
        let srv = try await TestHTTPServer.start()
        srv.route("GET", "/api/session/ses_old", .json(#"{"data":{"id":"ses_old"}}"#))
        srv.route("POST", "/api/session/ses_old/model", .json("{}"))
        let dir = try TempDir()
        let (rt, _) = try runtime(version: "2.0.26", FakeStarter(srv), dir)
        var r = request(dir.url, .opencode2)
        r.sessionID = "ses_old"
        r.model = "kimi-k3"
        let s = try await rt.resume(r)
        #expect(s.id == "ses_old" && srv.requests("POST", "/api/session").isEmpty)
        #expect(srv.requests("POST", "/api/session/ses_old/model").first?.json == ["model": ["id": "kimi-k3"]])
        await rt.close()
    }

    @Test func startErrorsReleaseTheServer() async throws {
        let srv = try await TestHTTPServer.start()
        srv.route("POST", "/session", .json(#"{"title":"no id"}"#))
        let dir = try TempDir()
        let pool = OpenCodeServerPool(starter: FakeStarter(srv).starter)
        let bin = try dir.script("opencode", "echo 1.0.0")
        let rt = Runtime(
            options: .init(binarySearchPaths: [dir.url], useLoginShellPath: false), now: Date.init,
            probeTimeout: .testProbe, openCodePool: pool)
        await #expect(throws: AgentBinderError.handshakeFailed("opencode: session has no id")) {
            _ = try await rt.start(request(dir.url))
        }
        var r = request(dir.url)
        r.sessionID = "ses_gone"
        await #expect(throws: AgentBinderError.resumeUnsupported) { _ = try await rt.resume(r) }
        r.sessionID = nil
        await #expect(throws: AgentBinderError.invalidRequest("opencode: resume needs a session id")) {
            _ = try await rt.resume(r)
        }
        srv.route("POST", "/session", TestHTTPServer.Reply(status: 500, #"{"error":"db locked"}"#))
        await #expect(throws: AgentBinderError.self) { _ = try await rt.start(request(dir.url)) }
        let servers = await pool.servers
        #expect(servers.count == 1)
        if let s = servers.first { #expect(await pool.refs(s) == 0) }
        _ = bin
        await rt.close()
    }

    @Test func oneShotEndsAfterTheTurn() async throws {
        let srv = try await TestHTTPServer.start()
        srv.route("POST", "/api/session", .json(#"{"data":{"id":"ses_1"}}"#))
        srv.route("POST", "/api/session/ses_1/prompt", .json("{}"))
        let dir = try TempDir()
        let (rt, _) = try runtime(version: "2.1.0", FakeStarter(srv), dir)
        var r = request(dir.url, .opencode2)
        r.model = "m"
        r.oneShot = OneShot(prompt: "do it")
        let s = try await rt.start(r)
        let sink = EventSink(s)
        #expect(srv.requests("POST", "/api/session/ses_1/prompt").first?.json?["text"] == "do it")
        srv.push(#"{"type":"session.execution.succeeded","data":{"sessionID":"ses_1"}}"#)
        await sink.waitEnd()
        #expect(sink.names() == ["init", "result", "exit"] && sink.exit?.code == 0)
        await rt.close()
    }

    @Test func modelsV1AndV2() async throws {
        let srv = try await TestHTTPServer.start()
        srv.route(
            "GET", "/config/providers",
            .json(String(decoding: try Fixtures.json("models/opencode_providers.json").jsonData, as: UTF8.self)))
        srv.route("GET", "/config", .json(#"{"model":"opencode-go/kimi-k3"}"#))
        let dir = try TempDir()
        let (rt, _) = try runtime(version: "1.14.3", FakeStarter(srv), dir)
        let list = try await rt.models(.opencode)
        #expect(list.map(\.id) == ["opencode-go/deepseek-v4.1-flash", "opencode-go/kimi-k3"])
        #expect(list.filter(\.isDefault).map(\.id) == ["opencode-go/kimi-k3"])
        await rt.close()

        let srv2 = try await TestHTTPServer.start()
        let polls = Locked(0)
        let raw = String(decoding: try Fixtures.json("models/opencode2_models.json").jsonData, as: UTF8.self)
        // Quirk: a new server answers an empty list first.
        srv2.on { r in
            guard r.path == "/api/model" else { return nil }
            let n = polls.withLock { p -> Int in
                p += 1
                return p
            }
            return n == 1 ? .json(#"{"data":[]}"#) : .json(raw)
        }
        srv2.route("GET", "/api/model/default", .json(#"{"data":{"modelID":"kimi-k3","providerID":"opencode-go"}}"#))
        let dir2 = try TempDir()
        let (rt2, _) = try runtime(version: "2.0.26", FakeStarter(srv2), dir2)
        let list2 = try await rt2.models(.opencode2)
        #expect(list2.map(\.id) == ["opencode-go/deepseek-v4.1-flash", "opencode-go/kimi-k3"])
        #expect(polls.value == 2 && list2.filter(\.isDefault).map(\.id) == ["opencode-go/kimi-k3"])
        #expect(srv2.requests("GET", "/api/model").first?.query["location[directory]"] != nil)
        await rt2.close()
    }

    @Test func modelsFallBackToTheCLI() async throws {
        let srv = try await TestHTTPServer.start()
        let dir = try TempDir()
        let f = FakeStarter(srv)
        f.fail.withLock { $0 = true }
        let (rt, _) = try runtime(version: "1.14.3", f, dir, models: "zeta/z\\nalpha/a\\nnot one\\n")
        #expect(try await rt.models(.opencode).map(\.id) == ["alpha/a", "zeta/z"])
        await rt.close()
        let empty = try TempDir()
        let (rt2, _) = try runtime(version: "1.14.3", f, empty)
        await #expect(throws: AgentBinderError.launch("opencode serve: no")) { _ = try await rt2.models(.opencode) }
    }

    @Test func drivers() async {
        let rt = Runtime(options: .init(useLoginShellPath: false))
        #expect(await rt.driver(for: .opencode)?.name == "opencode")
        #expect(await rt.driver(for: .opencode2) is OpenCodeDriver)
    }
}
