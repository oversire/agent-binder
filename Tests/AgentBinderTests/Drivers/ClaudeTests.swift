import Foundation
import Testing

@testable import AgentBinder

/// An adapter with the request ids `req_1`, `req_2`, and so on.
private func claudeAdapter(_ policy: PermissionPolicy = PermissionPolicy()) -> ClaudeAdapter {
    let n = Locked(0)
    return ClaudeAdapter(policy: policy) {
        "req_\(n.withLock { v -> Int in v += 1; return v })"
    }
}

private func canUseTool(_ id: String, _ tool: String, _ input: String) -> Data {
    Data(
        #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"can_use_tool","tool_name":"\#(tool)","input":\#(input)}}"#
            .utf8)
}

private func line(_ s: String) -> Data { Data(s.utf8) }

extension ScriptedPeer {
    fileprivate func frames(type: String) -> [JSONValue] { seen.filter { $0["type"]?.string == type } }
}

// MARK: fixtures

@Suite("ClaudeFixtureTests")
struct ClaudeFixtureTests {
    static let all = Fixtures.list("claude")

    @Test(arguments: all) func golden(_ rel: String) throws {
        try Fixtures.expectGolden(rel, try Fixtures.parse(rel, claudeAdapter()))
    }

    @Test func fixtureCount() { #expect(Self.all.count >= 10) }

    @Test(arguments: all) func streamInvariants(_ rel: String) throws {
        let evs = try Fixtures.parse(rel, claudeAdapter())
        #expect(evs.count("init") == 1)
        #expect(evs.first { $0.kind.name == "init" }?.sessionID?.isEmpty == false)
        #expect(evs.results.count == 1)
        let r = try #require(evs.results.first)
        if r.isError { #expect(r.code?.hasPrefix("claude.") == true) } else { #expect(r.code == nil) }
        // A completion carries only the id on the wire, so it gets the name of its start.
        var starts: [String: String] = [:]
        for t in evs.tools {
            switch t.status {
            case .started:
                #expect(!t.id.isEmpty && !t.name.isEmpty)
                starts[t.id] = t.name
            case .completed, .failed:
                if let n = starts[t.id] { #expect(t.name == n) }
            case .cancelled: #expect(starts[t.id] != nil)
            }
        }
    }

    @Test func basic() throws {
        let evs = try Fixtures.parse("claude/basic.ndjson", claudeAdapter())
        #expect(evs.first?.sessionID == "11111111-2222-3333-4444-555555555555")
        let texts = evs.compactMap { e -> String? in
            if case .assistant(let t, let d) = e.kind { return "\(t)|\(d)" }
            return nil
        }
        #expect(texts == ["hello from claude|false", "more |true"])
        let tools = evs.tools
        #expect(tools.count == 2)
        #expect(tools[0].name == "Bash" && tools[0].status == .started && tools[0].kind == .exec)
        #expect(tools[0].input == #"{"command":"echo hi"}"#)
        #expect(tools[1].name == "Bash" && tools[1].status == .completed && tools[1].output == "hi\n")
        let r = try #require(evs.results.first)
        #expect(r.subtype == "success" && !r.isError)
        #expect(r.sessionID == evs.first?.sessionID)
        #expect(
            r.usage
                == Usage(
                    input: 100, output: 25, cacheRead: 10, cacheCreation: 5, model: "claude-sonnet-4-5", costUSD: 0.0123
                ))
    }

    @Test func permissionRequest() throws {
        let p = try #require(try Fixtures.parse("claude/permission.ndjson", claudeAdapter()).permissions.first)
        #expect(p.id == "req_9_abc12345")
        #expect(p.tool == "Bash" && p.kind == .exec)
        #expect(p.question == "Claude wants to run a command")
        #expect(p.input.contains("trebi-perm"))
        #expect(p.toolUseID == "toolu_9")
    }

    @Test(arguments: [
        ("claude/error_auth.ndjson", EndReason.auth, "claude.invalid_credentials"),
        ("claude/error_limit.ndjson", .limit, "claude.rate_limited"),
    ])
    func errorResults(_ rel: String, _ reason: EndReason, _ code: String) throws {
        let r = try #require(try Fixtures.parse(rel, claudeAdapter()).results.first)
        #expect(r.isError && r.subtype == "error_during_execution")
        #expect(!r.text.isEmpty)
        #expect(r.endReason == reason)
        #expect(r.code == code)
    }

    // Quirk: the CLI sends each tool start twice with the same id.
    @Test func toolStartTwice() throws {
        let evs = try Fixtures.parse("claude/shapes.ndjson", claudeAdapter())
        let starts = evs.tools.filter { $0.id == "toolu_a" && $0.status == .started }
        #expect(starts.map(\.input) == ["{}", #"{"file_path":"/tmp/a.txt","new_string":"y","old_string":"x"}"#])
        #expect(starts.last?.paths == ["/tmp/a.txt"])
    }

    // Quirk: an error result whose subtype is its only text has a code and no end reason.
    @Test func subtypeOnlyError() throws {
        let r = try #require(try Fixtures.parse("claude/shapes.ndjson", claudeAdapter()).results.first)
        #expect(r.isError && r.text == "error_max_turns")
        #expect(r.endReason == nil && r.code == "claude.error_max_turns")
    }

    // Quirk: a success result has text too.
    @Test func successText() throws {
        let r = try #require(try Fixtures.parse("claude/permission.ndjson", claudeAdapter()).results.first)
        #expect(r.text == "allowed")
    }

    @Test func mcpAutoAllow() throws {
        let adapter = claudeAdapter(PermissionPolicy(allowTools: ["mcp__trebi__*"]))
        let evs = try Fixtures.parse("claude/0.3.273-2.1.267/mcp_auto_allow.ndjson", adapter)
        let tools = evs.tools
        #expect(!tools.isEmpty)
        #expect(!tools.contains { $0.id == "2a53d801-0b9a-49a1-8073-c1fb604130c3" })
        #expect(evs.permissions.isEmpty)
        let started = Set(tools.filter { $0.status == .started }.map(\.id))
        let ended = Set(tools.filter { $0.status != .started }.map(\.id))
        #expect(started.isSubset(of: ended))
    }

    @Test func rateLimitWindows() throws {
        let evs = try Fixtures.parse("claude/0.3.273-2.1.267/basic.ndjson", claudeAdapter())
        let l = try #require(evs.limits.first)
        #expect(!l.rejected)
        #expect(l.windows.count == 2)
        #expect(l.windows[0].key == .fiveHour && l.windows[0].minutes == 300)
        #expect(abs(l.windows[0].usedPercent - 11) < 1e-9)
        #expect(l.windows[0].resetsAt == Date(timeIntervalSince1970: 1_789_573_800))
        #expect(l.windows[1].key == .weekly && l.windows[1].minutes == 10080)
        #expect(abs(l.windows[1].usedPercent - 44) < 1e-9)
        #expect(l.windows[1].resetsAt == Date(timeIntervalSince1970: 1_789_884_000))
        #expect(evs.errors.isEmpty)
    }

    @Test func rateLimitRejected() throws {
        let evs = try Fixtures.parse("claude/rate_limit_rejected.ndjson", claudeAdapter())
        let l = try #require(evs.limits.first)
        #expect(l.rejected)
        #expect(l.windows.map(\.key) == [.fiveHour, .weekly, .weekly])
        #expect(l.windows.map(\.scope) == [nil, nil, "opus"])
        #expect(l.windows.map { $0.usedPercent.rounded() } == [100, 62, 30])
        #expect(evs.errors.first?.endReason == .limit)
    }
}

// MARK: parse and encode

@Suite("ClaudeAdapterTests")
struct ClaudeAdapterTests {
    @Test(arguments: [
        ("Edit", #"{"file_path":"/tmp/x"}"#, ToolKind.edit, ["/tmp/x"]),
        ("Bash", #"{"command":"ls"}"#, .exec, []),
        ("Read", #"{"file_path":"/tmp/x"}"#, .read, []),
        ("mcp__x__y", "{}", .mcp, []),
    ])
    func toolKindAndPaths(_ name: String, _ input: String, _ kind: ToolKind, _ paths: [String]) throws {
        let evs = claudeAdapter().parse(
            line(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"\#(name)","input":\#(input)}]}}"#
            ))
        let t = try #require(evs.tools.first)
        #expect(evs.count == 1 && t.kind == kind && t.paths == paths)
    }

    @Test func stringToolInput() throws {
        let evs = claudeAdapter().parse(
            line(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Write","input":"{}"}]}}"#
            ))
        #expect(evs.tools.first?.input == #""{}""#)
    }

    @Test func textPrompt() throws {
        let v = try #require(JSONValue.parse(try claudeAdapter().encodePrompt(Prompt("hello"))))
        #expect(
            v.jsonString
                == #"{"message":{"content":"hello","role":"user"},"parent_tool_use_id":null,"session_id":"","type":"user"}"#
        )
    }

    @Test func imageAttachment() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let p = Prompt("what is this?", attachments: [PromptAttachment(mime: "image/png", source: .data(png))])
        let v = try #require(JSONValue.parse(try claudeAdapter().encodePrompt(p)))
        let blocks = try #require(v.at("message", "content")?.array)
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] == "image")
        #expect(
            blocks[0]["source"]
                == .object(["type": "base64", "media_type": "image/png", "data": .string(png.base64EncodedString())]))
        #expect(blocks[1] == .object(["type": "text", "text": "what is this?"]))
    }

