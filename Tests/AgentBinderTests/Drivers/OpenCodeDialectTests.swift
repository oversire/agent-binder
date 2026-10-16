import Foundation
import Testing

@testable import AgentBinder

/// Feeds bus frames to a dialect inside one turn.
private func feed<D: OpenCodeDialect>(
    _ d: inout D, _ wire: OpenCodeWire, _ frames: [Data], _ t: inout OpenCodeTurn
) -> [OpenCodeStep] {
    frames.compactMap { raw in wire.frame(raw).map { d.parse($0.type, $0.payload, &t) } }
}

private func frames(_ lines: String...) -> [Data] { lines.map { Data($0.utf8) } }

private func v1() -> OpenCodeV1Dialect {
    OpenCodeV1Dialect(sessionID: "ses_1", directory: "/w", model: nil, effort: nil, instructions: nil)
}

private func v2() -> OpenCodeV2Dialect { OpenCodeV2Dialect(sessionID: "ses_2", directory: "/w", variant: nil) }

private func texts(_ evs: [Event]) -> [String] {
    evs.compactMap { e in
        guard case .assistant(let t, let delta) = e.kind else { return nil }
        return "\(t):\(delta)"
    }
}

private func v1Part(_ id: String, _ text: String, message: String = "msg_a") -> String {
    #"{"type":"message.part.updated","properties":{"part":{"id":"\#(id)","messageID":"\#(message)","sessionID":"ses_1","type":"text","text":"\#(text)"}}}"#
}

private func v2Event(_ type: String, _ data: String) -> String {
    #"{"id":"e","type":"\#(type)","data":{"sessionID":"ses_2",\#(data)}}"#
}

// MARK: fixtures

@Suite("OpenCodeFixtureTests")
struct OpenCodeFixtureTests {
    @Test func v1Turn() throws {
        var d = v1()
        var t = OpenCodeTurn(busy: true)
        let steps = feed(&d, .v1, try Fixtures.lines("opencode/turn.ndjson"), &t)
        let evs = steps.flatMap(\.events)
        try Fixtures.expectGolden("opencode/turn.ndjson", evs)
        #expect(texts(evs) == ["po:false", "n:true", "g:true"])
        let tools = evs.tools
        #expect(tools.map(\.status) == [.started, .completed, .failed])
        #expect(tools[1].kind == .exec && tools[1].output == "a.txt" && tools[1].input == #"{"command":"ls"}"#)
        #expect(tools[2].kind == .edit && tools[2].output == "denied" && tools[2].paths == ["/tmp/a.txt"])
        #expect(evs.permissions.first?.question == "Run ls" && evs.permissions.first?.kind == .exec)
        let usage = evs.compactMap { e -> Usage? in
            if case .usage(let u) = e.kind { return u }
            return nil
        }
        #expect(
            usage == [Usage(input: 100, output: 20, cacheRead: 30, cacheCreation: 5, model: "kimi-k3", costUSD: 0.002)])
        #expect(evs.results == [TurnResult(subtype: "success", sessionID: "ses_1")])
        #expect(steps.last?.endsTurn == true && !t.busy && t.sawResult)
    }

    @Test func v2Turn() throws {
        var d = v2()
        var t = OpenCodeTurn(busy: true)
        let steps = feed(&d, .v2, try Fixtures.lines("opencode2/turn.ndjson"), &t)
        let evs = steps.flatMap(\.events)
        try Fixtures.expectGolden("opencode2/turn.ndjson", evs)
        #expect(evs.count("init") == 0)
        #expect(texts(evs) == ["po:true", "ng:true", "\n(exit code 0):true"])
        let tools = evs.tools
        #expect(tools.map(\.name) == ["write", "write", "write", "write", "bash", "bash"])
        #expect(tools[0].kind == .edit && tools[0].status == .started && tools[0].input.isEmpty)
        #expect(tools[1].paths == ["/tmp/probe.txt"])
        #expect(tools[2].paths == ["/tmp/probe.txt"])
        #expect(tools[3].status == .completed && tools[3].output == "wrote")
        #expect(tools[5].status == .failed && tools[5].output == "exit 1")
        let usage = evs.compactMap { e -> Usage? in
            if case .usage(let u) = e.kind { return u }
            return nil
        }
        #expect(usage == [Usage(input: 12548, output: 3, cacheRead: 128, model: "kimi-k3", costUSD: 0.0019)])
        #expect(evs.permissions.first?.question == "write: /tmp/probe.txt")
        #expect(evs.results == [TurnResult(subtype: "success", sessionID: "ses_2")])
        #expect(steps.last?.endsTurn == true && !t.busy)
    }

    @Test func v2Interrupt() throws {
        var d = v2()
        var t = OpenCodeTurn(busy: true)
        let steps = feed(&d, .v2, try Fixtures.lines("opencode2/interrupt.ndjson"), &t)
        let evs = steps.flatMap(\.events)
        try Fixtures.expectGolden("opencode2/interrupt.ndjson", evs)
        #expect(evs.errors.isEmpty)
        #expect(
            evs.results == [
                TurnResult(subtype: "interrupted", isError: true, text: "turn interrupted", sessionID: "ses_2")
            ])
        #expect(steps.last?.endsTurn == true && !t.busy)
    }
}

