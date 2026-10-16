import Darwin
import Foundation
import Testing

@testable import AgentBinder

// Escapes one stdin line for a JSON string in a fake script.
private let esc = #"esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }"#

private let vocabulary = """
    echo '{"type":"init","session_id":"s1"}'
    echo '{"type":"assistant","text":"hello"}'
    echo '{"type":"tool","id":"t1","name":"Bash","status":"started"}'
    echo '{"type":"tool","id":"t1","name":"Bash","status":"completed"}'
    echo '{"type":"permission","id":"p1","tool":"Bash","question":"run it?"}'
    echo '{"type":"result","subtype":"success","text":"done"}'
    """

@Suite("FakeHarnessTests")
struct FakeHarnessTests {
    let dir: TempDir

    init() throws { dir = try TempDir() }

    private func runtime(_ env: [String: String] = [:]) -> Runtime {
        Runtime(options: .init(useLoginShellPath: false, environment: env))
    }

    private func start(
        _ driver: FakeDriver? = nil, rt: Runtime? = nil, _ change: (inout StartRequest) -> Void = { _ in }
    ) async throws -> (Runtime, any Session) {
        let rt = rt ?? runtime()
        if let driver { await rt.setDriver(driver, for: .fake) }
        var r = StartRequest(harness: .fake, workingDirectory: dir.url)
        change(&r)
        return (rt, try await rt.start(r))
    }

    @Test func vocabularyOrder() async throws {
        let (rt, s) = try await start(FakeDriver(script: vocabulary))
        let events = try await withTimeout { await s.events.collect() }
        #expect(events.map(\.kind.name) == ["init", "assistant", "tool", "tool", "permission", "result", "exit"])
        #expect(s.id == "s1")
        #expect(events[1].assistantText == "hello" && events[1].sessionID == "s1")
        guard case .tool(let start) = events[2].kind, case .tool(let end) = events[3].kind else {
            Issue.record("no tool events")
            return
        }
        #expect(start.id == "t1" && start.name == "Bash" && start.kind == .exec && start.status == .started)
        #expect(end.status == .completed)
        guard case .permission(let p) = events[4].kind else { return }
        #expect(p.id == "p1" && p.tool == "Bash" && p.question == "run it?")
        guard case .exit(let code, let error, _) = events.last?.kind else { return }
        #expect(code == 0 && error == nil)
        await rt.close()
    }

    @Test func builtInDriverReadsTheEnvironmentScript() async throws {
        let rt = runtime([
            FakeDriver.scriptEnvironmentKey:
                #"echo '{"type":"init","session_id":"env-1"}'; echo '{"type":"assistant","text":"from-env"}'"#
        ])
        #expect(await rt.driver(for: .fake)?.name == "fake")
        let d = await rt.detect(.fake)
        #expect(d.ready)
        let (_, s) = try await start(rt: rt)
        let events = try await withTimeout { await s.events.collect() }
        #expect(events.map(\.kind.name) == ["init", "assistant", "exit"])
        #expect(events[0].sessionID == "env-1" && events[1].assistantText == "from-env")
        await rt.close()
    }

    @Test func defaultScriptTurn() async throws {
        let (rt, s) = try await start(FakeDriver())
        try await s.prompt(Prompt("hi"))
        let first = await s.events.next(where: { $0.assistantText != nil })
        #expect(first?.assistantText == "working")
        #expect(first?.turn == 1)
        let rest = Task { await s.events.collect() }
        await s.close()
        let events = await rest.value
        #expect(events.map(\.kind.name) == ["result", "exit"])
        #expect(events.last?.isExit == true)
        await rt.close()
    }

    @Test func oneShotEndsAfterTheTurn() async throws {
        let (rt, s) = try await start(FakeDriver()) { $0.oneShot = OneShot(prompt: "job") }
        let events = try await withTimeout { await s.events.collect() }
        #expect(events.map(\.kind.name) == ["assistant", "result", "exit"])
        guard case .result(let r) = events[1].kind else { return }
        #expect(r.text == "done" && !r.isError)
        await rt.close()
    }

    @Test func steerDuringATurn() async throws {
        let (rt, s) = try await start(FakeDriver())
        try await s.prompt(Prompt("hi"))
        _ = await s.events.next(where: { $0.assistantText != nil })
        #expect(try await s.send(Prompt("more")) == .steered)
        let echo = await s.events.next(where: {
            if case .user = $0.kind { return true }
            return false
        })
        guard case .user(let text)? = echo?.kind else {
            Issue.record("no echo")
            return
        }
        #expect(text == #"got: {"text":"more","type":"steer"}"#)
        #expect(await s.events.next(where: \.isResult) != nil)
        await s.close()
        await rt.close()
    }

    @Test func steerWithoutATurn() async throws {
        let (rt, s) = try await start(FakeDriver())
        let steer = try #require(s as? any Steerable)
        await #expect(throws: AgentBinderError.noActiveTurn) { try await steer.steer(Prompt("x")) }
        await s.close()
        await rt.close()
    }

