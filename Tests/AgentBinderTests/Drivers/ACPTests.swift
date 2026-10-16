import Foundation
import Testing

@testable import AgentBinder

private func acpConfig(_ v: ACPVariant = .copilot, _ change: (inout ACPConfig) -> Void = { _ in }) -> ACPConfig {
    var c = ACPConfig(variant: v)
    c.cwd = "/w"
    c.handshakeTimeout = .seconds(2)
    change(&c)
    return c
}

private func result(_ req: JSONValue, _ body: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(req["id"]!.jsonString),"result":\#(body)}"#
}

private func failure(_ req: JSONValue, _ code: Int, _ message: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(req["id"]!.jsonString),"error":{"code":\#(code),"message":"\#(message)"}}"#
}

private func update(_ body: String, session: String = "ses_1") -> String {
    #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"\#(session)","update":\#(body)}}"#
}

private let initReply =
    #"{"protocolVersion":1,"authMethods":[{"id":"github-device","name":"GitHub"}],"agentCapabilities":{"mcpCapabilities":{"http":true}}}"#

extension ScriptedPeer {
    fileprivate func acpAgent(newSession: String = #"{"sessionId":"ses_1"}"#) {
        expect(method: "initialize") { [result($0, initReply)] }
        expect(method: "session/new") { [result($0, newSession)] }
    }

    fileprivate func frames(method: String) -> [JSONValue] { seen.filter { $0["method"]?.string == method } }
    fileprivate func reply(to id: JSONValue) -> JSONValue? { seen.first { $0["id"] == id && $0["method"] == nil } }
}

/// A scripted file system. It records each call.
private final class RecordingFileSystem: FileSystemAccess {
    let content: String
    let fails: Bool
    let calls = Locked<[String]>([])

    init(content: String = "file body", fails: Bool = false) {
        self.content = content
        self.fails = fails
    }

    func readTextFile(_ path: String) async throws -> String {
        calls.withLock { $0.append("read " + path) }
        if fails { throw AgentBinderError.invalidRequest("no such file") }
        return content
    }

    func writeTextFile(_ path: String, content: String) async throws {
        calls.withLock { $0.append("write \(path)=\(content)") }
        if fails { throw AgentBinderError.invalidRequest("read-only") }
    }
}

// MARK: fixtures

@Suite("ACPFixtureTests")
struct ACPFixtureTests {
    static let all = Fixtures.list("acp")

    @Test(arguments: all) func golden(_ rel: String) throws {
        try Fixtures.expectGolden(rel, try Fixtures.parse(rel, ACPAdapter(acpConfig())))
    }

    @Test func updates() throws {
        let evs = try Fixtures.parse("acp/updates.ndjson", ACPAdapter(acpConfig()))
        let tools = evs.tools
        #expect(tools.map(\.id) == ["t1", "t1", "t1", "t2", "t2", "t3", "t4"])
        #expect(tools[0].kind == .edit && tools[0].status == .started && tools[0].paths == ["/tmp/coa.txt"])
        #expect(tools[0].name == "Edit file" && tools[0].input == #"{"path":"/tmp/coa.txt"}"#)
        // A status that is not final stays started.
        #expect(tools[1].status == .started)
        #expect(tools[2].status == .completed && tools[2].output == "/tmp/coa.txt")
        #expect(tools[3].kind == .exec && tools[4].status == .failed && tools[4].output == "permission denied")
        #expect(tools[5].name == "fetch" && tools[5].kind == .read)
        #expect(tools[6].name == "tool" && tools[6].kind == .other)
        #expect(evs.compactMap(\.assistantText) == ["pong"])
        #expect(
            evs.filter { $0.assistantText != nil }.allSatisfy { e in
                if case .assistant(_, let delta) = e.kind { return !delta }
                return false
            })
        let usage = evs.compactMap { e -> Usage? in
            if case .usage(let u) = e.kind { return u }
            return nil
        }
        #expect(usage == [Usage(input: 12, output: 4, costUSD: 0.5)])
        #expect(evs.count("status") == 4)
    }
}

// MARK: adapter

