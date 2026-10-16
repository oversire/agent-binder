import Foundation
import Testing

@testable import AgentBinder

private func codexConfig(_ change: (inout CodexConfig) -> Void = { _ in }) -> CodexConfig {
    var c = CodexConfig()
    c.cwd = "/w"
    c.clientVersion = "1.0"
    change(&c)
    return c
}

private func note(_ method: String, _ params: String) -> Data {
    Data(#"{"jsonrpc":"2.0","method":"\#(method)","params":\#(params)}"#.utf8)
}

private func result(_ req: JSONValue, _ body: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(req["id"]!.jsonString),"result":\#(body)}"#
}

private func failure(_ req: JSONValue, _ code: Int, _ message: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(req["id"]!.jsonString),"error":{"code":\#(code),"message":"\#(message)"}}"#
}

extension ScriptedPeer {
    /// Answers initialize and thread/start (or thread/resume) with a thread.
    fileprivate func codexHandshake(_ thread: String = #"{"thread":{"id":"thr_1"}}"#) {
        expect(method: "initialize") { [result($0, "{}")] }
        expect({ ["thread/start", "thread/resume"].contains($0["method"]?.string ?? "") }) { [result($0, thread)] }
    }

    fileprivate func frames(method: String) -> [JSONValue] { seen.filter { $0["method"]?.string == method } }
}

// MARK: fixtures

@Suite("CodexFixtureTests")
struct CodexFixtureTests {
    static let all = Fixtures.list("codex")

    @Test(arguments: all) func golden(_ rel: String) throws {
        try Fixtures.expectGolden(rel, try Fixtures.parse(rel, CodexAdapter(codexConfig())))
    }

    @Test func notifications() throws {
        let evs = try Fixtures.parse("codex/notifications.ndjson", CodexAdapter(codexConfig()))
        #expect(evs.first?.sessionID == "thr_1")
        let tools = evs.tools
        #expect(tools.map(\.id) == ["c1", "c1", "c2", "c2", "f1", "f1", "m1", "m1", "w1", "w1"])
        #expect(tools[1].status == .completed && tools[1].output == "total 0\n" && tools[1].kind == .exec)
        // The exit code makes the item failed. The tool event has no exit code.
        #expect(tools[3].status == .failed && tools[3].output == "boom" && tools[3].exitCode == nil)
        #expect(tools[4].paths == ["a.go", "b.go"] && tools[4].kind == .edit)
        #expect(tools[6].name == "mcp:echo" && tools[6].input == #"{"text":"hi"}"# && tools[6].kind == .mcp)
        #expect(tools[8].name == "web_search" && tools[8].kind == .search)
        #expect(evs.compactMap(\.assistantText) == ["Hel", "lo", "Hello"])
        #expect(evs.results.count == 2)
        #expect(evs.results[0] == TurnResult(usage: Usage(input: 11, output: 4, cacheRead: 3, cacheCreation: 2)))
        let failed = evs.results[1]
        #expect(failed.subtype == "failed" && failed.isError && failed.text == "You've hit your usage limit.")
        #expect(failed.endReason == .limit && failed.code == "codex.rate_limited")
        #expect(evs.errors.map(\.message) == ["stream disconnected"])
        #expect(evs.errors.first?.code.hasPrefix("codex.") == true)
        let l = try #require(evs.limits.first)
        #expect(l.plan == "plus" && l.windows.map(\.key) == [.fiveHour, .weekly])
    }
}

// MARK: adapter

@Suite("CodexAdapterTests")
struct CodexAdapterTests {
    @Test func usageEventIsTheTotal() {
        let a = CodexAdapter(codexConfig())
        let evs = a.parse(
            note(
                "thread/token_usage/updated",
                #"{"input_tokens":11,"output_tokens":4,"cached_input_tokens":3,"cache_write_input_tokens":2}"#))
        guard case .usage(let u) = evs.first?.kind, evs.count == 1 else {
            Issue.record("got \(evs)")
            return
        }
        #expect(u == Usage(input: 11, output: 4, cacheRead: 3, cacheCreation: 2))
        #expect(a.parse(note("thread/tokenUsage/updated", #"{"tokenUsage":{"last":{"inputTokens":1}}}"#)).isEmpty)
    }

    @Test func turnUsage() {
        let a = CodexAdapter(codexConfig())
        func usage(_ turn: String, _ last: (Int, Int), _ total: (Int, Int)) {
            _ = a.parse(
                note(
                    "thread/tokenUsage/updated",
                    #"{"turnId":"\#(turn)","tokenUsage":{"last":{"inputTokens":\#(last.0),"outputTokens":\#(last.1)},"total":{"inputTokens":\#(total.0),"outputTokens":\#(total.1)}}}"#
                ))
        }
        func complete(_ status: String = "completed") -> Usage? {
            a.parse(note("turn/completed", #"{"turn":{"status":"\#(status)"}}"#)).results.first?.usage
        }
        // Not active: the note does not count.
        usage("turn_0", (5, 5), (5, 5))
        _ = a.parse(note("turn/started", #"{"turn":{"id":"turn_1"}}"#))
        usage("turn_1", (100, 10), (100, 10))
        #expect(complete() == Usage(input: 100, output: 10))
        _ = a.parse(note("turn/started", #"{"turn":{"id":"turn_2"}}"#))
        usage("turn_2", (120, 5), (220, 15))
        usage("turn_x", (999, 999), (9999, 9999))
        usage("turn_2", (130, 7), (350, 22))
        usage("turn_2", (130, 7), (350, 22))
        #expect(complete() == Usage(input: 250, output: 12))
        _ = a.parse(note("turn/started", #"{"turn":{"id":"turn_3"}}"#))
        #expect(complete("failed") == Usage())
    }

    @Test func lastOnlyAdds() {
        let a = CodexAdapter(codexConfig())
        _ = a.parse(note("turn/started", #"{"turn":{"id":"t"}}"#))
        for _ in 0..<2 { _ = a.parse(note("thread/tokenUsage/updated", #"{"tokenUsage":{"last":{"inputTokens":3}}}"#)) }
        #expect(a.parse(note("turn/completed", #"{"turn":{"status":"success"}}"#)).results.first?.usage.input == 6)
    }

    @Test(
        arguments: [
            (#"{"turn":{"status":"interrupted"}}"#, "interrupted", "turn interrupted", nil, nil),
            (#"{"turn":{"status":"canceled"}}"#, "interrupted", "turn interrupted", nil, nil),
            (
                #"{"turn":{"status":"failed","error":"401 Unauthorized"}}"#, "failed", "401 Unauthorized", .auth,
                "codex.invalid_credentials"
            ),
            (
                #"{"turn":{"status":"failed","error":{"error":"overloaded"}}}"#, "failed", "overloaded", .overloaded,
                "codex.capacity"
            ),
            (#"{"turn":{"status":"failed"}}"#, "failed", "turn failed", .unknown, "codex.unknown"),
        ] as [(String, String, String, EndReason?, String?)])
    func turnStatus(_ params: String, _ subtype: String, _ text: String, _ reason: EndReason?, _ code: String?) throws {
        let a = CodexAdapter(codexConfig())
        let r = try #require(a.parse(note("turn/completed", params)).results.first)
        #expect(r.subtype == subtype && r.isError && r.text == text)
        #expect(r.endReason == reason && r.code == code)
        #expect(r.sessionID == nil)
    }

    @Test func turnStartedWithoutTurn() {
        let a = CodexAdapter(codexConfig())
        #expect(a.parse(note("turn/started", "{}")).map(\.kind.name) == ["status"])
        #expect(!a.turnActive)
    }

    // Fixed on purpose: no Go map dump.
    @Test(arguments: [
        (#"{"message":"m"}"#, "m"),
        (#"{"error":"e"}"#, "e"),
        (#"{"error":{"message":"inner"}}"#, "inner"),
        (#"{"error":{"code":7}}"#, #"{"code":7}"#),
        ("{}", "codex reported an error"),
    ])
    func errorText(_ params: String, _ text: String) {
        let evs = CodexAdapter(codexConfig()).parse(note("error", params))
        #expect(evs.errors.map(\.message) == [text])
    }

    @Test func invalidLinesAreDropped() {
        let a = CodexAdapter(codexConfig())
        #expect(a.parse(Data("npm notice".utf8)).isEmpty)
        #expect(a.parse(Data(#"{"jsonrpc":"2.0"}"#.utf8)).isEmpty)
        #expect(a.parse(note("item/started", #"{"item":{"type":"agentMessage","text":""}}"#)).isEmpty)
        #expect(a.parse(note("thread/started", #"{"thread":{}}"#)).isEmpty)
    }

    @Test func exitClassification() {
        let a = CodexAdapter(codexConfig())
        #expect(
            a.exitEvents(code: 2, stderr: "").errors.map(\.message) == [
                "codex exited with code 2 before turn/completed"
            ])
        #expect(a.exitEvents(code: 1, stderr: " not logged in \n").errors.first?.code == "codex.not_logged_in")
        _ = a.parse(note("turn/completed", "{}"))
        // Quirk: sawResult is session-wide, so a crash in a later turn gets no classified error.
        _ = a.parse(note("turn/started", #"{"turn":{"id":"t2"}}"#))
        #expect(a.exitEvents(code: 1, stderr: "boom").isEmpty)
    }

    @Test(
        arguments: [
            ("item/commandExecution/requestApproval", true, nil, #"{"decision":"accept"}"#),
            ("item/commandExecution/requestApproval", false, "no", #"{"decision":"decline","reason":"no"}"#),
            ("item/fileChange/requestApproval", false, "", #"{"decision":"decline"}"#),
            ("item/tool/requestUserInput", false, nil, #"{"answers":{}}"#),
            ("mcpServer/elicitation/request", true, nil, #"{"action":"accept"}"#),
            ("mcpServer/elicitation/request", false, nil, #"{"action":"decline"}"#),
        ] as [(String, Bool, String?, String)])
    func decisionBody(_ method: String, _ allow: Bool, _ message: String?, _ want: String) {
        #expect(CodexAdapter.decisionBody(method: method, Decision(allow: allow, message: message)).jsonString == want)
    }

    @Test(arguments: [
        ("item/commandExecution/requestApproval", #"{"command":"ls"}"#, ToolKind.exec, "Allow command: ls"),
        ("item/commandExecution/requestApproval", "{}", .exec, "Codex requests approval"),
        ("item/fileChange/requestApproval", "{}", .edit, "Allow file changes"),
        ("item/permissions/requestApproval", "{}", .other, "Allow requested permissions"),
        ("item/tool/requestUserInput", #"{"question":"Name?"}"#, .other, "Name?"),
        ("item/tool/requestUserInput", "{}", .other, "Codex needs input"),
        ("mcpServer/elicitation/request", #"{"message":"Pick"}"#, .other, "Pick"),
        ("mcpServer/elicitation/request", "{}", .other, "Codex requests input"),
        // Quirk: the legacy methods are kind other.
        ("execCommandApproval", "{}", .other, "Allow command execution"),
        ("applyPatchApproval", "{}", .other, "Allow patch application"),
    ])
    func approvalQuestion(_ method: String, _ params: String, _ kind: ToolKind, _ question: String) throws {
        let a = CodexAdapter(codexConfig())
        let line = #"{"jsonrpc":"2.0","id":"r1","method":"\#(method)","params":\#(params)}"#
        let p = try #require(a.parse(Data(line.utf8)).permissions.first)
        #expect(p.id == #""r1""# && p.tool == method && p.kind == kind && p.question == question)
        #expect(p.input.isEmpty && p.toolUseID == nil)
    }

    @Test func limitsMapping() throws {
        let body = try #require(
            JSONValue.parse(
                #"{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":12.5,"windowDurationMins":10080,"resetsAt":1789573800},"secondary":null},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":12.5,"windowDurationMins":10080,"resetsAt":1789573800}},"gpt-x":{"rateLimitReachedType":"primary","primary":{"usedPercent":100,"windowDurationMins":300}}}}"#
            ))
        let l = try #require(Limits(codex: body))
        #expect(l.plan == "plus" && l.rejected)
        // The window key comes from the length. The codex scope is the default scope. Duplicates go.
        #expect(
            l.windows == [
                LimitWindow(
                    key: .weekly, minutes: 10080, usedPercent: 12.5,
                    resetsAt: Date(timeIntervalSince1970: 1_789_573_800)),
                LimitWindow(key: .fiveHour, scope: "gpt-x", minutes: 300, usedPercent: 100),
            ])
        #expect(Limits(codex: ["rateLimits": ["primary": .null]]) == nil)
        #expect(Limits(codex: "x") == nil)
        #expect(Limits(codex: ["rateLimits": ["planType": "pro"]]) == Limits(plan: "pro"))
    }

    @Test(arguments: [(300, WindowKey.fiveHour), (1440, .daily), (10080, .weekly), (43200, .monthly), (60, .custom)])
    func windowKey(_ minutes: Int, _ key: WindowKey) { #expect(WindowKey(minutes: minutes) == key) }

    @Test func noThread() throws {
        let a = CodexAdapter(codexConfig())
        #expect(throws: AgentBinderError.invalidRequest("codex: thread not started")) { try a.encodeInterrupt() }
        #expect(throws: AgentBinderError.invalidRequest("codex: thread not started")) {
            try a.encodePrompt(Prompt("hi"))
        }
    }

    @Test func fireAndForgetPrompt() throws {
        let a = CodexAdapter(codexConfig())
        _ = a.parse(note("thread/started", #"{"thread":{"id":"thr_9"}}"#))
        let f = try #require(JSONValue.parse(try a.encodePrompt(Prompt("hi"))))
        #expect(f["method"] == "turn/start" && f.at("params", "threadId") == "thr_9")
        #expect(f.at("params", "input") == [["type": "text", "text": "hi"]])
    }
}

// MARK: wire

@Suite("CodexWireTests")
struct CodexWireTests {
    private func session(
        _ peer: ScriptedPeer, _ config: CodexConfig = codexConfig()
    ) async throws -> (WireSession, CodexSession, CodexAdapter) {
        let a = CodexAdapter(config)
        let w = try await peer.session(a, harness: .codex)
        return (w, CodexSession(wire: w, adapter: a), a)
    }

    private func startTurn(_ peer: ScriptedPeer, _ a: CodexAdapter, id: String = "turn_1") async throws {
        peer.send(String(decoding: note("turn/started", #"{"turn":{"id":"\#(id)"}}"#), as: UTF8.self))
        try await eventually { a.turnActive }
    }

    @Test func handshakeOrder() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        let (w, s, _) = try await session(
            peer,
            codexConfig {
                $0.clientName = "oversire"
                $0.model = "gpt-5"
                $0.instructions = "be brief"
            })
        #expect(
            peer.seen.map(\.jsonString) == [
                #"{"id":1,"jsonrpc":"2.0","method":"initialize","params":{"clientInfo":{"name":"oversire","title":"oversire","version":"1.0"}}}"#,
                #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
                #"{"id":2,"jsonrpc":"2.0","method":"thread/start","params":{"approvalPolicy":"on-request","cwd":"/w","developerInstructions":"be brief","model":"gpt-5","sandbox":"workspace-write"}}"#,
                #"{"id":3,"jsonrpc":"2.0","method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}"#,
            ])
        let e = try await withTimeout { await s.events.next { $0.kind.name == "init" } }
        #expect(e?.sessionID == "thr_1" && w.id == "thr_1")
        await s.kill()
    }

    @Test func resume() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake(#"{"threadId":"thr_old"}"#)
        let (w, s, _) = try await session(peer, codexConfig { $0.resumeID = "thr_old" })
        let req = try #require(peer.frames(method: "thread/resume").first)
        #expect(req.at("params", "threadId") == "thr_old" && peer.frames(method: "thread/start").isEmpty)
        try await eventually { w.id == "thr_old" }
        await s.kill()
    }

    @Test func handshakeFailure() async throws {
        let peer = ScriptedPeer()
        peer.expect(method: "initialize") { [failure($0, -32600, "initialize failed")] }
        let (_, s, _) = try await session(peer)
        // Quirk: the error reply also gives an rpc_error event, before the handshake error.
        let first = try await withTimeout { await s.events.next { $0.errorCode != nil } }
        #expect(first?.errorCode == "rpc_error")
        let e = try await withTimeout { await s.events.next { $0.errorCode != nil } }
        guard case .error(let we) = try #require(e).kind else { return }
        #expect(we.code == "handshake_failed" && we.message.contains("codex initialize: initialize failed"))
        await s.kill()
    }

    @Test func noThreadInReply() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake("{}")
        let (_, s, a) = try await session(peer)
        await #expect(throws: AgentBinderError.invalidRequest("codex: thread not started")) {
            try await s.prompt(Prompt("hi"))
        }
        _ = a.parse(note("thread/started", #"{"thread":{"id":"thr_late"}}"#))
        #expect(a.threadID == "thr_late")
        await s.kill()
    }

    @Test func limitsAfterHandshake() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        peer.expect(method: "account/rateLimits/read") {
            [
                result(
                    $0,
                    #"{"rateLimits":{"planType":"plus","primary":{"usedPercent":10,"windowDurationMins":300},"secondary":{"usedPercent":20,"windowDurationMins":10080}}}"#
                )
            ]
        }
        let (_, s, _) = try await session(peer)
        let e = try await withTimeout { await s.events.next { $0.kind.name == "limits" } }
        guard case .limits(let l) = try #require(e).kind else { return }
        #expect(l.plan == "plus" && l.windows.count == 2)
        await s.kill()
    }

    // An API-key login has no plan limits. The error reply gives no event.
    @Test func limitsReadError() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        peer.expect(method: "account/rateLimits/read") { [failure($0, -32600, "chatgpt login required")] }
        let (_, s, _) = try await session(peer)
        peer.send(
            String(
                decoding: note(
                    "account/rateLimits/updated",
                    #"{"rateLimits":{"rateLimitReachedType":"primary","primary":{"usedPercent":100,"windowDurationMins":300}}}"#
                ), as: UTF8.self))
        let e = try await withTimeout { await s.events.next { $0.kind.name == "limits" || $0.errorCode != nil } }
        guard case .limits(let l) = try #require(e).kind else {
            Issue.record("got \(String(describing: e))")
            return
        }
        #expect(l.rejected)
        await s.kill()
    }

    @Test func promptAndTurnState() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        peer.expect(method: "turn/start") { [result($0, #"{"turn":{"id":"ignored"}}"#)] }
        let (_, s, a) = try await session(peer, codexConfig { $0.model = "gpt-5" })
        try await s.prompt(Prompt("hi"))
        #expect(a.turnActive)
        let req = try #require(peer.frames(method: "turn/start").first)
        #expect(
            req["params"]?.jsonString == #"{"input":[{"text":"hi","type":"text"}],"model":"gpt-5","threadId":"thr_1"}"#)
        await #expect(throws: AgentBinderError.turnActive) { try await s.prompt(Prompt("again")) }
        await s.kill()
    }

    // Fixed on purpose: a turn that ends before the ack does not stay active.
    @Test func turnEndsBeforeTheAck() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        peer.expect(method: "turn/start") {
            [
                String(decoding: note("turn/started", #"{"turn":{"id":"t1"}}"#), as: UTF8.self),
                String(decoding: note("turn/completed", #"{"turn":{"status":"completed"}}"#), as: UTF8.self),
                result($0, "{}"),
            ]
        }
        let (_, s, a) = try await session(peer)
        try await s.prompt(Prompt("hi"))
        #expect(!a.turnActive)
        await s.kill()
    }

    @Test func lateAckIsFine() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        let (_, s, a) = try await session(peer)
        try await s.prompt(Prompt("hi"))
        #expect(a.turnActive)
        await s.kill()
    }

    @Test func effortFallback() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        peer.expect({ $0["method"] == "turn/start" && $0.at("params", "effort") != nil }) {
            [failure($0, -32602, "unknown field `effort`")]
        }
        peer.expect(method: "turn/start") { [result($0, "{}")] }
        peer.expect(method: "turn/start") { [result($0, "{}")] }
        let (_, s, a) = try await session(peer, codexConfig { $0.effort = "high" })
        try await s.prompt(Prompt("one"))
        let starts = peer.frames(method: "turn/start")
        #expect(starts.map { $0.at("params", "effort") } == [.string("high"), nil])
        // Quirk: the error reply also gives an rpc_error event.
        let e = try await withTimeout { await s.events.next { $0.errorCode != nil } }
        #expect(e?.errorCode == "rpc_error")
        peer.send(String(decoding: note("turn/completed", "{}"), as: UTF8.self))
        try await eventually { !a.turnActive }
        try await s.prompt(Prompt("two"))
        #expect(peer.frames(method: "turn/start").last?.at("params", "effort") == nil)
        await s.kill()
    }

    @Test func otherPromptErrorThrows() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        peer.expect(method: "turn/start") { [failure($0, -32000, "thread busy")] }
        let (_, s, a) = try await session(peer, codexConfig { $0.effort = "high" })
        await #expect(throws: JSONRPCError(code: -32000, message: "thread busy")) { try await s.prompt(Prompt("x")) }
        #expect(!a.turnActive && peer.frames(method: "turn/start").count == 1)
        await s.kill()
    }

    @Test func steer() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        peer.expect(method: "turn/steer") { [result($0, "{}")] }
        peer.expect(method: "turn/steer") { [failure($0, -32600, "no active turn")] }
        let (_, s, a) = try await session(peer)
        await #expect(throws: AgentBinderError.noActiveTurn) { try await s.steer(Prompt("x")) }
        try await startTurn(peer, a, id: "turn_7")
        try await s.steer(Prompt("more"))
        let req = try #require(peer.frames(method: "turn/steer").first)
        #expect(req.at("params", "expectedTurnId") == "turn_7" && req.at("params", "threadId") == "thr_1")
        do {
            try await s.steer(Prompt("again"))
            Issue.record("no error")
        } catch let e as AgentBinderError {
            #expect(e.code == "unsupported" && "\(e)".contains("codex turn/steer"))
        }
        #expect(a.turnActive)
        await s.kill()
    }

    @Test func interrupt() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        let (_, s, a) = try await session(peer)
        try await s.interrupt()
        try await startTurn(peer, a, id: "turn_3")
        try await s.interrupt()
        let frames = peer.frames(method: "turn/interrupt")
        #expect(
            frames.map { $0["params"]?.jsonString } == [
                #"{"threadId":"thr_1"}"#, #"{"threadId":"thr_1","turnId":"turn_3"}"#,
            ])
        #expect(frames.allSatisfy { $0["id"]?.int != nil })
        await s.kill()
    }

    @Test func setModelNextTurn() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        peer.expect(method: "turn/start") { [result($0, "{}")] }
        let (_, s, _) = try await session(peer)
        try await s.setModel("gpt-5-mini")
        #expect(peer.seen.count == 4)
        try await s.prompt(Prompt("hi"))
        #expect(peer.frames(method: "turn/start").first?.at("params", "model") == "gpt-5-mini")
        await s.kill()
    }

    @Test func approvalRoundTrip() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        let (_, s, _) = try await session(peer)
        peer.send(
            #"{"jsonrpc":"2.0","id":7,"method":"item/commandExecution/requestApproval","params":{"command":"ls"}}"#)
        let e = try await withTimeout { await s.events.next { $0.kind.name == "permission" } }
        guard case .permission(let p) = try #require(e).kind else { return }
        #expect(p.id == "7" && p.kind == .exec && p.question == "Allow command: ls")
        try await s.answer("7", .allow())
        // A string id stays a string.
        peer.send(#"{"jsonrpc":"2.0","id":"7","method":"item/fileChange/requestApproval","params":{}}"#)
        let e2 = try await withTimeout { await s.events.next { $0.kind.name == "permission" } }
        guard case .permission(let p2) = try #require(e2).kind else { return }
        #expect(p2.id == #""7""#)
        try await s.answer(p2.id, .deny("not now"))
        let replies = peer.seen.filter { $0["result"] != nil }.map(\.jsonString)
        #expect(
            replies == [
                #"{"id":7,"jsonrpc":"2.0","result":{"decision":"accept"}}"#,
                #"{"id":"7","jsonrpc":"2.0","result":{"decision":"decline","reason":"not now"}}"#,
            ])
        await s.kill()
    }

    @Test func autoEditApproval() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        let (_, s, a) = try await session(peer, codexConfig { $0.policy = PermissionPolicy(mode: .autoEdit) })
        let evs = a.parse(
            Data(#"{"jsonrpc":"2.0","id":8,"method":"item/fileChange/requestApproval","params":{}}"#.utf8))
        #expect(evs.isEmpty)
        try await eventually { peer.seen.contains { $0["id"] == 8 } }
        #expect(peer.seen.last?.jsonString == #"{"id":8,"jsonrpc":"2.0","result":{"decision":"accept"}}"#)
        // The allow list matches the method name.
        let b = CodexAdapter(codexConfig { $0.policy = PermissionPolicy(allowTools: ["applyPatch*"]) })
        #expect(b.parse(Data(#"{"jsonrpc":"2.0","id":1,"method":"applyPatchApproval"}"#.utf8)).isEmpty)
        await s.kill()
    }

    @Test func unsupportedRequest() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        let (_, s, _) = try await session(peer)
        peer.send(#"{"jsonrpc":"2.0","id":9,"method":"item/tool/call","params":{}}"#)
        try await eventually { peer.seen.contains { $0["id"] == 9 } }
        #expect(
            peer.seen.last?.jsonString
                == #"{"error":{"code":-32601,"message":"agentbinder: app-server method unsupported: item/tool/call"},"id":9,"jsonrpc":"2.0"}"#
        )
        await s.kill()
    }

    @Test func attachments() async throws {
        let peer = ScriptedPeer()
        peer.codexHandshake()
        peer.expect(method: "turn/start") { [result($0, "{}")] }
        let (_, s, a) = try await session(peer)
        let p = Prompt(
            "look",
            attachments: [
                PromptAttachment(mime: "text/plain", source: .data(Data("notes".utf8))),
                PromptAttachment(mime: "image/png", source: .data(Data([0x89, 0x50]))),
                PromptAttachment(source: .file(URL(fileURLWithPath: "/pics/a.jpg"))),
            ])
        try await s.prompt(p)
        let input = try #require(peer.frames(method: "turn/start").first?.at("params", "input")?.array)
        #expect(input.map { $0["type"].stringValue } == ["localImage", "localImage", "text", "text"])
        #expect(input[1]["path"] == "/pics/a.jpg")
        #expect(input[2]["text"] == "notes" && input[3]["text"] == "look")
        let path = input[0]["path"].stringValue
        #expect(path.hasSuffix(".png") && path.contains("agentbinder-codex-images-"))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([0x89, 0x50]))
        a.cleanup()
        #expect(!FileManager.default.fileExists(atPath: path))
        await s.kill()
    }
}

// MARK: driver

/// A fake `codex app-server`. It records its argv and each line that it reads.
private struct FakeCodex {
    let dir: TempDir
    var inputFile: URL { dir.url.appendingPathComponent("in.txt") }

    init(limits: String = #""result":{"rateLimits":{"planType":"pro"}}"#) throws {
        dir = try TempDir()
        let page1 = Fixtures.url("models/codex_model_list_1.json").path
        let page2 = Fixtures.url("models/codex_model_list_2.json").path
        try dir.script(
            "codex",
            """
            printf '%s\\n' "$@" > '\(dir.path)/argv.txt'
            reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$id" "$1"; }
            while IFS= read -r line; do
              printf '%s\\n' "$line" >> '\(dir.path)/in.txt'
              id=$(printf '%s' "$line" | sed -n 's/^.*"id":\\([0-9][0-9]*\\).*$/\\1/p')
              case "$line" in
                *'"method":"initialize"'*) reply '{}' ;;
                *'"method":"thread/start"'*) reply '{"thread":{"id":"thr_new"}}' ;;
                *'"method":"thread/resume"'*) reply '{"thread":{"id":"thr_old"}}' ;;
                *'"cursor":"page-2"'*) reply "$(cat '\(page2)')" ;;
                *'"method":"model/list"'*) reply "$(cat '\(page1)')" ;;
                *'"method":"account/rateLimits/read"'*) printf '{"jsonrpc":"2.0","id":%s,\(limits)}\\n' "$id" ;;
                *'"method":"turn/start"'*) reply '{}' ;;
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

    func argv() -> [String] { (dir.read("argv.txt") ?? "").split(separator: "\n").map(String.init) }
    func input() -> [JSONValue] {
        (dir.read("in.txt") ?? "").split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
    }
}

@Suite("CodexDriverTests")
struct CodexDriverTests {
    @Test func startIgnoresTheSessionID() async throws {
        let bin = try FakeCodex()
        let rt = bin.runtime()
        let s = try await rt.start(
            StartRequest(
                harness: .codex, workingDirectory: bin.dir.url, sessionID: "mine", effort: Effort(rawValue: "high"),
                extraArguments: ["-c", "notify=true"]))
        #expect(s.id == "thr_new")
        #expect(bin.argv() == ["-c", "model_reasoning_effort=high", "-c", "notify=true", "app-server"])
        let start = try #require(bin.input().first { $0["method"] == "thread/start" })
        #expect(start.at("params", "threadId") == nil && start.at("params", "cwd")?.string == bin.dir.path)
        await rt.close()
    }

    @Test func resume() async throws {
        let bin = try FakeCodex()
        let rt = bin.runtime()
        let s = try await rt.resume(
            StartRequest(
                harness: .codex, workingDirectory: bin.dir.url, sessionID: "thr_old",
                permissions: PermissionPolicy(mode: .auto), raw: ["sandbox": .string("danger-full-access")]))
        #expect(s.id == "thr_old")
        let req = try #require(bin.input().first { $0["method"] == "thread/resume" })
        #expect(req.at("params", "threadId") == "thr_old" && req.at("params", "approvalPolicy") == "never")
        #expect(req.at("params", "sandbox") == "danger-full-access")
        await rt.close()
        await #expect(throws: AgentBinderError.invalidRequest("codex: resume needs a session id")) {
            _ = try await CodexDriver().resume(
                StartRequest(harness: .codex, workingDirectory: bin.dir.url), runtime: rt.context)
        }
    }

    @Test func oneShot() async throws {
        let bin = try FakeCodex()
        let rt = bin.runtime()
        let s = try await rt.start(
            StartRequest(harness: .codex, workingDirectory: bin.dir.url, oneShot: OneShot(prompt: "do it")))
        // The closed stdin ends the fake.
        let evs = try await withTimeout { await s.events.collect() }
        #expect(evs.last?.isExit == true)
        let turn = try #require(bin.input().first { $0["method"] == "turn/start" })
        #expect(turn.at("params", "input") == [["type": "text", "text": "do it"]])
        await rt.close()
    }

    @Test func modelPages() async throws {
        let bin = try FakeCodex()
        let rt = bin.runtime()
        let models = try await rt.models(.codex)
        #expect(models.map(\.id) == ["glm-5.3", "glm-5-turbo"])
        #expect(models.filter(\.isDefault).map(\.id) == ["glm-5.3"])
        #expect(models[1].name == "GLM-5 Turbo" && models[1].description == "Fast model")
        let lists = bin.input().filter { $0["method"] == "model/list" }
        #expect(lists.map { $0["params"]?.jsonString } == ["{}", #"{"cursor":"page-2"}"#])
        #expect(bin.argv() == ["app-server"])
        await rt.close()
    }

    @Test func readLimits() async throws {
        let bin = try FakeCodex()
        let rt = bin.runtime()
        #expect(try await rt.limits(.codex) == Limits(plan: "pro"))
        await rt.close()
    }

    @Test func readLimitsError() async throws {
        let bin = try FakeCodex(limits: #""error":{"code":-32600,"message":"login required"}"#)
        let rt = bin.runtime()
        await #expect(
            throws: AgentBinderError.vendor(code: -32600, message: "codex account/rateLimits/read: login required")
        ) {
            _ = try await rt.limits(.codex)
        }
        await rt.close()
    }

    @Test func unmappedLimitsAreEmpty() async throws {
        let bin = try FakeCodex(limits: #""result":{}"#)
        let rt = bin.runtime()
        #expect(try await rt.limits(.codex) == Limits())
        await rt.close()
    }
}
