import Foundation
import Testing

@testable import AgentBinder
@testable import AgentBinderNative

@Suite("NativeSessionTests")
struct NativeSessionTests {
    @Test func textTurn() async throws {
        let m = ScriptedModel([.parts([.textDelta("hello"), .textDelta(" world"), .stop])])
        let rt = await runtime(config(m))
        let s = try await rt.start(request())
        #expect(s.harness == .native && s.id == "s1" && s.pid == nil)
        let sink = Sink(s)
        try await s.prompt(Prompt("hi"))
        try await sink.waitResults(1)
        try await eventually { sink.names.last == "status" }
        #expect(sink.names == ["init", "status", "assistant", "assistant", "assistant", "usage", "result", "status"])
        #expect(sink.text == ["hello world"])
        let r = sink.results[0]
        #expect(r.subtype == "success" && !r.isError && r.usage.input == 10 && r.sessionID == "s1")
        #expect(sink.events.dropFirst().allSatisfy { $0.turn == 1 && $0.sessionID == "s1" })
        #expect(m.requests.value[0].messages == [.user("hi")] && m.requests.value[0].tools.isEmpty)
        await rt.close()
        await sink.waitEnd()
        #expect(sink.names.last == "exit")
    }

    @Test func imageAttachment() async throws {
        let dir = try Scratch()
        let png = try dir.write("a.PNG", "\u{1}\u{2}\u{3}")
        let store = MemoryStore()
        let m = ScriptedModel([.parts(StreamPart.text("ok"))])
        let rt = await runtime(config(m) { $0.store = store })
        let s = try await rt.start(request())
        let sink = Sink(s)
        await #expect(throws: AgentBinderError.unsupported(#"native takes image attachments only, got "text/plain""#)) {
            try await s.prompt(Prompt("x", attachments: [.data(Data("t".utf8), mime: "text/plain")]))
        }
        await #expect(throws: AgentBinderError.invalidRequest("native: attachment with no data")) {
            try await s.prompt(Prompt("x", attachments: [.data(Data(), mime: "image/png")]))
        }
        try await s.prompt(Prompt("look", attachments: [.file(png)]))
        try await sink.waitResults(1)
        let want = Message(
            role: .user, parts: [.file(FilePart(mediaType: "image/png", data: Data([1, 2, 3]))), .text("look")])
        #expect(m.requests.value[0].messages == [want])
        #expect(try await store.load("s1").first == want)
        await rt.close()
    }

    @Test func oneToolCall() async throws {
        let m = ScriptedModel([
            .parts(StreamPart.calls(.call("call_1", "echo", #"{"text":"hi"}"#))), .parts(StreamPart.text("done")),
        ])
        let rt = await runtime(config(m) { $0.toolSets = [StaticToolSet("t", [EchoTool()])] })
        let s = try await rt.start(request())
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await sink.waitResults(1)
        #expect(sink.tools.map(\.status) == [.started, .completed])
        #expect(
            sink.tools[0].kind == .other && sink.tools[0].input == #"{"text":"hi"}"#
                && sink.tools[1].output == "echo: hi")
        #expect(sink.permissions.isEmpty && m.calls == 2)
        let second = m.requests.value[1].messages
        #expect(second.count == 3 && second[1].parts == [.toolCall(.call("call_1", "echo", #"{"text":"hi"}"#))])
        #expect(
            second[2]
                == Message(
                    role: .tool,
                    parts: [.toolResult(ToolResult(callID: "call_1", name: "echo", content: [.text("echo: hi")]))]))
        #expect(m.requests.value[0].tools.map(\.name) == ["echo"])
        await rt.close()
    }

    @Test func toolErrors() async throws {
        struct Boom: Error, CustomStringConvertible { var description = "boom" }
        let failing = FuncTool(ToolSpec(name: "fail", annotations: ToolAnnotations(readOnly: true))) {
            (_: [String: String]) -> String in
            throw Boom()
        }
        struct Broken: Tool {
            var spec = ToolSpec(name: "broken", annotations: ToolAnnotations(readOnly: true))
            func call(_: Data?) async throws -> ToolResult { throw Boom() }
        }
        let m = ScriptedModel([
            .parts(
                StreamPart.calls(.call("a", "fail"), .call("b", "broken"), .call("c", "nope"), .call("d", "fail", "[1"))
            ),
            .parts(StreamPart.text("ok")),
        ])
        let rt = await runtime(config(m) { $0.toolSets = [StaticToolSet("t", [failing, Broken()])] })
        let s = try await rt.start(request())
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await sink.waitResults(1)
        let ends = sink.tools.filter { $0.status != .started }
        #expect(ends.map(\.status) == [.failed, .failed, .failed, .failed])
        #expect(ends[0].output == "boom" && ends[1].output == "tool infrastructure failure: boom")
        #expect(ends[2].output == #"unknown tool "nope""# && ends[2].kind == .mcp)
        #expect(ends[3].output.hasPrefix("invalid input:"))
        #expect(sink.results[0].subtype == "success" && m.calls == 2)
        await rt.close()
    }

    @Test func parallelCallsAndMaxTurns() async throws {
        let m = ScriptedModel([
            .parts(StreamPart.calls(.call("1", "echo", #"{"text":"a"}"#), .call("2", "echo", #"{"text":"b"}"#))),
            .parts(StreamPart.calls(.call("3", "echo", #"{"text":"c"}"#))),
        ])
        let rt = await runtime(
            config(m) {
                $0.toolSets = [StaticToolSet("t", [EchoTool()])]
                $0.maxTurns = 2
            })
        let s = try await rt.start(request())
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await sink.waitResults(1)
        #expect(sink.tools.filter { $0.status == .completed }.map(\.output) == ["echo: a", "echo: b", "echo: c"])
        #expect(m.calls == 2 && sink.results[0].subtype == "error_max_turns" && sink.results[0].isError)
        await rt.close()
    }

    @Test func interruptMidStream() async throws {
        let m = ScriptedModel([.hang([.textDelta("par")]), .parts(StreamPart.text("next"))])
        let rt = await runtime(config(m))
        let s = try await rt.start(request())
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await eventually { sink.names.contains("assistant") }
        await #expect(throws: AgentBinderError.turnActive) { try await s.prompt(Prompt("again")) }
        try await s.interrupt()
        try await sink.waitResults(1)
        #expect(sink.results[0].subtype == "interrupted" && sink.results[0].isError && s.lastError == nil)
        try await eventually { (try? await s.send(Prompt("again"))) == .prompted }
        try await sink.waitResults(2)
        #expect(sink.results[1].subtype == "success")
        // The partial answer is not in the history.
        #expect(m.requests.value[1].messages == [.user("go"), .user("again")])
        try await s.interrupt()
        await rt.close()
    }

    // Fixed on purpose: a cancel between tool calls gives each open call a result.
    @Test func cancelDuringToolsAddsResults() async throws {
        let gate = Locked(false)
        let slow = FuncTool(ToolSpec(name: "slow", annotations: ToolAnnotations(readOnly: true))) {
            (_: [String: String]) -> String in
            gate.withLock { $0 = true }
            try? await Task.sleep(for: .seconds(5))
            return "late"
        }
        let store = MemoryStore()
        let m = ScriptedModel([
            .parts(StreamPart.calls(.call("1", "slow"), .call("2", "slow"))), .parts(StreamPart.text("ok")),
        ])
        let rt = await runtime(
            config(m) {
                $0.toolSets = [StaticToolSet("t", [slow])]
                $0.store = store
            })
        let s = try await rt.start(request())
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await eventually { gate.value }
        try await s.interrupt()
        try await sink.waitResults(1)
        let log = try await store.load("s1")
        let results = log.filter { $0.role == .tool }.flatMap(\.parts).compactMap { p -> ToolResult? in
            if case .toolResult(let r) = p { return r }
            return nil
        }
        // The first tool ignores the cancel and keeps its result.
        #expect(results.map(\.callID) == ["1", "2"] && results.map(\.isError) == [false, true])
        #expect(results[1].content == [.text("cancelled")])
        #expect(sink.results[0].subtype == "interrupted")
        await rt.close()
    }

    @Test func approvalDeniedAndAllowed() async throws {
        let ran = Locked(0)
        let edit = FuncTool(ToolSpec(name: "edit_it", annotations: ToolAnnotations(kind: .edit))) {
            (i: [String: String]) -> String in
            ran.withLock { $0 += 1 }
            return "edited \(i["path"] ?? "")"
        }
        let m = ScriptedModel([
            .parts(StreamPart.calls(.call("t1", "edit_it", #"{"path":"a"}"#))),
            .parts(StreamPart.calls(.call("t2", "edit_it", #"{"path":"b"}"#))), .parts(StreamPart.text("ok")),
        ])
        let rt = await runtime(config(m) { $0.toolSets = [StaticToolSet("t", [edit])] })
        let s = try await rt.start(request())
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await eventually { sink.permissions.count == 1 }
        let p = sink.permissions[0]
        #expect(p.id == "perm-1" && p.tool == "edit_it" && p.kind == .edit && p.question == "Allow edit_it?")
        #expect(p.input == #"{"path":"a"}"# && p.toolUseID == "t1")
        #expect(sink.events.last.map { if case .status(.waiting, _) = $0.kind { true } else { false } } == true)
        try await s.answer("perm-1", .deny("no writes"))
        await #expect(throws: AgentBinderError.invalidRequest("native: unknown or answered permission")) {
            try await s.answer("perm-1", .allow())
        }
        try await eventually { sink.permissions.count == 2 }
        try await s.answer("perm-2", .allow(updatedInput: Data(#"{"path":"c"}"#.utf8)))
        try await sink.waitResults(1)
        let ends = sink.tools.filter { $0.status != .started }
        #expect(ends.map(\.output) == ["denied by the operator: no writes", "edited c"] && ran.value == 1)
        await rt.close()
    }

    @Test func policyAndCustomApprover() async throws {
        struct No: Approver {
            func approve(_: ApprovalRequest) async throws -> Decision { .deny() }
        }
        let m = ScriptedModel([
            .parts(StreamPart.calls(.call("t", "echo", #"{"text":"x"}"#))), .parts(StreamPart.text("ok")),
        ])
        let rt = await runtime(
            config(m) {
                $0.toolSets = [StaticToolSet("t", [EchoTool(readOnly: false)])]
                $0.approver = No()
            })
        let s = try await rt.start(request())
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await sink.waitResults(1)
        #expect(sink.permissions.isEmpty && sink.tools.last?.output == "denied by the operator")

        let m2 = ScriptedModel([
            .parts(StreamPart.calls(.call("t", "echo", #"{"text":"x"}"#))), .parts(StreamPart.text("ok")),
        ])
        let rt2 = await runtime(config(m2) { $0.toolSets = [StaticToolSet("t", [EchoTool(kind: .exec)])] })
        var r = request()
        r.permissions = PermissionPolicy(allowTools: ["ec*"])
        let s2 = try await rt2.start(r)
        let sink2 = Sink(s2)
        try await s2.prompt(Prompt("go"))
        try await sink2.waitResults(1)
        #expect(sink2.permissions.isEmpty && sink2.tools.last?.output == "echo: x")
        #expect(
            try await PolicyApprover(policy: PermissionPolicy()).approve(
                ApprovalRequest(callID: "c", spec: EchoTool().spec, input: nil)) == .deny("no approver configured"))
        await rt.close()
        await rt2.close()
    }

    @Test func closeEndsAWaitingPermission() async throws {
        let m = ScriptedModel([.parts(StreamPart.calls(.call("t", "echo", #"{"text":"x"}"#)))])
        let rt = await runtime(config(m) { $0.toolSets = [StaticToolSet("t", [EchoTool(kind: .exec)])] })
        let s = try await rt.start(request())
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await eventually { sink.permissions.count == 1 }
        _ = try await s.send(Prompt("later"))
        await s.close()
        await s.close()
        await sink.waitEnd()
        #expect(sink.results.first?.subtype == "interrupted")
        #expect(sink.errors.first { $0.code == "held_prompt_dropped" }?.text == "later")
        #expect(sink.names.last == "exit")
        await #expect(throws: AgentBinderError.sessionClosed) { try await s.prompt(Prompt("x")) }
        await #expect(throws: AgentBinderError.sessionClosed) { _ = try await s.send(Prompt("x")) }
        await rt.close()
    }

    @Test func modelErrorsFailTheTurn() async throws {
        let m = ScriptedModel([
            .fail(AgentBinderError.vendor(code: 429, message: "rate_limit_error: slow down")),
            .parts([.textDelta("x")]),
            .parts([.finish(Finish(reason: .refusal))]),
            .parts([.finish(Finish(reason: .contentFilter))]),
            .parts([.finish(Finish(reason: .length))]),
        ])
        let calls = Locked<[String]>([])
        let rt = await runtime(
            config(m) {
                $0.afterCall = { id, u in calls.withLock { $0.append("\(id):\(u.input)") } }
            })
        let s = try await rt.start(request())
        let sink = Sink(s)
        for i in 1...5 {
            try await s.prompt(Prompt("p\(i)"))
            try await sink.waitResults(i)
        }
        let r = sink.results
        #expect(r.map(\.subtype) == ["error", "error", "error", "error", "success"])
        #expect(r[0].endReason == .limit)
        #expect(sink.errors.map(\.code) == ["vendor_error", "stream_incomplete", "model_refused", "content_filtered"])
        #expect(sink.errors[1].message == "native: model stream ended without a finish part")
        #expect(s.lastError?.code == "vendor_error")
        #expect(calls.value == ["s1:0"])
        await rt.close()
    }

    @Test func beforeCallFails() async throws {
        let m = ScriptedModel([.parts(StreamPart.text("x"))])
        let rt = await runtime(
            config(m) {
                $0.beforeCall = { _ in throw NativeError("budget", "budget spent") }
            })
        let s = try await rt.start(request())
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await sink.waitResults(1)
        #expect(sink.errors.first == WireError(message: "budget spent", code: "budget", endReason: .failed))
        #expect(m.calls == 0)
        await rt.close()
    }

    // Fixed on purpose: the reasoning keeps its signature in the history, and an empty answer adds no message.
    @Test func reasoningSignatureIsKept() async throws {
        let m = ScriptedModel([
            .parts([
                .reasoningDelta("plan"), .reasoningDelta("ning"), .reasoningSignature("sigA"), .reasoningDelta("more"),
                .textDelta("Answer"), .toolCallDone(.call("t", "echo", #"{"text":"x"}"#)),
                .finish(Finish(reason: .toolCalls)),
            ]),
            .parts([.finish(Finish(reason: .stop))]),
            .parts(StreamPart.text("ok")),
        ])
        let rt = await runtime(config(m) { $0.toolSets = [StaticToolSet("t", [EchoTool()])] })
        var r = request()
        r.effort = .high
        let s = try await rt.start(r)
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await sink.waitResults(1)
        #expect(
            sink.events.compactMap { if case .thought(let t, true) = $0.kind { t } else { nil } } == [
                "plan", "ning", "more",
            ])
        let second = m.requests.value[1]
        #expect(second.effort == "high")
        #expect(
            second.messages[1].parts == [
                .reasoning(ReasoningPart(text: "planning", signature: "sigA")), .reasoning(ReasoningPart(text: "more")),
                .text("Answer"), .toolCall(.call("t", "echo", #"{"text":"x"}"#)),
            ])
        try await s.prompt(Prompt("next"))
        try await sink.waitResults(2)
        #expect(m.requests.value[2].messages.count == 4)
        await rt.close()
    }

    // Fixed on purpose: the history keeps the arrival order of reasoning and text.
    @Test func partsKeepArrivalOrder() async throws {
        let m = ScriptedModel([
            .parts([
                .reasoningDelta("a"), .reasoningSignature("s1"), .textDelta("x"), .reasoningDelta("b"),
                .reasoningSignature("s2"), .textDelta("y"), .stop,
            ]),
            .parts(StreamPart.text("ok")),
        ])
        let rt = await runtime(config(m))
        let s = try await rt.start(request())
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await sink.waitResults(1)
        try await s.prompt(Prompt("next"))
        try await sink.waitResults(2)
        #expect(
            m.requests.value[1].messages[1].parts == [
                .reasoning(ReasoningPart(text: "a", signature: "s1")), .text("x"),
                .reasoning(ReasoningPart(text: "b", signature: "s2")), .text("y"),
            ])
        await rt.close()
    }

    @Test func fallbackDropsTheDeclinedAttempt() async throws {
        let m = ScriptedModel([
            .parts([
                .reasoningDelta("r"), .reasoningSignature("s"), .textDelta("Hi "),
                .toolCallDone(.call("t", "echo", #"{"text":"x"}"#)), .fallback(model: "claude-opus-5-5"),
                .textDelta("ok"), .stop,
            ]),
            .parts(StreamPart.text("done")),
        ])
        let rt = await runtime(config(m) { $0.toolSets = [StaticToolSet("t", [EchoTool()])] })
        let s = try await rt.start(request())
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await sink.waitResults(1)
        #expect(sink.tools.isEmpty && m.calls == 1)
        try await s.prompt(Prompt("next"))
        try await sink.waitResults(2)
        #expect(m.requests.value[1].messages[1].parts == [.text("Hi "), .text("ok")])
        await rt.close()
    }

    @Test func resumeFromStore() async throws {
        let dir = try Scratch()
        let store = FileStore(directory: dir.url)
        try await store.append("old", [.user("earlier"), Message(role: .assistant, parts: [.text("reply")])])
        let m = ScriptedModel([.parts(StreamPart.text("ok"))])
        let rt = await runtime(config(m) { $0.store = store })
        let s = try await rt.resume(request(id: "old"))
        let sink = Sink(s)
        try await s.prompt(Prompt("now"))
        try await sink.waitResults(1)
        #expect(m.requests.value[0].messages.map(\.parts) == [[.text("earlier")], [.text("reply")], [.text("now")]])
        #expect(sink.events.first?.turn == 0 && sink.results[0].sessionID == "old")
        #expect(try await store.load("old").count == 4)
        await #expect(throws: AgentBinderError.invalidRequest("native session needs a session id")) {
            _ = try await rt.resume(request(id: nil))
        }
        let fresh = try await rt.start(request(id: nil))
        #expect(fresh.id?.count == 36)
        await rt.close()
    }

    @Test func compactionFolds() async throws {
        let store = MemoryStore()
        let history = (0..<10).map { Message.user("message \($0) " + String(repeating: "x", count: 40)) }
        try await store.replace("s1", history)
        let m = ScriptedModel([.parts(StreamPart.text("short")), .parts(StreamPart.text("ok"))])
        let rt = await runtime(
            config(m) {
                $0.store = store
                $0.compactor = SummaryCompactor(keepLast: 2)
                $0.contextTokens = 100
            })
        let s = try await rt.resume(request())
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await sink.waitResults(1)
        #expect(m.calls == 2 && m.requests.value[0].tools.isEmpty && m.requests.value[0].system.isEmpty)
        let call = m.requests.value[1].messages
        #expect(call.count == 3 && call[0] == .user("Summary of the earlier conversation:\nshort"))
        #expect(try await store.load("s1").count == 4)
        #expect(sink.names.filter { $0 == "usage" }.count == 1)
        await rt.close()
    }

    @Test func oneShotClosesAfterTheTurn() async throws {
        let m = ScriptedModel([.parts(StreamPart.text("done"))])
        let rt = await runtime(config(m))
        var r = request()
        r.oneShot = OneShot(prompt: "do it")
        let s = try await rt.start(r)
        let sink = Sink(s)
        await sink.waitEnd()
        #expect(sink.results.count == 1 && sink.names.last == "exit")
        await rt.close()
    }

    @Test func consumerCancelCloses() async throws {
        let closed = Locked(false)
        struct Set_: ToolSet {
            let closed: Locked<Bool>
            var name = "x"
            func tools() async throws -> [any Tool] { [] }
            func close() async { closed.withLock { $0 = true } }
        }
        let m = ScriptedModel([])
        let rt = await runtime(config(m) { c in c.toolSetFactories = [{ Set_(closed: closed) }] })
        let s = try await rt.start(request())
        let t = Task { for await _ in s.events {} }
        try await Task.sleep(for: .milliseconds(30))
        t.cancel()
        try await eventually { closed.value }
        await rt.close()
    }
}