@Suite("ACPAdapterTests")
struct ACPAdapterTests {
    @Test(arguments: [
        (["a1:allow_once", "r1:reject_once"], true, #"{"optionId":"a1","outcome":"selected"}"#),
        (["a1:allow_once", "r1:reject_once"], false, #"{"optionId":"r1","outcome":"selected"}"#),
        (["a2:allow_always", "r2:reject_always"], false, #"{"optionId":"r2","outcome":"selected"}"#),
        (["x:other", "y:other"], true, #"{"optionId":"x","outcome":"selected"}"#),
        (["x:other", "y:other"], false, #"{"optionId":"y","outcome":"selected"}"#),
        ([], true, #"{"outcome":"cancelled"}"#),
    ])
    func outcome(_ options: [String], _ allow: Bool, _ want: String) {
        let opts = options.map { o -> ACPAdapter.Option in
            let p = o.split(separator: ":")
            return ACPAdapter.Option(id: String(p[0]), kind: String(p[1]))
        }
        #expect(ACPAdapter.outcome(opts, allow: allow).jsonString == want)
    }

    @Test(arguments: [
        ("3f2b1c4d-1111-2222-3333-444455556666\n", "3f2b1c4d-1111-2222-3333-444455556666"),
        ("created chat 3F2B1C4D-1111-2222-3333-444455556666.\n", "3F2B1C4D-1111-2222-3333-444455556666"),
        (#"chat id: "3f2b1c4d-1111-2222-3333-444455556666""#, "3f2b1c4d-1111-2222-3333-444455556666"),
        ("creating chat\nmy chat id\n", "my chat id"),
        ("no identifier here", "no identifier here"),
        ("", ""),
        ("\n  \n", ""),
    ])
    func lastIdentifier(_ text: String, _ want: String) { #expect(ACPVariant.lastIdentifier(text) == want) }

    @Test(arguments: [
        (
            ["--resume", "x", "--model", "m", "-c", "y", "--continue=z", "--resume=q", "--trust"],
            ["--model", "m", "--trust"]
        ),
        (["--continue"], []),
    ])
    func stripCursorArguments(_ args: [String], _ want: [String]) {
        #expect(ACPVariant.stripCursorArguments(args) == want)
    }

    @Test(arguments: [
        (ACPVariant.copilot, ["--model", "m"], "", ["--model", "m", "--acp"]),
        (.copilot, ["--acp=1"], "", ["--acp=1"]),
        (.cursor, ["--trust", "--resume", "old"], "", ["--trust", "acp"]),
        (.gemini, ["--model", "g"], "  --acp  --experimental-acp", ["--model", "g", "--experimental-acp"]),
        (.gemini, [], "  --acp  start ACP mode", ["--acp"]),
        (.gemini, [], "", ["--experimental-acp"]),
    ])
    func arguments(_ v: ACPVariant, _ launch: [String], _ help: String, _ want: [String]) async {
        #expect(await v.arguments(launch) { help } == want)
    }

    @Test(arguments: [
        (ACPVariant.copilot, ["a", "github-device", "b"], "github-device"),
        (.copilot, ["device-x", "github"], "github"),
        (.cursor, ["x", "cursor_login"], "cursor_login"),
        (.gemini, ["oauth", "api-key"], "oauth"),
    ])
    func authMethod(_ v: ACPVariant, _ methods: [String], _ want: String) {
        #expect(v.authMethod(methods) == want)
        #expect(v.authMethod([]) == nil)
    }

    @Test func instructionsOnTheFirstPromptOnly() throws {
        let a = ACPAdapter(acpConfig { $0.instructions = " be brief " })
        func text(_ f: Data) -> String? { JSONValue.parse(f)?.at("params", "prompt")?.array?.last?["text"]?.string }
        let first = try a.encodePrompt(Prompt("hi"))
        #expect(text(first) == "<session-instructions>\nbe brief\n</session-instructions>\n\nhi")
        _ = a.parse(Data(#"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}"#.utf8))
        #expect(text(try a.encodePrompt(Prompt("again"))) == "again")
    }

    @Test func promptContent() throws {
        let a = ACPAdapter(acpConfig())
        let f = try a.encodePrompt(
            Prompt(
                "look",
                attachments: [
                    PromptAttachment(mime: "text/plain", source: .data(Data("notes".utf8))),
                    PromptAttachment(mime: "image/png", source: .data(Data([1, 2]))),
                ]))
        let v = try #require(JSONValue.parse(f))
        #expect(v["method"] == "session/prompt" && v["id"] == 1)
        #expect(
            v.at("params", "prompt")?.jsonString
                == #"[{"data":"AQI=","mimeType":"image/png","type":"image"},{"text":"notes","type":"text"},{"text":"look","type":"text"}]"#
        )
        #expect(a.turnActive)
        #expect(throws: AgentBinderError.turnActive) { try a.encodePrompt(Prompt("x")) }
    }

    // Fixed on purpose: an attachment error leaves no turn open, and the instructions wait for the next prompt.
    @Test func attachmentErrorLeavesNoTurn() throws {
        let a = ACPAdapter(acpConfig { $0.instructions = "rules" })
        let bad = Prompt("x", attachments: [PromptAttachment(source: .file(URL(fileURLWithPath: "/no/such/file.txt")))])
        #expect(throws: AgentBinderError.self) { try a.encodePrompt(bad) }
        #expect(!a.turnActive)
        let f = try a.encodePrompt(Prompt("hi"))
        #expect(
            JSONValue.parse(f)?.at("params", "prompt")?.array?.first?["text"]?.string?.hasPrefix(
                "<session-instructions>") == true)
    }

    @Test(arguments: [
        (#"{"stopReason":"end_turn"}"#, "success", false, ""),
        (#"{}"#, "success", false, ""),
        (#"{"stopReason":"cancelled"}"#, "cancelled", true, "turn cancelled"),
        (#"{"stopReason":"refused"}"#, "refused", true, "stop: refused"),
    ])
    func promptResults(_ body: String, _ subtype: String, _ isError: Bool, _ text: String) throws {
        let a = ACPAdapter(acpConfig())
        _ = try a.encodePrompt(Prompt("hi"))
        let evs = a.parse(Data(#"{"jsonrpc":"2.0","id":1,"result":\#(body)}"#.utf8))
        let r = try #require(evs.results.first)
        #expect(r.subtype == subtype && r.isError == isError && r.text == text)
        if subtype == "refused" {
            #expect(r.endReason != nil && r.code?.hasPrefix("copilot.") == true)
        } else {
            #expect(r.code == nil && r.endReason == nil)
        }
        #expect(!a.turnActive)
        #expect(a.exitEvents(code: 0, stderr: "").isEmpty)
    }

    @Test func promptUsageAndError() throws {
        let a = ACPAdapter(acpConfig())
        _ = try a.encodePrompt(Prompt("hi"))
        let evs = a.parse(
            Data(
                #"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn","usage":{"inputTokens":5,"output_tokens":2,"cachedReadTokens":1,"cached_write_tokens":3,"cost":0.25}}}"#
                    .utf8))
        #expect(evs.map(\.kind.name) == ["usage", "result"])
        if case .usage(let u) = evs[0].kind {
            #expect(u == Usage(input: 5, output: 2, cacheRead: 1, cacheCreation: 3, costUSD: 0.25))
        }
        _ = try a.encodePrompt(Prompt("again"))
        let err = a.parse(
            Data(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"rate limit exceeded"}}"#.utf8))
        #expect(err.errors.map(\.code) == ["copilot.rate_limited"] && err.results.isEmpty)
        // A reply to another id is not the turn end.
        #expect(a.parse(Data(#"{"jsonrpc":"2.0","id":99,"result":{}}"#.utf8)).isEmpty)
    }

    @Test func exitEvents() throws {
        let a = ACPAdapter(acpConfig())
        // Fixed on purpose: an idle session that ends with code 0 is quiet.
        #expect(a.exitEvents(code: 0, stderr: "").isEmpty)
        #expect(
            a.exitEvents(code: 3, stderr: "").errors.map(\.message) == [
                "copilot exited with code 3 before the turn ended"
            ])
        _ = try a.encodePrompt(Prompt("hi"))
        _ = a.parse(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        #expect(a.exitEvents(code: 1, stderr: "x").isEmpty)
        // A new prompt resets the latch.
        _ = try a.encodePrompt(Prompt("two"))
        let evs = a.exitEvents(code: 1, stderr: "copilot died")
        #expect(evs.errors.count == 1 && evs.errors[0].code.hasPrefix("copilot."))
        #expect(a.exitEvents(code: 0, stderr: "").count == 1)
    }

    @Test func interruptFrame() throws {
        let a = ACPAdapter(acpConfig())
        _ = try a.encodePrompt(Prompt("hi"))
        #expect(
            JSONValue.parse(try a.encodeInterrupt())?.jsonString
                == #"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":""}}"#)
        #expect(a.turnActive)
    }

    @Test func otherSessionsAreDropped() {
        let a = ACPAdapter(acpConfig())
        _ = a.parse(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        let chunk = #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"x"}}"#
        // No session yet: only an empty id passes.
        #expect(a.parse(Data(update(chunk, session: "ses_other").utf8)).isEmpty)
        #expect(a.parse(Data(update(chunk, session: "").utf8)).count == 1)
        #expect(a.parse(Data(#"{"jsonrpc":"2.0","method":"other/note","params":{}}"#.utf8)).isEmpty)
    }
}

// MARK: wire

@Suite("ACPWireTests")
struct ACPWireTests {
    private func session(
        _ peer: ScriptedPeer, _ config: ACPConfig = acpConfig()
    ) async throws -> (WireSession, ACPSession, ACPAdapter) {
        let a = ACPAdapter(config)
        let w = try await peer.session(a, harness: config.variant.harness)
        return (w, ACPSession(wire: w, adapter: a), a)
    }

    @Test func handshake() async throws {
        let peer = ScriptedPeer()
        peer.acpAgent()
        let (w, s, a) = try await session(
            peer,
            acpConfig {
                $0.clientName = "oversire"
                $0.clientVersion = "1.2"
                $0.fileSystem = RecordingFileSystem()
                $0.mcpServers = [
                    MCPServer(name: "local", transport: .stdio(command: "cmd", args: ["a"], env: [:]))
                ]
            })
        try await eventually { w.id == "ses_1" }
        #expect(a.authMethods == ["github-device"] && a.trustHTTPMCP)
        #expect(
            peer.seen.first?.jsonString
                == #"{"id":1,"jsonrpc":"2.0","method":"initialize","params":{"clientCapabilities":{"auth":{"terminal":false},"fs":{"readTextFile":true,"writeTextFile":true},"terminal":false},"clientInfo":{"name":"oversire","version":"1.2"},"protocolVersion":1}}"#
        )
        #expect(
            peer.frames(method: "session/new").first?["params"]?.jsonString
                == #"{"cwd":"/w","mcpServers":[{"args":["a"],"command":"cmd","name":"local"}]}"#)
        await s.kill()
    }

    @Test func mcpServers() {
        let servers = [
            MCPServer(
                name: "remote", transport: .http(url: URL(string: "https://x/mcp")!, headers: ["Authorization": "t"])),
            MCPServer(name: "local", transport: .stdio(command: "cmd", args: ["a", "b"], env: ["K": "V"])),
            MCPServer(name: "", transport: .stdio(command: "x", args: [], env: [:])),
        ]
        #expect(
            MCPRender.acpServers(servers, http: true).jsonString
                == #"[{"headers":[{"name":"Authorization","value":"t"}],"name":"remote","type":"http","url":"https://x/mcp"},{"args":["a","b"],"command":"cmd","env":[{"name":"K","value":"V"}],"name":"local"}]"#
        )
        #expect(
            MCPRender.acpServers(Array(servers.prefix(1)), http: false).jsonString == "[]")
        #expect(MCPRender.acpServers(servers, http: false).array?.count == 1)
    }

    @Test func setModelInTheHandshake() async throws {
        let peer = ScriptedPeer()
        peer.acpAgent(
            newSession:
                #"{"sessionId":"ses_1","models":{"currentModelId":"a","availableModels":[{"modelId":"a"},{"modelId":""}]}}"#
        )
        peer.expect(method: "session/set_model") { [result($0, "{}")] }
        let (_, s, _) = try await session(peer, acpConfig { $0.model = "b" })
        let e = try await withTimeout { await s.events.next { $0.kind.name == "status" } }
        if case .status(_, let text) = try #require(e).kind { #expect(text == "model b") }
        #expect(peer.frames(method: "session/set_model").first?["params"] == ["sessionId": "ses_1", "modelId": "b"])
        #expect(s.offeredModels == [ModelInfo(id: "a")])
        await s.kill()
    }

    @Test func refusedModelIsAStatus() async throws {
        let peer = ScriptedPeer()
        peer.acpAgent()
        peer.expect(method: "session/set_model") { [failure($0, -32602, "bad model")] }
        let (_, s, _) = try await session(peer, acpConfig { $0.model = "b" })
        let e = try await withTimeout { await s.events.next { $0.kind.name == "status" } }
        guard case .status(_, let text) = try #require(e).kind else { return }
        #expect(text?.hasPrefix("model not applied: ") == true && text?.contains("copilot session/set_model") == true)
        await s.kill()
    }

    @Test func sessionModels() async throws {
        let peer = ScriptedPeer()
        let fixture = try #require(
            JSONValue.parse(try String(contentsOf: Fixtures.url("models/acp_session_new.json"), encoding: .utf8))?
                .jsonString)
        peer.acpAgent(newSession: fixture)
        peer.expect(method: "session/set_model") { [result($0, "{}")] }
        let (_, s, _) = try await session(peer, acpConfig(.cursor))
        #expect(s.offeredModels.map(\.id) == ["composer-2", "gpt-5.5"])
        #expect(s.offeredModels.filter(\.isDefault).map(\.id) == ["composer-2"])
        try await s.setModel("gpt-5.5")
        #expect(
            peer.frames(method: "session/set_model").first?["params"] == ["sessionId": "ses_1", "modelId": "gpt-5.5"])
        #expect(s.offeredModels.filter(\.isDefault).map(\.id) == ["gpt-5.5"])
        await s.kill()
    }

    @Test func setModelWithoutAList() async throws {
        let peer = ScriptedPeer()
        peer.acpAgent()
        let (_, s, _) = try await session(peer)
        #expect(s.offeredModels.isEmpty)
        await #expect(throws: AgentBinderError.unsupported("copilot offered no models")) { try await s.setModel("x") }
        await s.kill()
    }

    @Test func loadKnownSession() async throws {
        let peer = ScriptedPeer()
        peer.expect(method: "initialize") { [result($0, initReply)] }
        peer.expect(method: "session/resume") { [failure($0, -32601, "method not found")] }
        peer.expect(method: "session/load") { [result($0, "{}")] }
        let (w, s, _) = try await session(
            peer,
            acpConfig {
                $0.sessionID = "ses_old"; $0.resume = true
            })
        try await eventually { w.id == "ses_old" }
        #expect(peer.frames(method: "session/load").first?.at("params", "sessionId") == "ses_old")
        #expect(peer.frames(method: "session/new").isEmpty)
        await s.kill()
    }

    // Fixed on purpose: a failed resume throws. It does not open a new session.
    @Test func failedResumeThrows() async throws {
        let peer = ScriptedPeer()
        peer.expect(method: "initialize") { [result($0, initReply)] }
        peer.expect(method: "session/resume") { [failure($0, -32601, "method not found")] }
        peer.expect(method: "session/load") { [failure($0, -32602, "not found")] }
        let a = ACPAdapter(
            acpConfig {
                $0.sessionID = "ses_old"; $0.resume = true
            })
        let w = try await peer.session(a, harness: .copilot)
        let e = try await withTimeout { await w.events.next { $0.errorCode != nil } }
        #expect(e?.errorCode == "handshake_failed")
        #expect(w.lastError?.message == "\(AgentBinderError.resumeUnsupported)")
        #expect(peer.frames(method: "session/new").isEmpty)
        await w.kill()
    }

    // A new Cursor chat has no session/resume, and session/load does not know it yet.
    @Test func freshCursorChat() async throws {
        let peer = ScriptedPeer()
        peer.expect(method: "initialize") { [result($0, initReply)] }
        peer.expect(method: "session/load") { [failure($0, -32602, "Session not found")] }
        peer.expect(method: "session/new") { [result($0, #"{"sessionId":"ses_new"}"#)] }
        let (w, s, _) = try await session(
            peer,
            acpConfig(.cursor) {
                $0.sessionID = "chat-1"; $0.fresh = true
            })
        try await eventually { w.id == "ses_new" }
        #expect(peer.frames(method: "session/resume").isEmpty)
        await s.kill()
    }

    @Test func authenticateThenRetry() async throws {
        let peer = ScriptedPeer()
        peer.expect(method: "initialize") {
            [result($0, #"{"authMethods":[{"id":"x"},{"id":"cursor_login"}]}"#)]
        }
        peer.expect(method: "session/new") { [failure($0, -32000, "auth required")] }
        peer.expect(method: "authenticate") { [result($0, "{}")] }
        peer.expect(method: "session/new") { [result($0, #"{"sessionId":"ses_2"}"#)] }
        let (w, s, _) = try await session(peer, acpConfig(.cursor))
        try await eventually { w.id == "ses_2" }
        #expect(peer.frames(method: "authenticate").first?["params"] == ["methodId": "cursor_login"])
        await s.kill()
    }

    @Test func preferredAuthMethod() async throws {
        let peer = ScriptedPeer()
        peer.expect(method: "initialize") { [result($0, initReply)] }
        peer.expect(method: "session/new") { [failure($0, -32000, "auth required")] }
        peer.expect(method: "authenticate") { [result($0, "{}")] }
        peer.expect(method: "session/new") { [result($0, #"{"sessionId":"ses_2"}"#)] }
        let (w, s, _) = try await session(peer, acpConfig { $0.authMethod = "api-key" })
        try await eventually { w.id == "ses_2" }
        #expect(peer.frames(method: "authenticate").first?["params"] == ["methodId": "api-key"])
        await s.kill()
    }

    @Test func sessionOpenFails() async throws {
        let peer = ScriptedPeer()
        peer.expect(method: "initialize") { [result($0, "{}")] }
        peer.expect(method: "session/new") { [result($0, "{}")] }
        let a = ACPAdapter(acpConfig())
        let w = try await peer.session(a, harness: .copilot)
        _ = try await withTimeout { await w.events.next { $0.errorCode != nil } }
        #expect(w.lastError?.message.contains("session/new returned no sessionId") == true)
        await w.kill()
    }

    @Test func promptRoundTrip() async throws {
        let peer = ScriptedPeer()
        peer.acpAgent()
        peer.expect(method: "session/prompt") { req in
            [
                update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"pong"}}"#),
                result(req, #"{"stopReason":"end_turn"}"#),
            ]
        }
        let (_, s, a) = try await session(peer)
        try await s.prompt(Prompt("ping"))
        let e = try await withTimeout { await s.events.next { $0.isResult } }
        #expect(e?.sessionID == "ses_1")
        #expect(!a.turnActive)
        let p = try #require(peer.frames(method: "session/prompt").first)
        #expect(p.at("params", "sessionId") == "ses_1")
        await s.kill()
    }

    @Test func permissionRoundTrip() async throws {
        let peer = ScriptedPeer()
        peer.acpAgent()
        let (_, s, _) = try await session(peer)
        peer.send(
            #"{"jsonrpc":"2.0","id":5,"method":"session/request_permission","params":{"sessionId":"ses_1","toolCall":{"toolCallId":"t","title":"Run tests","kind":"execute"},"options":[{"optionId":"a1","kind":"allow_once"},{"optionId":"r1","kind":"reject_once"}]}}"#
        )
        let e = try await withTimeout { await s.events.next { $0.kind.name == "permission" } }
        guard case .permission(let p) = try #require(e).kind else { return }
        #expect(p.id == "5" && p.kind == .exec && p.tool == "Run tests" && p.question == "Allow Run tests?")
        try await s.answer("5", .allow())
        #expect(
            peer.reply(to: 5)?.jsonString
                == #"{"id":5,"jsonrpc":"2.0","result":{"outcome":{"optionId":"a1","outcome":"selected"}}}"#)
        peer.send(
            #"{"jsonrpc":"2.0","id":"p9","method":"session/request_permission","params":{"toolCall":{"kind":"edit"},"options":[{"optionId":"a9","kind":"allow_once"},{"optionId":"r9","kind":"reject_once"}]}}"#
        )
        let e2 = try await withTimeout { await s.events.next { $0.kind.name == "permission" } }
        guard case .permission(let p2) = try #require(e2).kind else { return }
        #expect(p2.id == #""p9""# && p2.tool == "edit" && p2.question == "Agent requests permission")
        try await s.answer(p2.id, .deny("no"))
        #expect(peer.reply(to: "p9")?.at("result", "outcome") == ["outcome": "selected", "optionId": "r9"])
        await s.kill()
    }

    @Test func autoPolicy() async throws {
        let peer = ScriptedPeer()
        peer.acpAgent()
        let (_, s, a) = try await session(peer, acpConfig { $0.policy = PermissionPolicy(mode: .auto) })
        let evs = a.parse(
            Data(
                #"{"jsonrpc":"2.0","id":6,"method":"session/request_permission","params":{"toolCall":{"title":"Run"},"options":[{"optionId":"a1","kind":"allow_once"}]}}"#
                    .utf8))
        #expect(evs.isEmpty)
        try await eventually { peer.reply(to: 6) != nil }
        #expect(peer.reply(to: 6)?.at("result", "outcome", "optionId") == "a1")
        await s.kill()
    }

    @Test func fileSystem() async throws {
        let peer = ScriptedPeer()
        peer.acpAgent()
        let fs = RecordingFileSystem()
        let (_, s, _) = try await session(peer, acpConfig { $0.fileSystem = fs })
        peer.send(#"{"jsonrpc":"2.0","id":11,"method":"fs/read_text_file","params":{"path":"/tmp/coa.txt"}}"#)
        peer.send(
            #"{"jsonrpc":"2.0","id":12,"method":"fs/write_text_file","params":{"path":"/tmp/coa.txt","content":"new body"}}"#
        )
        try await eventually { peer.reply(to: 11) != nil && peer.reply(to: 12) != nil }
        #expect(peer.reply(to: 11)?["result"] == ["content": "file body"])
        #expect(peer.reply(to: 12)?["result"] == [:])
        #expect(Set(fs.calls.value) == ["read /tmp/coa.txt", "write /tmp/coa.txt=new body"])
        await s.kill()
    }

    @Test func fileSystemErrors() async throws {
        let peer = ScriptedPeer()
        peer.acpAgent()
        let (_, s, _) = try await session(peer, acpConfig { $0.fileSystem = RecordingFileSystem(fails: true) })
        peer.send(#"{"jsonrpc":"2.0","id":11,"method":"fs/read_text_file","params":{"path":"/x"}}"#)
        try await eventually { peer.reply(to: 11) != nil }
        #expect(peer.reply(to: 11)?.at("error", "code") == -32603)
        await s.kill()

        let peer2 = ScriptedPeer()
        peer2.acpAgent()
        let (_, s2, _) = try await session(peer2)
        peer2.send(#"{"jsonrpc":"2.0","id":11,"method":"fs/read_text_file","params":{"path":"/x"}}"#)
        try await eventually { peer2.reply(to: 11) != nil }
        #expect(
            peer2.reply(to: 11)?["error"]
                == ["code": -32601, "message": "agentbinder: file system access is not enabled"])
        await s2.kill()
    }

    @Test func unknownMethod() async throws {
        let peer = ScriptedPeer()
        peer.acpAgent()
        let (_, s, _) = try await session(peer)
        peer.send(#"{"jsonrpc":"2.0","id":"abc","method":"terminal/create","params":{}}"#)
        try await eventually { peer.reply(to: "abc") != nil }
        #expect(
            peer.reply(to: "abc")?.jsonString
                == #"{"error":{"code":-32601,"message":"agentbinder: client method unsupported: terminal/create"},"id":"abc","jsonrpc":"2.0"}"#
        )
        await s.kill()
    }
}

// MARK: driver

/// A fake ACP agent on a search path, under the binary name of each variant.
private struct FakeACP {
    let dir: TempDir

    init(help: String = "--acp", models: String = "") throws {
        dir = try TempDir()
        let session = models.isEmpty ? #"{"sessionId":"ses_1"}"# : models
        let body = """
            case "$1" in
              --help) echo '\(help)'; exit 0 ;;
              create-chat) echo 'created chat 3f2b1c4d-1111-2222-3333-444455556666'; exit 0 ;;
            esac
            printf '%s\\n' "$@" > '\(dir.path)/argv.txt'
            reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$id" "$1"; }
            while IFS= read -r line; do
              printf '%s\\n' "$line" >> '\(dir.path)/in.txt'
              id=$(printf '%s' "$line" | sed -n 's/^.*"id":\\([0-9][0-9]*\\).*$/\\1/p')
              case "$line" in
                *'"method":"initialize"'*) reply '{"protocolVersion":1}' ;;
                *'"method":"session/new"'*) reply '\(session)' ;;
                *'"method":"session/load"'*) reply '{}' ;;
                *'"method":"session/resume"'*) reply '{}' ;;
                *'"method":"session/set_model"'*) reply '{}' ;;
                *'"method":"session/prompt"'*) reply '{"stopReason":"end_turn"}' ;;
              esac
            done
            """
        for name in ["copilot", "cursor-agent", "gemini"] { try dir.script(name, body) }
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

@Suite("ACPDriverTests")
struct ACPDriverTests {
    @Test(arguments: [
        (Harness.copilot, false, ["--model", "gpt-5", "--effort", "low", "--acp"]),
        (.copilot, true, ["--resume", "cp-1", "--model", "gpt-5", "--effort", "low", "--acp"]),
        (.gemini, false, ["--model", "gpt-5", "--acp"]),
    ])
    func launch(_ h: Harness, _ resume: Bool, _ want: [String]) async throws {
        let bin = try FakeACP()
        let rt = bin.runtime()
        var r = StartRequest(
            harness: h, workingDirectory: bin.dir.url, model: "gpt-5", effort: Effort(rawValue: "low"),
            instructions: "rules", permissions: PermissionPolicy(mode: .auto))
        if resume { r.sessionID = "cp-1" }
        let s = try await resume ? rt.resume(r) : rt.start(r)
        #expect(bin.argv() == want)
        #expect(!bin.argv().contains("--append-system-prompt"))
        await s.close()
        await rt.close()
    }

    @Test func cursorStart() async throws {
        let bin = try FakeACP()
        let rt = bin.runtime()
        let home = try TempDir()
        let s = try await rt.start(
            StartRequest(
                harness: .cursor, workingDirectory: bin.dir.url, home: home.url, model: "composer-2",
                permissions: PermissionPolicy(mode: .auto), extraArguments: ["--resume", "x"]))
        #expect(bin.argv() == ["--trust", "acp"])
        // The new chat goes to session/load, which the fake accepts.
        #expect(s.id == "3f2b1c4d-1111-2222-3333-444455556666")
        let load = try #require(bin.input().first { $0["method"] == "session/load" })
        #expect(load.at("params", "sessionId") == "3f2b1c4d-1111-2222-3333-444455556666")
        #expect(!bin.input().contains { $0["method"] == "session/resume" })
        await s.close()
        await rt.close()
    }

    @Test func oneShot() async throws {
        let bin = try FakeACP()
        let rt = bin.runtime()
        let s = try await rt.start(
            StartRequest(harness: .copilot, workingDirectory: bin.dir.url, oneShot: OneShot(prompt: "go")))
        let evs = try await withTimeout { await s.events.collect() }
        #expect(evs.results.count == 1 && evs.last?.isExit == true)
        #expect(evs.errors.isEmpty)
        await rt.close()
    }

    @Test func modelProbe() async throws {
        let fixture = try String(contentsOf: Fixtures.url("models/acp_session_new.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bin = try FakeACP(models: fixture)
        let rt = bin.runtime()
        let models = try await rt.models(.cursor)
        #expect(models.map(\.id) == ["composer-2", "gpt-5.5"])
        #expect(models.first?.isDefault == true)
        #expect(!bin.input().contains { $0["method"] == "authenticate" })
        #expect(bin.input().first { $0["method"] == "session/new" }?.at("params", "mcpServers") == [])
        await rt.close()
    }

    @Test func modelProbeWithoutAList() async throws {
        let bin = try FakeACP()
        let rt = bin.runtime()
        await #expect(throws: AgentBinderError.unsupported("gemini offered no models")) {
            _ = try await rt.models(.gemini)
        }
        await rt.close()
    }

    @Test func resumeNeedsAnID() async throws {
        let bin = try FakeACP()
        let rt = bin.runtime()
        await #expect(throws: AgentBinderError.resumeUnsupported) {
            _ = try await rt.resume(StartRequest(harness: .copilot, workingDirectory: bin.dir.url))
        }
        await rt.close()
    }
}