// MARK: wire

@Suite("OpenCodeWireTests")
struct OpenCodeWireTests {
    @Test(arguments: [
        ("opencode v2.0.26", OpenCodeWire.v2), ("1.14.3", .v1), ("", .v1), ("opencode 3.1", .v2), ("dev build", .v1),
    ])
    func versionRouting(_ line: String, _ want: OpenCodeWire) {
        #expect(OpenCodeWire(versionLine: line) == want)
    }

    @Test func noVersionIsV1() { #expect(OpenCodeWire(versionLine: nil) == .v1) }

    @Test func ready() {
        #expect(OpenCodeWire.v1.ready(Data(#"{"healthy":true,"version":"1.14.3"}"#.utf8)))
        #expect(!OpenCodeWire.v1.ready(Data(#"{"version":"2.0.26","pid":1}"#.utf8)))
        #expect(OpenCodeWire.v2.ready(Data(#"{"version":"2.0.26","pid":1}"#.utf8)))
        #expect(!OpenCodeWire.v2.ready(Data("<html></html>".utf8)))
    }

    @Test func v1SessionIDs() {
        let lines = [
            #"{"type":"a","properties":{"sessionID":"s1"}}"#, #"{"type":"a","properties":{"sessionId":"s2"}}"#,
            #"{"type":"a","properties":{"info":{"sessionID":"s3"}}}"#,
            #"{"type":"a","properties":{"part":{"sessionID":"s4"}}}"#,
        ]
        #expect(lines.compactMap { OpenCodeWire.v1.frame(Data($0.utf8))?.sessionID } == ["s1", "s2", "s3", "s4"])
        for bad in [
            #"{"type":"a","properties":{}}"#, #"{"properties":{"sessionID":"s"}}"#, #"{"type":"a","properties":1}"#,
            "x",
        ] {
            #expect(OpenCodeWire.v1.frame(Data(bad.utf8)) == nil)
        }
    }

    @Test func v2SessionIDs() {
        #expect(OpenCodeWire.v2.frame(Data(#"{"type":"a","data":{"sessionID":"s1"}}"#.utf8))?.sessionID == "s1")
        let shell = #"{"type":"shell.x","data":{"info":{"metadata":{"sessionID":"s2"}}}}"#
        #expect(OpenCodeWire.v2.frame(Data(shell.utf8))?.sessionID == "s2")
        #expect(OpenCodeWire.v2.frame(Data(#"{"type":"a"}"#.utf8)) == nil)
    }

    @Test func decodeAndErrors() {
        #expect(OpenCodeWire.v2.decode(Data(#"{"data":{"id":"s1"}}"#.utf8))["id"] == "s1")
        #expect(OpenCodeWire.v2.decode(Data(#"{"id":"s1"}"#.utf8))["id"] == "s1")
        #expect(OpenCodeWire.v1.decode(Data(#"{"data":{"id":"x"},"id":"s1"}"#.utf8))["id"] == "s1")
        #expect(OpenCodeWire.v1.decode(Data()) == .null)
        #expect(OpenCodeWire.v1.errorText(Data(#"{"error":"bad"}"#.utf8), status: 400) == "bad")
        #expect(OpenCodeWire.v1.errorText(Data(#"{"data":{"message":"m"}}"#.utf8), status: 400) == "m")
        #expect(OpenCodeWire.v1.errorText(Data("x".utf8), status: 502) == "HTTP 502")
        #expect(OpenCodeWire.v2.errorText(Data(#"{"_tag":"NotFound"}"#.utf8), status: 404) == "NotFound")
        #expect(OpenCodeWire.v2.errorText(Data(#"{"message":"m","error":"e"}"#.utf8), status: 400) == "m")
    }

    @Test func fingerprint() {
        let bin = URL(fileURLWithPath: "/bin/opencode")
        func fp(
            _ env: [String: String], wire w: OpenCodeWire = .v1, args: [String] = [], ignore: [String] = []
        ) -> String {
            OpenCodeServerPool.fingerprint(w, binary: bin, environment: env, arguments: args, ignore: ignore)
        }
        let base = fp(["A": "1"])
        #expect(fp(["A": "1", "OPENCODE_SERVER_PASSWORD": "x", "OPENCODE_SERVER_USERNAME": "y"]) == base)
        #expect(fp(["A": "1", "RUN_ID": "7"], ignore: ["run_id"]) == base)
        #expect(fp(["A": "2", "B": "3"], ignore: ["*"]) == fp([:]))
        #expect(fp(["A": "1", "OPENCODE_CONFIG_CONTENT": "{}"]) != base)
        #expect(fp(["A": "1"], wire: .v2) != base)
        #expect(fp(["A": "1"], args: ["--log-level", "DEBUG"]) != base)
    }
}

// MARK: V1

@Suite("OpenCodeV1DialectTests")
struct OpenCodeV1DialectTests {
    @Test func promptBody() throws {
        let dir = try TempDir()
        let file = try dir.write("a.png", "png")
        var d = OpenCodeV1Dialect(
            sessionID: "ses_1", directory: "/w", model: "anthropic/claude-sonnet-4", effort: "high",
            instructions: " be brief ")
        let c = try d.prompt(
            Prompt(
                "hello",
                attachments: [
                    .data(Data("t".utf8), mime: "text/plain"), .file(file), .data(Data("i".utf8), mime: "image/png"),
                ]))
        #expect(c.path == "/session/ses_1/prompt_async" && c.directory == "/w" && c.method == "POST")
        let parts = try #require(c.body?["parts"]?.array)
        #expect(
            parts.map { $0["mime"]?.string ?? $0["type"].stringValue } == [
                "image/png", "image/png", "text/plain", "text",
            ])
        #expect(parts[0]["filename"]?.string == file.path && parts[0]["url"]?.string == file.absoluteString)
        #expect(parts[1]["url"]?.string == "data:image/png;base64,aQ==" && parts[1]["filename"] == nil)
        #expect(parts[3]["text"] == "hello")
        #expect(c.body?["model"] == ["providerID": "anthropic", "modelID": "claude-sonnet-4"])
        #expect(c.body?["variant"] == "high")
        #expect(c.body?["system"] == "be brief")
        _ = d.setModel("kimi-k3")
        let next = try d.prompt(Prompt(""))
        #expect(next.body?["system"] == nil && next.body?["variant"] == "high")
        #expect(next.body?["model"] == ["modelID": "kimi-k3"])
        #expect(next.body?["parts"]?.array?.last?["text"] == "")
    }

