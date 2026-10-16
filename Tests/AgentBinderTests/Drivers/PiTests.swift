import Foundation
import Testing

@testable import AgentBinder

private func ok(_ req: JSONValue, _ data: String = "{}") -> String {
    #"{"type":"response","id":"\#(req["id"].stringValue)","command":"\#(req["type"].stringValue)","success":true,"data":\#(data)}"#
}

private func refused(_ req: JSONValue, _ error: String) -> String {
    #"{"type":"response","id":"\#(req["id"].stringValue)","command":"\#(req["type"].stringValue)","success":false,"error":"\#(error)"}"#
}

private func parse(_ a: PiAdapter, _ lines: String...) -> [Event] {
    lines.flatMap { a.parse(Data($0.utf8)) }
}

private let agentEnd = #"{"type":"agent_end","messages":[]}"#

extension ScriptedPeer {
    fileprivate func frames(type: String) -> [JSONValue] { seen.filter { $0["type"]?.string == type } }
}

// MARK: fixtures

@Suite("PiFixtureTests")
struct PiFixtureTests {
    static let all = Fixtures.list("pi")

    @Test(arguments: all) func golden(_ rel: String) throws {
        try Fixtures.expectGolden(rel, try Fixtures.parse(rel, PiAdapter()))
    }

    @Test func lifecycle() throws {
        let a = PiAdapter()
        _ = try a.encodePrompt(Prompt("ping"))
        let evs = try Fixtures.parse("pi/lifecycle.ndjson", a)
        #expect(evs.map(\.kind.name) == ["status", "status", "assistant", "usage", "result"])
        #expect(evs.compactMap(\.assistantText) == ["PONG"])
        if case .assistant(_, let delta) = evs[2].kind { #expect(!delta) }
        if case .usage(let u) = evs[3].kind {
            #expect(u == Usage(input: 1, output: 2, cacheRead: 3, costUSD: 0.001))
        }
        #expect(evs.results == [TurnResult(subtype: "success")])
        #expect(!a.turnActive)
        let next = try a.encodePrompt(Prompt("hi"))
        #expect(JSONValue.parse(next)?["message"] == "hi")
    }

    @Test func shapes() throws {
        let evs = try Fixtures.parse("pi/shapes.ndjson", PiAdapter())
        #expect(evs.first?.kind.name == "init" && evs.first?.sessionID == "ses_9")
        let tools = evs.tools
        #expect(tools.map(\.id) == ["call_1", "call_1", "call_9", "call_9", "t1", "t1", "t2"])
        #expect(tools[0].kind == .exec && tools[0].status == .started && tools[0].input == #"{"command":"ls"}"#)
        #expect(tools[1].status == .completed && tools[1].output == "ok")
        #expect(tools[2].kind == .edit && tools[2].status == .started && tools[3].status == .completed)
        #expect(tools[4].paths == ["/tmp/a.txt"] && tools[4].input == #"{"path":"/tmp/a.txt"}"#)
        #expect(tools[5].status == .completed && tools[5].output == "done")
        #expect(tools[6].status == .failed && tools[6].output == "boom" && tools[6].kind == .exec)
        let texts = evs.compactMap { e -> String? in
            guard case .assistant(let t, let delta) = e.kind else { return nil }
            return "\(t):\(delta)"
        }
        #expect(texts == ["all done:false", "PO:true", "whole:false", "hello:false"])
        let usage = evs.compactMap { e -> Usage? in
            if case .usage(let u) = e.kind { return u }
            return nil
        }
        #expect(usage == [Usage(input: 10, output: 4, cacheRead: 2, cacheCreation: 1, costUSD: 0.25)])
    }
}

// MARK: adapter

@Suite("PiAdapterTests")
struct PiAdapterTests {
    @Test func errorFrame() throws {
        let a = PiAdapter()
        _ = try a.encodePrompt(Prompt("x"))
        let evs = parse(a, #"{"type":"error","error":"invalid api key"}"#, agentEnd)
        let e = try #require(evs.errors.first)
        #expect(e.endReason == .auth && e.code.hasPrefix("pi."))
        let r = try #require(evs.results.first)
        #expect(
            r.isError && r.subtype == "error_during_execution" && r.endReason == .auth && r.text == "invalid api key")
        #expect(
            parse(PiAdapter(), #"{"type":"error","error":{"status":500}}"#).errors.map(\.message) == [
                #"{"status":500}"#
            ])
    }