    @Test func sendHoldsWhenTheScriptCannotSteer() async throws {
        let gate = dir.url.appendingPathComponent("gate").path
        let script = """
            \(esc)
            read -r a
            echo '{"type":"assistant","text":"one"}'
            while [ ! -f '\(gate)' ]; do sleep 0.02; done
            echo '{"type":"result","subtype":"success"}'
            read -r b
            printf '{"type":"user","text":"%s"}\\n' "$(esc "$b")"
            echo '{"type":"result","subtype":"success"}'
            """
        let (rt, s) = try await start(FakeDriver(script: script, steers: false))
        try await s.prompt(Prompt("first"))
        _ = await s.events.next(where: { $0.assistantText != nil })
        #expect(try await s.send(Prompt("x")) == .held)
        #expect(try await s.send(Prompt("y")) == .held)
        FileManager.default.createFile(atPath: gate, contents: nil)
        let events = try await withTimeout { await s.events.collect() }
        let users = events.compactMap { e -> String? in
            if case .user(let t) = e.kind { return t }
            return nil
        }
        #expect(users == [#"{"text":"x\n\ny","type":"user"}"#])
        #expect(events.filter(\.isResult).map(\.turn) == [1, 2])
        await rt.close()
    }

    @Test func permissionRoundTrip() async throws {
        let seen = dir.url.appendingPathComponent("decision")
        let script = """
            read -r a
            echo '{"type":"permission","id":"p1","tool":"Bash"}'
            read -r d
            printf '%s\\n' "$d" > '\(seen.path)'
            echo '{"type":"result","subtype":"success"}'
            """
        let (rt, s) = try await start(FakeDriver(script: script)) {
            $0.permissions = PermissionPolicy(mode: .ask)
        }
        try await s.prompt(Prompt("go"))
        let ask = await s.events.next(where: {
            if case .permission = $0.kind { return true }
            return false
        })
        guard case .permission(let p)? = ask?.kind else {
            Issue.record("no permission")
            return
        }
        try await s.answer(p.id, .deny("no"))
        _ = try await withTimeout { await s.events.collect() }
        let line = try #require(JSONValue.parse(try String(contentsOf: seen, encoding: .utf8)))
        #expect(line == .object(["type": "decision", "id": "p1", "allow": false, "message": "no"]))
        await rt.close()
    }

    @Test func setModelWritesTheLine() async throws {
        let seen = dir.url.appendingPathComponent("model")
        let script = "read -r m; printf '%s\\n' \"$m\" > '\(seen.path)'"
        let (rt, s) = try await start(FakeDriver(script: script))
        let ms = try #require(s as? any ModelSettable)
        try await ms.setModel("m2")
        _ = try await withTimeout { await s.events.collect() }
        let line = try #require(JSONValue.parse(try String(contentsOf: seen, encoding: .utf8)))
        #expect(line == .object(["type": "set_model", "model": "m2"]))
        await rt.close()
    }

    @Test func offeredModelsFromInit() async throws {
        let script = #"echo '{"type":"init","models":[{"id":"a","default":true},{"id":"b"}]}'; read -r x || true"#
        let (rt, s) = try await start(FakeDriver(script: script))
        let listing = try #require(s as? any SessionModelListing)
        try await eventually { await !listing.offeredModels.isEmpty }
        #expect(await listing.offeredModels == [ModelInfo(id: "a", isDefault: true), ModelInfo(id: "b")])
        await rt.close()
    }