    @Test func imageGoesFirst() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let p = Prompt(
            "prompt",
            attachments: [
                PromptAttachment(mime: "text/plain", source: .data(Data("snippet".utf8))),
                PromptAttachment(mime: "image/png", source: .data(png)),
            ])
        let v = try #require(JSONValue.parse(try claudeAdapter().encodePrompt(p)))
        let blocks = try #require(v.at("message", "content")?.array)
        #expect(blocks.map { $0["type"].stringValue } == ["image", "text", "text"])
        #expect(blocks[1]["text"] == "snippet" && blocks[2]["text"] == "prompt")
    }

    @Test func malformedFrames() throws {
        let a = claudeAdapter()
        let notice = a.parse(line("npm notice: update available"))
        guard case .status(.running, let t) = try #require(notice.first).kind else {
            Issue.record("not a status")
            return
        }
        #expect(notice.count == 1 && t == "npm notice: update available")
        let bad = a.parse(line(#"{"type":"assistant","message":"#))
        let e = try #require(bad.errors.first)
        #expect(bad.count == 1 && e.code == "malformed_frame" && e.endReason == .protocol)
        #expect(e.message.hasPrefix("claude: malformed JSON frame: "))
        #expect(a.parse(line("   ")).isEmpty)
        #expect(a.parse(line(#"{"type":"keep_alive"}"#)).isEmpty)
    }

    @Test func exitClassification() throws {
        let evs = claudeAdapter().exitEvents(code: 1, stderr: "Invalid API key\n")
        let e = try #require(evs.errors.first)
        #expect(evs.count == 1 && e.endReason == .auth && e.code == "claude.invalid_credentials")
        #expect(e.message == "Invalid API key")

        let bare = try #require(claudeAdapter().exitEvents(code: 2, stderr: "").errors.first)
        #expect(bare.message == "claude exited with code 2 before a result")
        #expect(bare.code == "claude.unknown" && bare.endReason == .unknown)

        let after = claudeAdapter()
        _ = after.parse(line(#"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#))
        #expect(after.exitEvents(code: 1, stderr: "Invalid API key").isEmpty)
    }

    @Test func resultClosesOpenTools() throws {
        let a = claudeAdapter()
        _ = a.parse(
            line(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_lost","name":"Bash","input":{"command":"ls"}}]}}"#
            ))
        let evs = a.parse(line(#"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#))
        #expect(evs.map(\.kind.name) == ["tool", "result"])
        #expect(evs.tools == [ToolEvent(id: "toolu_lost", status: .cancelled)])
        let again = a.parse(line(#"{"type":"result","subtype":"success","is_error":false,"result":"again"}"#))
        #expect(again.map(\.kind.name) == ["result"])
    }

    @Test func toolResultClearsTheTable() {
        let a = claudeAdapter()
        _ = a.parse(
            line(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#)
        )
        let done = a.parse(
            line(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#))
        #expect(done.tools == [ToolEvent(id: "t1", name: "Bash", kind: .exec, output: "ok", status: .completed)])
        #expect(a.exitEvents(code: 0, stderr: "").tools.isEmpty)
    }

    @Test func exitCancelsOpenTools() throws {
        let a = claudeAdapter()
        _ = a.parse(
            line(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b","name":"Write","input":{}}]}}"#)
        )
        _ = a.parse(
            line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Read","input":{}}]}}"#)
        )
        let evs = a.exitEvents(code: 1, stderr: "segfault")
        #expect(evs.map(\.kind.name) == ["tool", "tool", "error"])
        #expect(evs.tools.map(\.id) == ["a", "b"])
    }

    @Test func rateLimitWithoutWindows() throws {
        let a = claudeAdapter()
        let rejected = a.parse(
            line(
                #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":1789573800}}"#
            ))
        #expect(rejected.limits == [Limits(rejected: true)])
        #expect(rejected.errors.first?.message == "claude rate limit rejected")
        #expect(rejected.errors.first?.code == "claude.rate_limited")
        let allowed = a.parse(line(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#))
        #expect(allowed.limits.isEmpty && allowed.map(\.kind.name) == ["status"])
    }

    @Test func customWindow() {
        let l = Limits(claude: ["unifiedWindows": ["overage": ["utilization": 0.5]]], rejected: false)
        #expect(l?.windows == [LimitWindow(key: .custom, scope: "overage", usedPercent: 50)])
    }

    @Test func modelsParse() throws {
        let v = try Fixtures.json("models/claude_initialize.json")
        let models = try #require(ClaudeFrames.models(v.at("response", "response")))
        #expect(models.map(\.id) == ["default", "sonnet", "haiku"])
        #expect(models[0].name == "Default (recommended)" && models[0].isDefault)
        #expect(models[1].description?.contains("Sonnet 4.6") == true && !models[1].isDefault)
        #expect(ClaudeFrames.models(.object([:])) == nil)
    }

    @Test func resultTextOrder() {
        #expect(ClaudeFrames.resultText(["errors": ["a", "", "b"], "result": "r"]) == "a; b")
        #expect(ClaudeFrames.resultText(["errors": "one", "result": "r"]) == "one")
        #expect(ClaudeFrames.resultText(["result": "  r  ", "subtype": "error_x"]) == "r")
        #expect(ClaudeFrames.resultText(["subtype": "success", "api_error_status": 529]) == "API error (HTTP 529)")
        #expect(ClaudeFrames.resultText(["subtype": "success"]) == "unknown error")
    }

    @Test func requestIDShape() {
        let id = ClaudeAdapter.requestID(7)
        #expect(id.hasPrefix("req_7_") && id.count == "req_7_".count + 8)
    }

    @Test func controlWithoutWriter() async {
        await #expect(throws: AgentBinderError.sessionClosed) {
            _ = try await claudeAdapter().control(["subtype": "set_model"])
        }
    }
}

// MARK: wire

@Suite("ClaudeWireTests")
struct ClaudeWireTests {
    static func initialize(_ models: String) -> @Sendable (JSONValue) -> [String] {
        { req in
            [
                #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(req["request_id"].stringValue)","response":{"models":\#(models)}}}"#
            ]
        }
    }

    private func session(
        _ peer: ScriptedPeer, _ adapter: ClaudeAdapter = claudeAdapter()
    ) async throws -> (WireSession, ClaudeSession) {
        let w = try await peer.session(adapter, harness: .claude)
        return (w, ClaudeSession(wire: w, adapter: adapter))
    }

    @Test func handshakeStoresModels() async throws {
        let peer = ScriptedPeer()
        let fixture = try String(contentsOf: Fixtures.url("models/claude_initialize.json"), encoding: .utf8)
        peer.expect({ $0.at("request", "subtype")?.string == "initialize" }) { req in
            [fixture.replacingOccurrences(of: "\"INIT\"", with: "\"\(req["request_id"].stringValue)\"")]
        }
        let (_, s) = try await session(peer)
        #expect(
            peer.seen.first?.jsonString
                == #"{"request":{"hooks":null,"subtype":"initialize"},"request_id":"req_1","type":"control_request"}"#)
        try await eventually { await s.offeredModels.count == 3 }
        #expect(await s.offeredModels.first?.name == "Default (recommended)")
        await s.kill()
    }

    @Test func replayKeepsTheSessionID() async throws {
        let peer = ScriptedPeer()
        let (w, _) = try await session(peer)
        for l in try Fixtures.lines("claude/basic.ndjson") { peer.send(String(decoding: l, as: UTF8.self)) }
        peer.end()
        let evs = try await withTimeout { await w.events.collect() }
        #expect(w.id == "11111111-2222-3333-4444-555555555555")
        #expect(evs.count("init") == 1 && evs.count("assistant") == 2 && evs.count("tool") == 2)
        #expect(evs.last?.isExit == true)
        #expect(evs.allSatisfy { $0.sessionID == w.id })
        #expect(peer.frames(type: "control_request").count == 1)
    }

    @Test func permissionRoundTrip() async throws {
        let peer = ScriptedPeer()
        let (_, s) = try await session(peer)
        peer.send(
            String(decoding: canUseTool("req_9", "Bash", #"{"command":"echo side-effect > /tmp/x"}"#), as: UTF8.self))
        let e = try await withTimeout { await s.events.next { $0.kind.name == "permission" } }
        guard case .permission(let p) = try #require(e).kind else { return }
        #expect(p.id == "req_9" && p.tool == "Bash" && p.question == "Allow Bash?")

        try await s.answer("req_9", .allow())
        try await s.answer("req_9", .deny("no"))
        try await s.answer("req_9", .allow())
        let out = peer.frames(type: "control_response").map(\.jsonString)
        #expect(
            out == [
                #"{"response":{"request_id":"req_9","response":{"behavior":"allow","updatedInput":{"command":"echo side-effect > /tmp/x"}},"subtype":"success"},"type":"control_response"}"#,
                #"{"response":{"request_id":"req_9","response":{"behavior":"deny","message":"no"},"subtype":"success"},"type":"control_response"}"#,
                // The first answer removed the input, so a second allow has an empty input.
                #"{"response":{"request_id":"req_9","response":{"behavior":"allow","updatedInput":{}},"subtype":"success"},"type":"control_response"}"#,
            ])
        await s.kill()
    }

    @Test func updatedInputWins() async throws {
        let peer = ScriptedPeer()
        let adapter = claudeAdapter()
        let (_, s) = try await session(peer, adapter)
        _ = adapter.parse(canUseTool("p1", "Bash", #"{"command":"rm -rf /"}"#))
        try await s.answer("p1", .allow(updatedInput: Data(#"{"command":"ls"}"#.utf8)))
        #expect(
            peer.frames(type: "control_response").first?.at("response", "response", "updatedInput") == ["command": "ls"]
        )
        await s.kill()
    }

    @Test(arguments: [
        (PermissionPolicy(mode: .auto), "Bash", #"{"command":"ls"}"#, true),
        (PermissionPolicy(mode: .autoEdit), "Edit", #"{"file_path":"/tmp/x"}"#, true),
        (PermissionPolicy(mode: .autoEdit), "Bash", #"{"command":"ls"}"#, false),
        (PermissionPolicy(allowTools: ["mcp__sling__*"]), "mcp__sling__echo", "{}", true),
        (PermissionPolicy(allowTools: ["mcp__sling__*"]), "mcp__other__echo", "{}", false),
    ])
    func policyAnswers(_ policy: PermissionPolicy, _ tool: String, _ input: String, _ allowed: Bool) async throws {
        let peer = ScriptedPeer()
        let adapter = claudeAdapter(policy)
        let (_, s) = try await session(peer, adapter)
        let evs = adapter.parse(canUseTool("req_x", tool, input))
        if allowed {
            #expect(evs.isEmpty)
            try await eventually { peer.frames(type: "control_response").count == 1 }
            let r = peer.frames(type: "control_response")[0]
            #expect(r.at("response", "response", "behavior") == "allow")
            #expect(r.at("response", "response", "updatedInput") == JSONValue.parse(input))
        } else {
            #expect(evs.permissions.count == 1 && evs.tools.isEmpty)
            try await Task.sleep(for: .milliseconds(50))
            #expect(peer.frames(type: "control_response").isEmpty)
        }
        await s.kill()
    }

    @Test func recordedDenyLeavesNothingOpen() async throws {
        let peer = ScriptedPeer()
        let adapter = claudeAdapter()
        let (_, s) = try await session(peer, adapter)
        var evs: [Event] = []
        for l in try Fixtures.lines("claude/0.3.273-2.1.267/permission_deny.ndjson") {
            for e in adapter.parse(l) {
                evs.append(e)
                if case .permission(let p) = e.kind { try await s.answer(p.id, .deny("no")) }
            }
        }
        #expect(!evs.tools.contains { $0.status == .cancelled })
        #expect(adapter.exitEvents(code: 0, stderr: "").isEmpty)
        #expect(peer.frames(type: "control_response").count == 1)
        await s.kill()
    }

    @Test func unsupportedControlRequest() async throws {
        let peer = ScriptedPeer()
        let (_, s) = try await session(peer)
        peer.send(#"{"type":"control_request","request_id":"req_hook_1","request":{"subtype":"hook_callback"}}"#)
        try await eventually { peer.frames(type: "control_response").count == 1 }
        #expect(
            peer.frames(type: "control_response")[0].jsonString
                == #"{"response":{"error":"agentbinder: unsupported control request subtype hook_callback","request_id":"req_hook_1","subtype":"error"},"type":"control_response"}"#
        )
        await s.kill()
    }

    @Test func interruptFrame() async throws {
        let peer = ScriptedPeer()
        let (_, s) = try await session(peer)
        try await s.interrupt()
        #expect(
            peer.seen.last?.jsonString
                == #"{"request":{"subtype":"interrupt"},"request_id":"req_2","type":"control_request"}"#)
        await s.kill()
    }

    @Test func setModel() async throws {
        let peer = ScriptedPeer()
        peer.expect({ $0.at("request", "subtype") == "initialize" }, reply: Self.initialize(#"[{"value":"default"}]"#))
        peer.expect({ $0.at("request", "model") == "sonnet" }) { req in
            [
                #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(req["request_id"].stringValue)","response":{}}}"#
            ]
        }
        peer.expect({ $0.at("request", "model") == "bogus" }) { req in
            [
                #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(req["request_id"].stringValue)","error":"model bogus not found"}}"#
            ]
        }
        peer.expect({ $0.at("request", "model") == "haiku" }) { req in
            [
                #"{"type":"control_response","response":{"subtype":"success","request_id":"nobody","response":{"models":[]}}}"#,
                #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(req["request_id"].stringValue)","response":{}}}"#,
            ]
        }
        let (_, s) = try await session(peer)
        try await eventually { await s.offeredModels.count == 1 }
        try await s.setModel("sonnet")
        #expect(
            peer.seen[1].jsonString
                == #"{"request":{"model":"sonnet","subtype":"set_model"},"request_id":"req_2","type":"control_request"}"#
        )
        do {
            try await s.setModel("bogus")
            Issue.record("no error")
        } catch let e as AgentBinderError {
            #expect(e == .vendor(code: 0, message: "claude: model bogus not found"))
        }
        // A reply to an unknown id is dropped.
        try await s.setModel("haiku")
        #expect(await s.offeredModels.count == 1)
        #expect(peer.pending == 0)
        await s.kill()
    }

    @Test func steer() async throws {
        let peer = ScriptedPeer()
        let adapter = claudeAdapter()
        let (_, s) = try await session(peer, adapter)
        await #expect(throws: AgentBinderError.noActiveTurn) { try await s.steer(Prompt("more")) }
        try await s.prompt(Prompt("start"))
        try await s.steer(Prompt("more"))
        #expect(peer.frames(type: "user").map { $0.at("message", "content").stringValue } == ["start", "more"])
        peer.send(#"{"type":"result","subtype":"success","result":"ok"}"#)
        try await eventually { !adapter.turnActive }
        await #expect(throws: AgentBinderError.noActiveTurn) { try await s.steer(Prompt("late")) }
        await s.kill()
    }

    // The CLI queues a second user frame during a turn.
    @Test func concurrentPrompt() async throws {
        let peer = ScriptedPeer()
        let (w, s) = try await session(peer)
        try await s.prompt(Prompt("one"))
        try await s.prompt(Prompt("two"))
        #expect(w.turn == 2)
        #expect(peer.frames(type: "user").count == 2)
        await s.kill()
    }
}

// MARK: driver

/// A fake `claude` on a search path. It records its argv, its working folder and its first user frame.
private struct FakeClaude {
    let dir: TempDir
    var argvFile: URL { dir.url.appendingPathComponent("argv.txt") }
    var pwdFile: URL { dir.url.appendingPathComponent("pwd.txt") }
    var userFile: URL { dir.url.appendingPathComponent("user.txt") }

    init(
        version: String = "2.1.0 (Claude Code)",
        models: String = #"[{"value":"default","displayName":"Default"},{"value":"opus","displayName":"Opus"}]"#
    )
        throws
    {
        dir = try TempDir()
        try dir.script(
            "claude",
            """
            case "$1" in --version) echo '\(version)'; exit 0 ;; esac
            printf '%s\\n' "$@" > '\(dir.path)/argv.txt'
            pwd > '\(dir.path)/pwd.txt'
            read -r line
            id=$(printf '%s' "$line" | sed 's/.*"request_id":"\\([^"]*\\)".*/\\1/')
            printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"models":\(models)}}}\\n' "$id"
            if read -r user; then printf '%s\\n' "$user" > '\(dir.path)/user.txt'; fi
            cat > /dev/null
            """)
    }

    func runtime() -> Runtime {
        Runtime(
            options: Runtime.Options(
                binarySearchPaths: [dir.url, URL(fileURLWithPath: "/usr/bin"), URL(fileURLWithPath: "/bin")],
                useLoginShellPath: false),
            now: Date.init, probeTimeout: .testProbe)
    }

    func argv() -> [String] {
        ((try? String(contentsOf: argvFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

@Suite("ClaudeDriverTests")
struct ClaudeDriverTests {
    static let head = [
        "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--input-format", "stream-json",
    ]

    @Test(arguments: [
        (
            ["--session-id=sid-1", "--permission-prompt-tool", "stdio", "--permission-mode", "default"], false,
            head + ["--session-id=sid-1", "--permission-prompt-tool", "stdio", "--permission-mode", "default"]
        ),
        (
            ["--permission-mode", "default", "--permission-prompt-tool", "my-bridge"], false,
            head + ["--permission-mode", "default", "--permission-prompt-tool", "my-bridge"]
        ),
        // A base command has no launch arguments, so the driver adds the permission tool.
        (["--x"], true, head + ["--print", "--x", "--permission-prompt-tool", "stdio"]),
    ])
    func arguments(_ launch: [String], _ oneShot: Bool, _ want: [String]) {
        #expect(ClaudeDriver.arguments(launch, oneShot: oneShot) == want)
    }

    @Test(arguments: [
        (
            StartRequest(workingDirectory: URL(fileURLWithPath: "/tmp"), sessionID: "sid-1"), false,
            ["--session-id=sid-1", "--permission-prompt-tool", "stdio", "--permission-mode", "default"]
        ),
        (
            StartRequest(workingDirectory: URL(fileURLWithPath: "/tmp"), sessionID: "sid-1"), true,
            ["--resume=sid-1", "--permission-prompt-tool", "stdio", "--permission-mode", "default"]
        ),
        (
            StartRequest(workingDirectory: URL(fileURLWithPath: "/tmp"), permissions: PermissionPolicy(mode: .inherit)),
            false, ["--permission-prompt-tool", "stdio"]
        ),
        (
            StartRequest(
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                extraArguments: ["--permission-prompt-tool", "my-bridge"]),
            false, ["--permission-mode", "default", "--permission-prompt-tool", "my-bridge"]
        ),
    ])
    func sessionArguments(_ base: StartRequest, _ resume: Bool, _ tail: [String]) async throws {
        let bin = try FakeClaude()
        let rt = bin.runtime()
        var r = base
        r.workingDirectory = bin.dir.url
        let s = try await resume ? rt.resume(r) : rt.start(r)
        try await eventually { bin.argv().count == Self.head.count + tail.count }
        #expect(bin.argv() == Self.head + tail)
        #expect(s.id == r.sessionID)
        await rt.close()
    }

    @Test func oneShot() async throws {
        let bin = try FakeClaude()
        let rt = bin.runtime()
        let s = try await rt.start(StartRequest(workingDirectory: bin.dir.url, oneShot: OneShot(prompt: "hi")))
        try await eventually { FileManager.default.fileExists(atPath: bin.userFile.path) }
        #expect(bin.argv().contains("--print"))
        let user = try #require(JSONValue.parse(try Data(contentsOf: bin.userFile)))
        #expect(user.at("message", "content") == "hi")
        await s.close()
        await rt.close()
    }

    @Test func modelProbe() async throws {
        let bin = try FakeClaude()
        let rt = bin.runtime()
        let other = try TempDir()
        let models = try await rt.models(.claude, query: ModelQuery(workingDirectory: other.url))
        #expect(
            models == [ModelInfo(id: "default", name: "Default", isDefault: true), ModelInfo(id: "opus", name: "Opus")])
        let argv = bin.argv()
        #expect(argv.starts(with: ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json"]))
        #expect(!argv.contains("--include-partial-messages"))
        #expect(argv.last == "--strict-mcp-config")
        // Quirk: the probe ignores the working folder of the query.
        let pwd = try String(contentsOf: bin.pwdFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pwd != other.path)
        await rt.close()
    }

    @Test func modelProbeFallsBackToAliases() async throws {
        let bin = try FakeClaude(models: "[]")
        let rt = bin.runtime()
        #expect(try await rt.models(.claude) == ClaudeDriver.aliases)
        await rt.close()
    }

    @Test func belowFloor() async throws {
        let bin = try FakeClaude(version: "1.9.0 (Claude Code)")
        let rt = bin.runtime()
        await #expect(throws: AgentBinderError.belowVersionFloor(.claude, version: "1.9.0", floor: "2.0.0")) {
            _ = try await rt.start(StartRequest(workingDirectory: bin.dir.url))
        }
        await rt.close()
    }

    // Quirk: a base command also gets the version check.
    @Test func baseCommandVersionCheck() async throws {
        let bin = try FakeClaude(version: "")
        let rt = bin.runtime()
        let r = StartRequest(
            workingDirectory: bin.dir.url, baseCommand: [bin.dir.url.appendingPathComponent("claude").path])
        do {
            _ = try await rt.start(r)
            Issue.record("no error")
        } catch let e as AgentBinderError {
            #expect(e.code == "launch")
            #expect("\(e)".contains("cannot determine --version"))
        }
        await rt.close()
    }
}