    @Test func providerErrorOnMessage() throws {
        let a = PiAdapter()
        _ = try a.encodePrompt(Prompt("x"))
        let evs = parse(
            a,
            #"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"OAuth refresh failed for xai: invalid_grant"}}"#,
            agentEnd)
        let r = try #require(evs.results.first)
        #expect(r.isError && r.endReason == .auth && r.text.contains("invalid_grant"))
        _ = try a.encodePrompt(Prompt("y"))
        let stop = parse(a, #"{"type":"turn_end","message":{"stopReason":"error"}}"#, agentEnd)
        #expect(stop.results.first?.text == "pi turn ended with stopReason error")
    }

    // Fixed on purpose: the error of one turn does not fail the next turn.
    @Test func errorResetsEachTurn() throws {
        let a = PiAdapter()
        _ = try a.encodePrompt(Prompt("x"))
        #expect(parse(a, #"{"type":"error","error":"boom"}"#, agentEnd).results.first?.isError == true)
        _ = try a.encodePrompt(Prompt("y"))
        #expect(parse(a, agentEnd).results == [TurnResult(subtype: "success")])
    }

    @Test func promptFrame() throws {
        let a = PiAdapter(instructions: "Be terse.")
        let first = try #require(JSONValue.parse(try a.encodePrompt(Prompt("one"))))
        #expect(first["type"] == "prompt" && first["id"] == "aw-1")
        #expect(first["message"] == "<session-instructions>\nBe terse.\n</session-instructions>\n\none")
        #expect(throws: AgentBinderError.turnActive) { try a.encodePrompt(Prompt("x")) }
        _ = parse(a, agentEnd)
        #expect(JSONValue.parse(try a.encodePrompt(Prompt("two")))?["message"] == "two")
        let blank = PiAdapter(instructions: "   ")
        #expect(JSONValue.parse(try blank.encodePrompt(Prompt("plain")))?["message"] == "plain")
    }

    @Test func attachmentsAreUnsupported() {
        let a = PiAdapter()
        let p = Prompt("x", attachments: [PromptAttachment(mime: "text/plain", source: .data(Data("n".utf8)))])
        #expect(throws: AgentBinderError.unsupported("pi does not accept prompt attachments")) {
            try a.encodePrompt(p)
        }
        #expect(!a.turnActive)
    }