    @Test func modelLists() async throws {
        let rt = runtime([FakeDriver.modelsEnvironmentKey: #"[{"id":"env-1","default":true},{"id":"env-2"}]"#])
        #expect(try await rt.models(.fake).map(\.id) == ["env-1", "env-2"])

        let other = runtime()
        await other.setDriver(FakeDriver(modelList: [ModelInfo(id: "set")]), for: .fake)
        #expect(try await other.models(.fake).map(\.id) == ["set"])

        #expect(try await runtime().models(.fake).isEmpty)

        let bad = runtime([FakeDriver.modelsEnvironmentKey: "not json"])
        await #expect(throws: AgentBinderError.self) { try await bad.models(.fake) }
    }

    @Test func resultUsageAndSessionID() async throws {
        let script =
            #"echo '{"type":"result","subtype":"success","session_id":"s2","usage":{"input":12,"output":4,"model":"m1"}}'"#
        let (rt, s) = try await start(FakeDriver(script: script))
        let events = try await withTimeout { await s.events.collect() }
        guard case .result(let r) = events.first?.kind else {
            Issue.record("no result")
            return
        }
        #expect(r.sessionID == "s2")
        #expect(r.usage == Usage(input: 12, output: 4, model: "m1"))
        #expect(s.id == "s2")
        await rt.close()
    }

    @Test func resumeKeepsTheID() async throws {
        let rt = runtime()
        await rt.setDriver(FakeDriver(script: "read -r x || true"), for: .fake)
        let s = try await rt.resume(StartRequest(harness: .fake, workingDirectory: dir.url, sessionID: "old-1"))
        #expect(s.id == "old-1")
        await rt.close()
    }

    @Test func nonZeroExit() async throws {
        let (rt, s) = try await start(FakeDriver(script: "echo boom >&2; echo more >&2; exit 2"))
        let events = try await withTimeout { await s.events.collect() }
        #expect(events.map(\.kind.name) == ["error", "exit"])
        #expect(events[0].errorCode == "process_exited")
        guard case .exit(let code, let error, let errorCode) = events[1].kind else { return }
        #expect(code == 2)
        #expect(error == "boom")
        #expect(errorCode == "process_exited")
        #expect(s.lastError?.code == "process_exited")
        await rt.close()
    }

    @Test func cancelledConsumerKillsTheChild() async throws {
        let (rt, s) = try await start(FakeDriver(script: "cat"))
        let pid = try #require(s.pid)
        #expect(ProcessGroup.alive(pid))
        let reader = Task { await s.events.collect() }
        try await Task.sleep(for: .milliseconds(50))
        reader.cancel()
        try await eventually(timeout: .seconds(10)) { !ProcessGroup.alive(pid) }
        await rt.close()
    }

    @Test func runtimeCloseEndsThreeSessions() async throws {
        let rt = runtime()
        await rt.setDriver(FakeDriver(script: "cat"), for: .fake)
        var sessions: [any Session] = []
        for _ in 0..<3 { sessions.append(try await rt.start(StartRequest(harness: .fake, workingDirectory: dir.url))) }
        let pids = sessions.compactMap(\.pid)
        let readers = sessions.map { s in Task { await s.events.collect() } }
        try await withTimeout(.seconds(20)) { await rt.close() }
        for r in readers { #expect(await r.value.last?.isExit == true) }
        for pid in pids { #expect(!ProcessGroup.alive(pid)) }
    }

    @Test func recordWritesAFixture() async throws {
        let rec = dir.url.appendingPathComponent("rec")
        let rt = runtime([RuntimeContext.recordEnvironmentKey: rec.path])
        let (_, s) = try await start(FakeDriver(script: vocabulary), rt: rt)
        _ = try await withTimeout { await s.events.collect() }
        let files = try FileManager.default.contentsOfDirectory(atPath: rec.path)
        #expect(files.count == 1)
        let name = try #require(files.first)
        #expect(name.hasPrefix("fake-") && name.hasSuffix(".ndjson"))
        let text = try String(contentsOf: rec.appendingPathComponent(name), encoding: .utf8)
        let want = vocabulary.split(separator: "\n").map { $0.dropFirst(6).dropLast(1) }.joined(separator: "\n")
        #expect(text == want + "\n")
        await rt.close()
    }
}

@Suite("FixtureTests")
struct FixtureTests {
    @Test func fakeVocabularyGolden() throws {
        let rel = "fake/vocabulary.ndjson"
        let adapter = FakeAdapter(steers: true)
        let events = try Fixtures.parse(rel, adapter)
        #expect(events.count == 10)
        #expect(adapter.offeredModels.map(\.id) == ["m1", "m2"])
        try Fixtures.expectGolden(rel, events)
    }

    @Test func importedFixturesParseAsJSON() throws {
        let claude = Fixtures.list("claude")
        #expect(claude.count == 9)
        for rel in claude {
            for line in try Fixtures.lines(rel) { #expect(JSONValue.parse(line) != nil, "\(rel)") }
        }
        let models = Fixtures.list("models", ext: "json")
        #expect(models.count == 8)
        for rel in models { _ = try Fixtures.json(rel) }
    }
}

@Suite("ScriptedPeerTests")
struct ScriptedPeerTests {
    @Test func stepsReplyInOrder() async throws {
        let peer = ScriptedPeer()
        peer.expect(type: "hello") { _ in [#"{"type":"init","id":"peer-1"}"#] }
        peer.expect(type: "user") { req in
            [#"{"type":"assistant","text":"echo \#(req["text"]?.string ?? "")"}"#, #"{"type":"result"}"#]
        }
        let adapter = LineAdapter(
            .init(handshake: { w in
                try await w.write(JSONValue.object(["type": "hello"]))
                return []
            }))
        let s = try await peer.session(adapter)
        let first = await s.events.next(where: { _ in true })
        #expect(s.id == "peer-1")
        #expect(first?.sessionID == "peer-1")
        try await s.prompt(Prompt("ping"))
        let reply = await s.events.next(where: { $0.assistantText != nil })
        #expect(reply?.assistantText == "echo ping")
        try await s.answer("x", .allow())
        #expect(peer.pending == 0)
        #expect(peer.unmatched.map { $0["type"]?.string } == ["decision"])
        #expect(peer.seen.count == 3)
        peer.end()
        let rest = await s.events.collect()
        #expect(rest.last?.isExit == true)
    }
}