    @Test func attachmentErrorBeforeTurn() {
        var d = v1()
        #expect(throws: AgentBinderError.self) {
            _ = try d.prompt(Prompt("x", attachments: [.file(URL(fileURLWithPath: "/nonexistent/a.png"))]))
        }
    }

    @Test func calls() {
        let d = v1()
        #expect(d.interrupt == OpenCodeCall(path: "/session/ses_1/abort", directory: "/w", body: [:]))
        #expect(d.answer("per_1", .allow()).body == ["response": "once"])
        #expect(d.answer("per_1", .deny()).path == "/session/ses_1/permissions/per_1")
        #expect(d.answer("per_1", .deny()).body == ["response": "reject"])
    }

    @Test func userPartsAreDropped() {
        var d = v1()
        var t = OpenCodeTurn(busy: true)
        let evs = feed(
            &d, .v1,
            frames(
                #"{"type":"message.updated","properties":{"info":{"id":"msg_u","sessionID":"ses_1","role":"user"}}}"#,
                v1Part("p1", "echo", message: "msg_u"),
                // The first owner wins, so a later message id does not change it.
                v1Part("p1", "echo more", message: "msg_a"), v1Part("p2", "unknown role")), &t
        ).flatMap(\.events)
        #expect(texts(evs) == ["unknown role:false"])
    }

    // Fixed on purpose: a replacement lowers the stored length, so a later growth gives a delta from it.
    @Test func replacementLowersLength() {
        var d = v1()
        var t = OpenCodeTurn(busy: true)
        let evs = feed(&d, .v1, frames(v1Part("p", "a long draft"), v1Part("p", "short"), v1Part("p", "shorter")), &t)
            .flatMap(\.events)
        #expect(texts(evs) == ["a long draft:false", "short:false", "er:true"])
    }

    @Test func promptResetsParts() throws {
        var d = v1()
        var t = OpenCodeTurn(busy: true)
        _ = feed(&d, .v1, frames(v1Part("p", "abc")), &t)
        _ = try d.prompt(Prompt("again"))
        let evs = feed(&d, .v1, frames(v1Part("p", "abcd")), &t).flatMap(\.events)
        #expect(texts(evs) == ["abcd:false"])
    }

    @Test func errorThenIdleGivesAnErrorResult() {
        var d = v1()
        var t = OpenCodeTurn(busy: true)
        let steps = feed(
            &d, .v1,
            frames(
                #"{"type":"session.error","properties":{"sessionID":"ses_1","error":{"name":"APIError","data":{"message":"overloaded_error: try later"}}}}"#,
                #"{"type":"session.idle","properties":{"sessionID":"ses_1"}}"#), &t)
        let err = steps[0].events.errors.first
        #expect(err?.message == "overloaded_error: try later" && err?.code.hasPrefix("opencode.") == true)
        #expect(!steps[0].endsTurn && t.sawResult)
        let r = steps[1].events.results.first
        #expect(r?.isError == true && r?.subtype == "error_during_execution" && r?.code?.hasPrefix("opencode.") == true)
        #expect(r?.text == "overloaded_error: try later")
    }

    @Test func emptySessionErrorHasDefaultText() {
        var d = v1()
        var t = OpenCodeTurn(busy: true)
        let steps = feed(&d, .v1, frames(#"{"type":"session.error","properties":{"sessionID":"ses_1"}}"#), &t)
        #expect(steps[0].events.errors.first?.message == "opencode session error")
    }

    @Test func idleWithoutTurnIsQuiet() {
        var d = v1()
        var t = OpenCodeTurn()
        let steps = feed(&d, .v1, frames(#"{"type":"session.idle","properties":{"sessionID":"ses_1"}}"#), &t)
        #expect(steps[0].events.isEmpty && !steps[0].endsTurn)
    }

    @Test func deletedAndMessageError() {
        var d = v1()
        var t = OpenCodeTurn(busy: true)
        let steps = feed(
            &d, .v1,
            frames(
                #"{"type":"message.updated","properties":{"info":{"id":"m","sessionID":"ses_1","role":"assistant","error":{"name":"ProviderAuthError","data":{"message":"invalid api key"}}}}}"#,
                #"{"type":"session.deleted","properties":{"sessionID":"ses_1"}}"#), &t)
        #expect(steps[0].events.errors.first?.message == "invalid api key" && t.lastError == "invalid api key")
        #expect(steps[1].deleted && steps[1].events.isEmpty)
    }

    @Test func permissionQuestionFallback() {
        var d = v1()
        var t = OpenCodeTurn(busy: true)
        let evs = feed(
            &d, .v1,
            frames(
                #"{"type":"permission.asked","properties":{"id":"p1","sessionID":"ses_1","type":"edit","message":"Edit a.txt"}}"#,
                #"{"type":"permission.v2.asked","properties":{"id":"p2","sessionID":"ses_1","type":"webfetch"}}"#), &t
        ).flatMap(\.events)
        #expect(evs.permissions.map(\.question) == ["Edit a.txt", "OpenCode requests permission"])
        #expect(evs.permissions.first?.kind == .edit)
    }

    @Test func usageNeedsAFinalMessage() {
        let info = JSONValue.parse(#"{"id":"m","tokens":{"input":5,"output":1,"cache":7}}"#)!
        #expect(OpenCodeV1Dialect.usage(info) == Usage(input: 5, output: 1, cacheRead: 7))
        #expect(OpenCodeV1Dialect.usage(JSONValue.parse(#"{"tokens":{"input":0}}"#)!) == nil)
        var d = v1()
        var t = OpenCodeTurn(busy: true)
        let evs = feed(
            &d, .v1,
            frames(
                #"{"type":"message.updated","properties":{"info":{"id":"m","sessionID":"ses_1","role":"assistant","tokens":{"input":5}}}}"#
            ),
            &t
        ).flatMap(\.events)
        #expect(evs.isEmpty)
    }

    @Test func toolStatuses() {
        func status(_ s: String) -> ToolStatus {
            OpenCodeV1Dialect.tool("t", JSONValue.parse(#"{"tool":"read","state":{"status":"\#(s)"}}"#)!).status
        }
        #expect(status("pending") == .started && status("") == .started && status("odd") == .started)
        let failed = OpenCodeV1Dialect.tool(
            "t", JSONValue.parse(#"{"tool":"read","state":{"status":"error","error":{"message":"gone"}}}"#)!)
        #expect(failed.status == .failed && failed.output == "gone" && failed.kind == .read)
    }

    @Test func modelRef() {
        #expect(OpenCodeV1Dialect.modelRef("a/b/c") == ["providerID": "a", "modelID": "b/c"])
        #expect(OpenCodeV1Dialect.modelRef("m") == ["modelID": "m"])
    }
}

// MARK: V2

@Suite("OpenCodeV2DialectTests")
struct OpenCodeV2DialectTests {
    @Test func textEndedReplaces() {
        var d = v2()
        var t = OpenCodeTurn(busy: true)
        let key = #""assistantMessageID":"m","ordinal":1"#
        let evs = feed(
            &d, .v2,
            frames(
                v2Event("session.text.delta", key + #","delta":"a long draft""#),
                v2Event("session.text.ended", key + #","text":"short""#),
                v2Event("session.text.ended", #""assistantMessageID":"m","ordinal":2,"text":"fresh""#),
                v2Event("session.text.delta", key + #","delta":"""#)), &t
        ).flatMap(\.events)
        #expect(texts(evs) == ["a long draft:true", "short:false", "fresh:false"])
    }

    @Test func failureIsClassified() {
        var d = v2()
        var t = OpenCodeTurn(busy: true)
        let steps = feed(
            &d, .v2,
            frames(
                v2Event("session.step.failed", #""error":{"type":"provider.auth","message":"bad token","status":401}"#),
                v2Event("session.execution.failed", #""error":{"message":"HTTP 429 too many requests","status":429}"#)
            ), &t)
        let first = steps[0].events.errors.first
        #expect(first?.code == "opencode2.invalid_credentials" && first?.endReason == .auth)
        #expect(!steps[0].endsTurn)
        let last = steps[1].events
        #expect(last.map(\.kind.name) == ["error", "result"] && steps[1].endsTurn && !t.busy)
        #expect(last.results.first?.code?.hasPrefix("opencode2.") == true && last.results.first?.isError == true)
        #expect(last.results.first?.endReason == .limit)
    }

    @Test(arguments: [
        ("provider.rate-limit", "opencode2.rate_limited", EndReason.limit),
        ("provider.quota", "opencode2.credits_exhausted", .limit),
        ("provider.internal", "opencode2.capacity", .overloaded),
        ("provider.transport", "opencode2.capacity", .overloaded),
        ("provider.invalid-output", "opencode2.wire_drift", .protocol),
    ])
    func typedClasses(_ type: String, _ code: String, _ reason: EndReason) {
        let w = OpenCodeV2Dialect.classified("x", status: 0, type: type)
        #expect(w.code == code && w.endReason == reason)
    }

    @Test func succeededAfterErrorFails() {
        var d = v2()
        var t = OpenCodeTurn(busy: true)
        let steps = feed(
            &d, .v2,
            frames(
                v2Event("session.step.failed", #""error":"plain""#), v2Event("session.execution.succeeded", #""x":1"#)),
            &t)
        #expect(steps[0].events.errors.first?.message == "plain")
        #expect(steps[1].events.results.first?.isError == true && steps[1].events.results.first?.text == "plain")
    }

    @Test func emptyFailureHasDefaultText() {
        var d = v2()
        var t = OpenCodeTurn(busy: true)
        let steps = feed(&d, .v2, frames(v2Event("session.step.failed", #""x":1"#)), &t)
        #expect(steps[0].events.errors.first?.message == "opencode2 session error")
    }

    @Test func toolWithoutIDIsDropped() {
        var d = v2()
        var t = OpenCodeTurn(busy: true)
        let evs = feed(
            &d, .v2,
            frames(
                v2Event("session.tool.called", #""input":"raw""#),
                v2Event("session.tool.called", #""id":"c","name":"grep","input":"raw text""#),
                v2Event("session.tool.success", #""id":"c","output":"found""#),
                v2Event("permission.asked", #""action":"x""#)
            ), &t
        ).flatMap(\.events)
        #expect(evs.tools.map(\.input) == ["raw text", ""] && evs.tools.last?.output == "found")
        #expect(evs.tools.first?.kind == .search && evs.permissions.isEmpty)
    }

    @Test func permissionQuestion() {
        var d = v2()
        var t = OpenCodeTurn(busy: true)
        let evs = feed(
            &d, .v2,
            frames(
                v2Event("permission.asked", #""id":"p1","action":"write","message":"Write it?""#),
                v2Event("permission.asked", #""id":"p2""#)), &t
        ).flatMap(\.events)
        #expect(evs.permissions.map(\.question) == ["Write it?", "OpenCode requests permission"])
        #expect(evs.permissions.first?.kind == .edit && evs.permissions.first?.tool == "write")
    }

    @Test func promptBody() throws {
        let dir = try TempDir()
        let note = try dir.write("note.txt", "n")
        var d = v2()
        let c = try d.prompt(Prompt("hello", attachments: [.file(note), .data(Data("i".utf8), mime: "image/png")]))
        #expect(c.path == "/session/ses_2/prompt" && c.directory == nil)
        #expect(c.body?["text"] == "hello" && c.body?.at("location", "directory") == "/w")
        #expect(
            c.body?["files"]
                == [["uri": "data:image/png;base64,aQ=="], ["uri": .string(note.absoluteString), "name": "note.txt"]])
        #expect(try d.prompt(Prompt("x")).body?["files"] == nil)
    }

    @Test func calls() {
        var d = OpenCodeV2Dialect(sessionID: "s", directory: "/w", variant: "high")
        #expect(d.interrupt == OpenCodeCall(path: "/session/s/interrupt"))
        #expect(
            d.answer("p", .allow())
                == OpenCodeCall(path: "/session/s/permission/p/reply", body: ["decision": "once", "reply": "once"]))
        #expect(d.answer("p", .deny()).body == ["decision": "reject", "reply": "reject"])
        #expect(
            d.setModel("opencode-go/kimi-k3")?.body == [
                "model": ["providerID": "opencode-go", "id": "kimi-k3", "variant": "high"]
            ])
        #expect(d.setModel(" ") == nil)
        let puts = OpenCodeV2Dialect.instructionsCalls("s", " be brief ")
        #expect(
            puts.map(\.path) == [
                "/experimental/session/s/instructions/entries/agentbinder.instructions",
                "/session/s/instructions/entries/agentbinder.instructions",
            ])
        #expect(puts.allSatisfy { $0.method == "PUT" && $0.body == ["value": "be brief"] })
        #expect(OpenCodeV2Dialect.instructionsCalls("s", "  ").isEmpty)
    }

    @Test func modelRefTable() {
        #expect(
            OpenCodeV2Dialect.modelRef("opencode-go/deepseek-v4.1-flash", variant: "") == [
                "providerID": "opencode-go", "id": "deepseek-v4.1-flash",
            ])
        #expect(
            OpenCodeV2Dialect.modelRef("anthropic/claude-sonnet-4", variant: "high")
                == ["providerID": "anthropic", "id": "claude-sonnet-4", "variant": "high"])
        #expect(OpenCodeV2Dialect.modelRef("deepseek-v4.1-flash", variant: nil) == ["id": "deepseek-v4.1-flash"])
        #expect(
            OpenCodeV2Dialect.modelRef("", variant: "high") == nil
                && OpenCodeV2Dialect.modelRef(nil, variant: nil) == nil)
    }

    @Test(arguments: [
        (#"{"model":{"providerID":"opencode-go","model":"kimi-k3"}}"#, "opencode-go/kimi-k3" as String?),
        (#"{"model":" anthropic/claude-sonnet-4 "}"#, "anthropic/claude-sonnet-4"),
        (#"{"model":{"model":"bare"}}"#, "bare"),
        (#"{"theme":"x"}"#, nil), (#"{"model":{"providerID":"p"}}"#, nil), ("{bad", nil),
    ])
    func operatorModel(_ config: String, _ want: String?) throws {
        let dir = try TempDir()
        try dir.write("opencode/opencode.json", config)
        #expect(OpenCodeV2Dialect.operatorModel(environment: ["XDG_CONFIG_HOME": dir.path]) == want)
    }

    @Test func operatorModelFallsBackToHome() throws {
        let home = try TempDir()
        try home.write(".config/opencode/opencode.json", #"{"model":"p/m"}"#)
        #expect(OpenCodeV2Dialect.operatorModel(environment: ["HOME": home.path]) == "p/m")
        #expect(OpenCodeV2Dialect.operatorModel(environment: ["HOME": home.path + "/none"]) == nil)
    }

    @Test func numberText() {
        #expect(OpenCodeV2Dialect.numberText(.int(3)) == "3")
        #expect(OpenCodeV2Dialect.numberText(.double(2)) == "2")
        #expect(OpenCodeV2Dialect.numberText(.double(1.5)) == "1.5")
        #expect(OpenCodeV2Dialect.numberText(.string("x")) == "x")
        #expect(OpenCodeV2Dialect.numberText(nil) == "")
    }
}

// MARK: models

@Suite("OpenCodeModelTests")
struct OpenCodeModelTests {
    @Test func v1List() throws {
        let list = OpenCodeDriver.v1Models(
            providers: try Fixtures.json("models/opencode_providers.json"),
            config: JSONValue.parse(#"{"model":"opencode-go/deepseek-v4.1-flash"}"#)
        ).sorted { $0.id < $1.id }
        #expect(list.map(\.id) == ["opencode-go/deepseek-v4.1-flash", "opencode-go/kimi-k3"])
        #expect(list.map(\.isDefault) == [true, false])
        #expect(list.map(\.description) == ["OpenCode Go · 1M context", "OpenCode Go · 256K context"])
        #expect(list[1].name == "Kimi K3")
        let objectDefault = OpenCodeDriver.v1Models(
            providers: try Fixtures.json("models/opencode_providers.json"),
            config: JSONValue.parse(#"{"model":{"providerID":"opencode-go","model":"kimi-k3"}}"#))
        #expect(objectDefault.filter(\.isDefault).map(\.id) == ["opencode-go/kimi-k3"])
    }

    @Test func v2List() throws {
        let raw = try Fixtures.json("models/opencode2_models.json")
        let list = OpenCodeDriver.v2Models(
            list: OpenCodeWire.v2.decode(raw.jsonData),
            default: JSONValue.parse(#"{"modelID":"kimi-k3","providerID":"opencode-go"}"#))
        #expect(list.map(\.id) == ["opencode-go/kimi-k3", "opencode-go/deepseek-v4.1-flash"])
        #expect(list.map(\.isDefault) == [true, false])
        #expect(list.map(\.description) == ["256K context", "1M context"])
        #expect(OpenCodeDriver.v2Models(list: [["id": "bare"]], default: nil).map(\.id) == ["bare"])
    }

    @Test func cliLines() {
        let list = OpenCodeDriver.cliModels(
            "opencode-go/kimi-k3\n  anthropic/claude-sonnet-4 \nnot a model\n/x\ny/\nplain\n")
        #expect(list.map(\.id) == ["opencode-go/kimi-k3", "anthropic/claude-sonnet-4"])
    }
}