    // Fixed on purpose: the prompt has an id, so a refused prompt ends the turn with an error.
    @Test(arguments: [#""id":"aw-1","#, ""])
    func refusedPrompt(_ id: String) throws {
        let a = PiAdapter()
        _ = try a.encodePrompt(Prompt("x"))
        let evs = parse(a, #"{"type":"response",\#(id)"command":"prompt","success":false,"error":"busy"}"#)
        #expect(evs.errors.map(\.message) == ["\(AgentBinderError.vendor(code: 0, message: "pi prompt: busy"))"])
        #expect(!a.turnActive)
    }

    @Test func acceptedPrompt() throws {
        let a = PiAdapter()
        _ = try a.encodePrompt(Prompt("x"))
        #expect(parse(a, #"{"type":"response","id":"aw-1","command":"prompt","success":true}"#).isEmpty)
        #expect(a.turnActive)
        // A late ack of no prompt is dropped.
        #expect(parse(a, #"{"type":"response","id":"aw-7","command":"prompt","success":false}"#).isEmpty)
    }

    @Test func frames() throws {
        let a = PiAdapter()
        #expect(String(decoding: try a.encodeInterrupt(), as: UTF8.self) == #"{"type":"abort"}"# + "\n")
        #expect(
            JSONValue.parse(try a.encodeDecision(id: "perm_1", .deny("no")))
                == ["type": "permission_response", "id": "perm_1", "approved": false, "message": "no"])
        #expect(JSONValue.parse(try a.encodeDecision(id: "p", .allow()))?["message"] == "")
    }

    @Test func permissionEvent() throws {
        let a = PiAdapter()
        let evs = parse(a, #"{"type":"permission_request","id":"perm_1","tool":"bash","message":"Allow bash?"}"#)
        guard case .permission(let p) = try #require(evs.first).kind else { return }
        #expect(p == PermissionRequest(id: "perm_1", tool: "bash", kind: .exec, question: "Allow bash?"))
        let other = parse(a, #"{"type":"permission","id":"p2","tool":"read"}"#)
        guard case .permission(let p2) = try #require(other.first).kind else { return }
        #expect(p2.question == "pi requests permission" && p2.kind == .read)
    }

    @Test func usage() {
        #expect(PiAdapter.usage(["input": 0, "output": 0, "cost": ["total": 1]]) == nil)
        #expect(PiAdapter.usage(nil) == nil)
        #expect(PiAdapter.usage(["output": 3]) == Usage(output: 3))
    }

    @Test func exitEvents() throws {
        // Fixed on purpose: an idle session that ends with code 0 is quiet.
        #expect(PiAdapter().exitEvents(code: 0, stderr: "").isEmpty)
        #expect(
            PiAdapter().exitEvents(code: 2, stderr: "").errors.map(\.message) == [
                "pi exited with code 2 before agent_end"
            ])
        let a = PiAdapter()
        _ = try a.encodePrompt(Prompt("x"))
        #expect(a.exitEvents(code: 0, stderr: " rate limit exceeded \n").errors.map(\.code) == ["pi.rate_limited"])
        let b = PiAdapter()
        _ = try b.encodePrompt(Prompt("x"))
        _ = parse(b, #"{"type":"error","error":"boom"}"#)
        #expect(b.exitEvents(code: 1, stderr: "").errors.map(\.message) == ["boom"])
        _ = parse(b, agentEnd)
        #expect(b.exitEvents(code: 1, stderr: "x").isEmpty)
    }

    @Test func models() throws {
        var list = try PiDriver.models(try #require(try Fixtures.json("models/pi_available_models.json")["data"]))
        PiDriver.markDefault(&list, try #require(try Fixtures.json("models/pi_state.json")["data"]))
        #expect(list.map(\.id) == ["xai/grok-4.5", "zai/glm-5.3"])
        #expect(list.filter(\.isDefault).map(\.id) == ["xai/grok-4.5"])
        #expect(list.first?.description == "256K context" && list.first?.name == "Grok 4.5")
        #expect(try PiDriver.models(["models": [["id": "x"], ["provider": "p"]]]).isEmpty)
        #expect(throws: AgentBinderError.self) { try PiDriver.models([:]) }
    }

    @Test(arguments: [
        (0, ""), (999, "999 context"), (256_000, "256K context"), (1_000_000, "1M context"),
        (1_500_000, "1500K context"),
    ])
    func contextText(_ n: Int, _ want: String) { #expect(ModelInfo.contextText(n) == want) }
}

// MARK: wire

@Suite("PiWireTests")
struct PiWireTests {
    private func session(_ peer: ScriptedPeer, _ a: PiAdapter = PiAdapter()) async throws -> (PiSession, PiAdapter) {
        let w = try await peer.session(a, harness: .pi)
        return (PiSession(wire: w, adapter: a), a)
    }

    @Test func setModel() async throws {
        let peer = ScriptedPeer()
        peer.expect(type: "set_model") { [ok($0)] }
        peer.expect(type: "set_model") { [refused($0, "Model not found: nope/x")] }
        let (s, _) = try await session(peer)
        try await s.setModel("zai/glm-5.3")
        var frame = peer.frames(type: "set_model").first?.object
        frame?["id"] = nil
        #expect(frame == ["type": "set_model", "provider": "zai", "modelId": "glm-5.3"])
        await #expect(throws: AgentBinderError.vendor(code: 0, message: "pi set_model: Model not found: nope/x")) {
            try await s.setModel("nope/x")
        }
        await #expect(throws: AgentBinderError.invalidRequest(#"pi: model "noslash" is not provider/model"#)) {
            try await s.setModel("noslash")
        }
        await #expect(throws: AgentBinderError.self) { try await s.setModel("/x") }
        await s.kill()
    }

    @Test func steer() async throws {
        let peer = ScriptedPeer()
        peer.expect(type: "steer") { [ok($0)] }
        peer.expect(type: "steer") { [refused($0, "not streaming")] }
        let (s, a) = try await session(peer)
        await #expect(throws: AgentBinderError.noActiveTurn) { try await s.steer(Prompt("early")) }
        try await s.prompt(Prompt("go"))
        try await s.steer(Prompt("more"))
        #expect(peer.frames(type: "steer").first?["message"] == "more")
        await #expect(throws: AgentBinderError.self) { try await s.steer(Prompt("refuse")) }
        let p = Prompt("x", attachments: [PromptAttachment(mime: "text/plain", source: .data(Data("n".utf8)))])
        await #expect(throws: AgentBinderError.unsupported("pi does not accept steer attachments")) {
            try await s.steer(p)
        }
        peer.send(agentEnd)
        try await eventually { !a.turnActive }
        await #expect(throws: AgentBinderError.noActiveTurn) { try await s.steer(Prompt("late")) }
        await s.kill()
    }

    @Test func refusedSteerIsUnsupported() async throws {
        let peer = ScriptedPeer()
        peer.expect(type: "steer") { [refused($0, "not streaming")] }
        let (s, _) = try await session(peer)
        try await s.prompt(Prompt("go"))
        do {
            try await s.steer(Prompt("refuse"))
            Issue.record("steer did not throw")
        } catch let e as AgentBinderError {
            #expect(e.code == "unsupported" && "\(e)".contains("pi steer: ") && "\(e)".contains("not streaming"))
        }
        await s.kill()
    }

    // A prompt during a turn goes out as a steer.
    @Test func sendSteers() async throws {
        let peer = ScriptedPeer()
        peer.expect(type: "steer") { [ok($0)] }
        let (s, _) = try await session(peer)
        try await s.prompt(Prompt("go"))
        _ = try await s.send(Prompt("also"))
        try await eventually { !peer.frames(type: "steer").isEmpty }
        #expect(peer.frames(type: "prompt").count == 1)
        await s.kill()
    }

    @Test func stateGivesTheSessionID() async throws {
        let peer = ScriptedPeer()
        peer.expect(type: "get_state") { [ok($0, #"{"sessionId":"01a1","isStreaming":false}"#)] }
        let (s, _) = try await session(peer)
        try await eventually { s.id == "01a1" }
        await s.kill()
    }

    @Test func commandTimeout() async throws {
        let peer = ScriptedPeer()
        let (s, a) = try await session(peer)
        await #expect(throws: AgentBinderError.timeout("pi get_state")) {
            try await a.commands.request(["type": "get_state"], timeout: .milliseconds(50))
        }
        await s.kill()
    }

    @Test func exitFailsTheWaitingCommands() async throws {
        let peer = ScriptedPeer()
        let (s, a) = try await session(peer)
        let t = Task { try await a.commands.request(["type": "get_state"]) }
        try await eventually { !peer.frames(type: "get_state").isEmpty }
        _ = a.exitEvents(code: 0, stderr: "")
        await #expect(throws: AgentBinderError.sessionClosed) { try await t.value }
        await #expect(throws: AgentBinderError.sessionClosed) { try await a.commands.request(["type": "x"]) }
        // A reply after the exit has no caller.
        #expect(!a.commands.deliver(["type": "response", "id": "aw-1", "success": true]))
        await s.kill()
    }

    @Test func autoPermission() async throws {
        let peer = ScriptedPeer()
        let (s, _) = try await session(peer, PiAdapter(policy: PermissionPolicy(mode: .auto)))
        peer.send(#"{"type":"permission_request","id":"perm_1","tool":"bash","message":"Allow bash?"}"#)
        try await eventually { !peer.frames(type: "permission_response").isEmpty }
        #expect(
            peer.frames(type: "permission_response") == [
                ["type": "permission_response", "id": "perm_1", "approved": true, "message": ""]
            ])
        await s.kill()
    }

    @Test func askPermission() async throws {
        let peer = ScriptedPeer()
        let (s, _) = try await session(peer)
        peer.send(#"{"type":"permission_request","id":"perm_1","tool":"bash","message":"Allow bash?"}"#)
        let e = try await withTimeout { await s.events.next { $0.kind.name == "permission" } }
        #expect(e != nil && peer.frames(type: "permission_response").isEmpty)
        try await s.answer("perm_1", .deny("no"))
        #expect(peer.frames(type: "permission_response").first?["approved"] == false)
        #expect(peer.frames(type: "permission_response").first?["message"] == "no")
        await s.kill()
    }

    @Test func interrupt() async throws {
        let peer = ScriptedPeer()
        let (s, _) = try await session(peer)
        try await s.prompt(Prompt("go"))
        try await s.interrupt()
        #expect(peer.frames(type: "abort").count == 1)
        await s.kill()
    }
}

// MARK: driver

/// A fake `pi --mode rpc`. It records its argv, its home environment and each line that it reads.
private struct FakePi {
    let dir: TempDir

    init(help: String = "") throws {
        dir = try TempDir()
        let models = Fixtures.url("models/pi_available_models.json").path
        let state = Fixtures.url("models/pi_state.json").path
        try dir.script(
            "pi",
            """
            case "$1" in --help) echo '\(help)'; exit 0 ;; esac
            printf '%s\\n' "$@" > '\(dir.path)/argv.txt'
            printf '%s\\n' "$PI_CODING_AGENT_DIR" "$PI_SKIP_VERSION_CHECK" "$PI_TELEMETRY" > '\(dir.path)/env.txt'
            with_id() { sed "s/^{\\"type\\":\\"response\\"/{\\"id\\":\\"$id\\",\\"type\\":\\"response\\"/" "$1"; }
            while IFS= read -r line; do
              printf '%s\\n' "$line" >> '\(dir.path)/in.txt'
              id=$(printf '%s' "$line" | sed -n 's/^.*"id":"\\(aw-[0-9]*\\)".*$/\\1/p')
              case "$line" in
                *'"type":"prompt"'*)
                  printf '{"type":"response","id":"%s","command":"prompt","success":true}\\n' "$id"
                  echo '{"type":"agent_start"}'
                  echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"PONG"}]}}'
                  echo '{"type":"agent_end","messages":[]}' ;;
                *'"type":"get_available_models"'*) with_id '\(models)' ;;
                *'"type":"get_state"'*) with_id '\(state)' ;;
              esac
            done
            """)
    }

    func runtime() -> Runtime {
        Runtime(
            options: Runtime.Options(
                binarySearchPaths: [dir.url, URL(fileURLWithPath: "/usr/bin"), URL(fileURLWithPath: "/bin")],
                useLoginShellPath: false),
            now: Date.init, probeTimeout: .testProbe)
    }

    func lines(_ name: String) -> [String] {
        (dir.read(name) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLast()
    }
    func input() -> [JSONValue] { lines("in.txt").compactMap { JSONValue.parse($0) } }
}

@Suite("PiDriverTests")
struct PiDriverTests {
    @Test(arguments: [
        (
            false, PermissionPolicy.Mode.auto,
            ["--session-id", "pi-1", "--model", "xai/grok-4.5", "--effort", "low", "--approve", "--mode", "rpc"]
        ),
        (true, .ask, ["--session", "pi-1", "--model", "xai/grok-4.5", "--effort", "low", "--mode", "rpc"]),
    ])
    func launch(_ resume: Bool, _ mode: PermissionPolicy.Mode, _ want: [String]) async throws {
        let bin = try FakePi()
        let home = try TempDir()
        let rt = bin.runtime()
        let r = StartRequest(
            harness: .pi, workingDirectory: bin.dir.url, home: home.url, sessionID: "pi-1", model: "xai/grok-4.5",
            effort: Effort(rawValue: "low"), permissions: PermissionPolicy(mode: mode))
        let s = try await resume ? rt.resume(r) : rt.start(r)
        #expect(s.id == "pi-1")
        try await eventually { !bin.lines("env.txt").isEmpty }
        #expect(bin.lines("argv.txt") == want)
        #expect(bin.lines("env.txt") == [home.path, "1", "0"])
        await s.close()
        await rt.close()
    }

    @Test func modeFlagStays() async throws {
        let bin = try FakePi()
        let rt = bin.runtime()
        let s = try await rt.start(
            StartRequest(harness: .pi, workingDirectory: bin.dir.url, extraArguments: ["--mode=rpc"]))
        try await eventually { !bin.lines("argv.txt").isEmpty }
        #expect(bin.lines("argv.txt") == ["--mode=rpc"])
        #expect(bin.lines("env.txt") == ["", "", ""])
        await s.close()
        await rt.close()
    }

    @Test func mcpNeedsAHome() async throws {
        let bin = try FakePi()
        let rt = bin.runtime()
        let r = StartRequest(
            harness: .pi, workingDirectory: bin.dir.url,
            mcpServers: [MCPServer(name: "local", transport: .stdio(command: "cmd", args: [], env: [:]))])
        await #expect(throws: AgentBinderError.homeRequired(feature: "MCP injection")) { _ = try await rt.start(r) }
        await rt.close()
    }

    @Test func resumeNeedsAnID() async throws {
        let bin = try FakePi()
        let rt = bin.runtime()
        await #expect(throws: AgentBinderError.invalidRequest("pi: resume needs a session id")) {
            _ = try await rt.resume(StartRequest(harness: .pi, workingDirectory: bin.dir.url))
        }
        await rt.close()
    }

    // Without --append-system-prompt in the help text, the first prompt carries the instructions.
    @Test(arguments: [("", false), ("  --append-system-prompt <text>", true)])
    func instructions(_ help: String, _ flag: Bool) async throws {
        let bin = try FakePi(help: help)
        let rt = bin.runtime()
        let s = try await rt.start(
            StartRequest(harness: .pi, workingDirectory: bin.dir.url, instructions: "Be terse."))
        try await s.prompt(Prompt("one"))
        _ = try await withTimeout { await s.events.next { $0.isResult } }
        #expect(bin.lines("argv.txt").contains("--append-system-prompt") == flag)
        let message = bin.input().first { $0["type"] == "prompt" }?["message"]?.string
        #expect(message == (flag ? "one" : "<session-instructions>\nBe terse.\n</session-instructions>\n\none"))
        await s.close()
        await rt.close()
    }

    @Test func oneShot() async throws {
        let bin = try FakePi()
        let rt = bin.runtime()
        let s = try await rt.start(
            StartRequest(harness: .pi, workingDirectory: bin.dir.url, oneShot: OneShot(prompt: "go")))
        let evs = try await withTimeout { await s.events.collect() }
        #expect(evs.compactMap(\.assistantText) == ["PONG"])
        #expect(evs.results.count == 1 && evs.errors.isEmpty && evs.last?.isExit == true)
        await rt.close()
    }

    @Test func modelProbe() async throws {
        let bin = try FakePi()
        let rt = bin.runtime()
        let models = try await rt.models(.pi)
        #expect(models.map(\.id) == ["xai/grok-4.5", "zai/glm-5.3"])
        #expect(models.filter(\.isDefault).map(\.id) == ["xai/grok-4.5"])
        #expect(bin.lines("argv.txt") == ["--mode", "rpc", "--no-session"])
        #expect(bin.input().map { $0["type"].stringValue } == ["get_available_models", "get_state"])
        await rt.close()
    }
}
