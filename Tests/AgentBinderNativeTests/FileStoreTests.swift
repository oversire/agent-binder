import Foundation
import Testing

@testable import AgentBinder
@testable import AgentBinderNative

@Suite("FileStoreTests")
struct FileStoreTests {
    static let all: [Message] = [
        .user("hi"),
        Message(
            role: .user,
            parts: [
                .file(FilePart(mediaType: "image/png", data: Data([1, 2]))),
                .file(FilePart(mediaType: "", url: "https://x/y")),
            ]),
        Message(
            role: .assistant,
            parts: [
                .reasoning(ReasoningPart(text: "think", signature: "sig")), .reasoning(ReasoningPart(text: "plain")),
                .text("ok"), .toolCall(.call("c1", "echo", #"{"text":"x"}"#)),
                .toolCall(ToolCall(id: "c2", name: "none", input: nil)),
            ]),
        Message(
            role: .tool,
            parts: [.toolResult(ToolResult(callID: "c1", name: "echo", content: [.text("echo: x")], isError: true))]),
    ]

    @Test func roundTrip() async throws {
        let dir = try Scratch()
        let s = FileStore(directory: dir.url.appendingPathComponent("deep"))
        await #expect(throws: NativeError.notFound) { _ = try await s.load("a") }
        try await s.append("a", Self.all)
        try await s.append("a", [])
        #expect(try await s.load("a") == Self.all)
        let mode = try FileManager.default.attributesOfItem(atPath: s.file("a").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try await s.replace("a", [.user("only")])
        #expect(try await s.load("a") == [.user("only")])
        let mode2 = try FileManager.default.attributesOfItem(atPath: s.file("a").path)[.posixPermissions] as? Int
        #expect(mode2 == 0o600 && !FileManager.default.fileExists(atPath: s.file("a").path + ".tmp"))
    }

    @Test func lineShape() {
        #expect(Message.user("hi").line.jsonString == #"{"parts":[{"text":{"text":"hi"}}],"role":"user"}"#)
        let r = Part.reasoning(ReasoningPart(text: "t", signature: "s")).line.jsonString
        #expect(r == #"{"reasoning":{"provider_meta":{"signature":"s"},"text":"t"}}"#)
    }

    @Test func fileNames() {
        let s = FileStore(directory: URL(fileURLWithPath: "/x"))
        #expect(s.file("../escape").lastPathComponent == "___escape.messages.jsonl")
        #expect(s.file("ok_id-1").lastPathComponent == "ok_id-1.messages.jsonl")
        #expect(s.file("é/b").lastPathComponent == "__b.messages.jsonl")
    }

    @Test func badAndLegacyLines() async throws {
        let dir = try Scratch()
        let s = FileStore(directory: dir.url)
        let legacy = [
            #"{"role":"user","content":"old"}"#,
            "",
            "not json",
            #"{"Role":"assistant","Content":"","ToolCalls":[{"ID":"t1","Name":"read","Arguments":{"path":"a"}}]}"#,
            #"{"role":"tool","content":"result","ToolCallID":"t1","name":"read"}"#,
            #"{"role":"system","content":"skip"}"#,
            #"{"role":"user","parts":[{"text":{"text":"new"}},{"weird":{}}]}"#,
        ]
        try Data(legacy.joined(separator: "\n").utf8).write(to: s.file("l"))
        let got = try await s.load("l")
        #expect(
            got == [
                .user("old"),
                Message(role: .assistant, parts: [.toolCall(.call("t1", "read", #"{"path":"a"}"#))]),
                Message(
                    role: .tool,
                    parts: [.toolResult(ToolResult(callID: "t1", name: "read", content: [.text("result")]))]),
                .user("new"),
            ])
    }

    @Test func memoryStore() async throws {
        let s = MemoryStore()
        await #expect(throws: NativeError.notFound) { _ = try await s.load("a") }
        try await s.append("a", [.user("1")])
        try await s.append("a", [.user("2")])
        #expect(try await s.load("a").count == 2)
        try await s.replace("a", [])
        #expect(try await s.load("a").isEmpty)
    }
}

@Suite("CompactorTests")
struct CompactorTests {
    // Fixed on purpose: the kept tail never starts with a tool result.
    @Test func cutSkipsToolResults() async throws {
        let m = ScriptedModel([.parts(StreamPart.text("sum"))])
        let msgs: [Message] = [
            .user("a"), Message(role: .assistant, parts: [.text("b")]), .user("c"),
            Message(role: .assistant, parts: [.toolCall(.call("1", "x"))]),
            Message(role: .tool, parts: [.toolResult(ToolResult(callID: "1", name: "x", content: [.text("r")]))]),
        ]
        let out = try await SummaryCompactor(keepLast: 1).compact(model: m, messages: msgs)
        #expect(out.count == 3 && out[1].parts == [.toolCall(.call("1", "x"))])
        let prompt = m.requests.value[0].messages[0].parts.text
        #expect(prompt.hasSuffix("user: a\nassistant: b\nuser: c"))
    }

    @Test func shortAndFailing() async throws {
        let m = ScriptedModel([.fail(URLError(.timedOut)), .parts(StreamPart.calls(.call("1", "x")))])
        let short: [Message] = [.user("a"), .user("b")]
        #expect(try await SummaryCompactor(keepLast: 0).compact(model: m, messages: short) == short)
        let three: [Message] = [.user("a"), .user("b"), .user("c")]
        await #expect { try await SummaryCompactor(keepLast: 1).compact(model: m, messages: three) } throws: {
            ($0 as? NativeError)?.code == "compaction_failed"
        }
        await #expect(throws: NativeError("compaction_failed", "native: compaction summary called a tool")) {
            try await SummaryCompactor(keepLast: 1).compact(model: m, messages: three)
        }
        let tools = Array(repeating: Message(role: .tool, parts: []), count: 3)
        #expect(try await SummaryCompactor(keepLast: 1).compact(model: m, messages: [.user("a")] + tools).count == 4)
    }

    @Test func tokenEstimate() {
        let m: [Message] = [
            .user(String(repeating: "x", count: 40)),
            Message(
                role: .assistant,
                parts: [
                    .reasoning(ReasoningPart(text: "1234")), .toolCall(.call("1", "x", "1234")),
                    .file(FilePart(mediaType: "image/png", data: Data(count: 99))),
                ]),
        ]
        #expect(m.tokenEstimate == 12)
    }
}

@Suite("SkillTests")
struct SkillTests {
    @Test func catalogAndActivation() async throws {
        let dir = try Scratch()
        try dir.write(
            "pdf/SKILL.md",
            "---\nname: pdf-tools\ndescription: Work with PDF files.\nallowed-tools: read, bash\n---\nUse pdftotext.")
        try dir.write("pdf/ref.md", "r")
        try dir.write("plain/SKILL.md", "No frontmatter.")
        let c = try SkillCatalog([
            Skill(directory: dir.url.appendingPathComponent("pdf")),
            Skill(name: "mine", directory: dir.url.appendingPathComponent("plain")),
        ])
        #expect(c.entries.map(\.name) == ["pdf-tools", "mine"] && c.entries[0].allowedTools == ["read", "bash"])
        #expect(
            c.prompt.contains(
                "<skill>\n<name>pdf-tools</name>\n<description>Work with PDF files.</description>\n</skill>"))
        let tool = try #require(c.tool)
        let r = try await tool.call(Data(#"{"name":"pdf-tools"}"#.utf8))
        let v = try #require(JSONValue.parse(Data(r.content.text.utf8)))
        #expect(v["content"]?.string?.hasSuffix("Use pdftotext.") == true && v["resources"] == ["ref.md"])
        let plain = try await tool.call(Data(#"{"name":"mine"}"#.utf8))
        #expect(JSONValue.parse(Data(plain.content.text.utf8))?["resources"] == nil)
        let bad = try await tool.call(Data(#"{"name":"x"}"#.utf8))
        #expect(bad.isError && bad.content.text == #"unknown skill "x""#)
        #expect(try SkillCatalog([]).tool == nil && (try SkillCatalog([])).prompt.isEmpty)
        #expect(throws: NativeError.self) {
            try SkillCatalog([Skill(directory: dir.url.appendingPathComponent("none"))])
        }
    }

    @Test func sessionGetsTheSkillTool() async throws {
        let dir = try Scratch()
        try dir.write("s/SKILL.md", "---\ndescription: d\n---\nbody")
        let m = ScriptedModel([
            .parts(StreamPart.calls(.call("1", "activate_skill", #"{"name":"s"}"#))), .parts(StreamPart.text("ok")),
        ])
        let rt = await runtime(config(m))
        var r = request()
        r.skills = [Skill(directory: dir.url.appendingPathComponent("s"))]
        r.instructions = "  Be kind.  "
        let s = try await rt.start(r)
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await sink.waitResults(1)
        let req = m.requests.value[0]
        #expect(req.tools.map(\.name) == ["activate_skill"] && req.system.hasPrefix("Be kind.\n\n<available_skills>"))
        #expect(sink.tools.last?.status == .completed && sink.tools.last?.kind == .read)
        await rt.close()
    }
}
