import Foundation
import Testing

@testable import AgentBinder

@Suite("TranscriptReaderTests")
struct TranscriptReaderTests {
    let reader = TranscriptReader(claudeHome: URL(fileURLWithPath: "/nonexistent"))

    private func json(_ d: TranscriptDigest) throws -> JSONValue {
        try #require(JSONValue.parse(try JSONEncoder().encode(d)))
    }

    private func digest(_ lines: [String], budget: TranscriptBudget = TranscriptBudget()) throws -> TranscriptDigest {
        var r = reader
        r.budget = budget
        return try r.digest(data: Data(lines.joined(separator: "\n").utf8), sessionId: "fallback")
    }

    private func user(_ text: String, extra: String = "") -> String {
        let content = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return #"{"type":"user","sessionId":"s1"\#(extra),"message":{"role":"user","content":\#(content)}}"#
    }

    private func reply(_ text: String) -> String {
        let t = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return #"{"type":"assistant","message":{"content":[{"type":"text","text":\#(t)}]}}"#
    }

    /// The cases are byte copies of the session-digest contract fixtures. The `source` field is the consumer's.
    @Test(arguments: ["basic", "interrupted", "long", "notices", "tools-only"])
    func contractFixture(_ name: String) throws {
        let got = try json(reader.digest(file: Fixtures.url("claude/transcript/\(name).jsonl")))
        guard case .object(var want) = try Fixtures.json("claude/transcript/\(name).expected.json") else {
            Issue.record("expected an object")
            return
        }
        want["source"] = nil
        #expect(got == .object(want))
    }

    @Test func fixtureRoundTrips() throws {
        let d = try reader.digest(file: Fixtures.url("claude/transcript/interrupted.jsonl"))
        let again = try JSONDecoder().decode(TranscriptDigest.self, from: JSONEncoder().encode(d))
        #expect(again == d)
        #expect(d.last.first?.interrupted == true)
    }

    @Test func skipsSidechainBadLinesAndUsesTheFallbackId() throws {
        let d = try digest([
            "not json", "[1,2]", "",
            #"{"type":"user","isSidechain":true,"sessionId":"side","message":{"content":"agent prompt"}}"#,
            #"{"type":"user","message":{"content":"hello"}}"#, reply("hi"),
        ])
        #expect(d.sessionId == "fallback")
        #expect(d.turns == 1 && d.last.map(\.prompt) == ["hello"])
    }

    @Test func fileNameGivesTheFallbackId() throws {
        let dir = try TempDir()
        let file = try dir.write("abc.def.jsonl", #"{"type":"user","message":{"content":"x"}}"#)
        #expect(try reader.digest(file: file).sessionId == "abc.def")
    }

    // Python reads with universal newlines, so a lone CR ends a line.
    @Test func loneCarriageReturnEndsALine() throws {
        let d = try reader.digest(data: Data((user("one") + "\r" + reply("two")).utf8), sessionId: "x")
        #expect(d.last.map(\.text) == ["two"])
    }

    // Python str.strip removes U+001C to U+001F. Foundation does not count them as white space.
    @Test func stripUsesThePythonSpaceSet() throws {
        let d = try digest([user("\u{1F}\u{3000} ask \u{85}"), reply("\u{1C} answer \u{2028}")])
        #expect(d.last.first?.prompt == "ask")
        #expect(d.last.first?.text == "answer")
    }

    // "<" plus U+0338 is one Character ("≮"), but its first code point is "<": it is a notice.
    @Test func noticeCheckUsesCodePoints() throws {
        let d = try digest([user("real"), reply("a"), user("<\u{338}tag>"), reply("b")])
        #expect(d.turns == 1 && d.last.first?.text == "a\n\nb")
    }

    @Test func promptRules() throws {
        let d = try digest([
            user("Caveat: local command"), user("first"), reply("r1"),
            user("meta", extra: #","isMeta":true"#), user("summary", extra: #","isCompactSummary":1"#),
            #"{"type":"user","message":{"content":[{"type":"text","text":"a"},{"type":"image"},{"type":"text","text":"b"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"x"},{"type":"tool_use"},{"type":"text","text":"  "}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"c"},{"type":"tool_result"}]}}"#,
            reply("r2"), user("[Request interrupted by user]"), user("   "), user("no reply"),
        ])
        #expect(d.turns == 2)
        #expect(d.last.map(\.prompt) == ["first", "a\nb"])
        #expect(d.last[1].text == "r2" && d.last[1].tools == 1 && d.last[1].interrupted)
    }

    @Test func budgetCutsTurnsAndKeepsTheEndOfTheText() throws {
        var lines: [String] = []
        for i in 1...5 { lines += [user("p\(i)"), reply("first \(i)"), reply("close \(i) 🚀")] }
        let d = try digest(lines, budget: TranscriptBudget(earlier: 2, full: 1, maxChars: 4))
        #expect(d.turns == 5 && d.truncated)
        #expect(d.earlier.map(\.prompt) == ["p3", "p4"])
        #expect(d.earlier.map(\.closing) == ["close 3 🚀", "close 4 🚀"])
        #expect(d.last.first?.text == " 5 🚀")
        let none = try digest(lines, budget: TranscriptBudget(earlier: 0, full: 0))
        #expect(none.earlier.isEmpty && none.last.isEmpty && none.truncated)
    }

    @Test func budgetDecodesMissingFieldsAsDefaults() throws {
        let b = try JSONDecoder().decode(TranscriptBudget.self, from: Data(#"{"full":1}"#.utf8))
        #expect(b == TranscriptBudget(earlier: 12, full: 1, maxChars: 4000))
    }

    @Test func otherHarnessesAreUnsupported() throws {
        #expect(throws: TranscriptError.unsupportedHarness(.codex)) {
            try reader.digest(data: Data(), harness: .codex, sessionId: "x")
        }
        #expect(TranscriptError.unsupportedHarness(.codex).code == "unsupported_harness")
        #expect(throws: TranscriptError.notFound("/nonexistent/x.jsonl")) {
            try reader.digest(file: URL(fileURLWithPath: "/nonexistent/x.jsonl"))
        }
    }

    // Claude maps each UTF-16 code unit that is not an ASCII letter or digit to "-".
    @Test func projectFolderName() {
        #expect(TranscriptReader.projectFolderName(cwd: "/Users/a/my_repo.v2") == "-Users-a-my-repo-v2")
        #expect(TranscriptReader.projectFolderName(cwd: "/tmp/é🚀") == "-tmp----")
    }

    @Test func locateAndNewest() throws {
        let dir = try TempDir()
        let r = TranscriptReader(claudeHome: dir.url)
        let old = try dir.write("projects/-repo/old.jsonl", "")
        let new = try dir.write("projects/-repo/new.jsonl", "")
        try dir.write("projects/-repo/notes.txt", "")
        let other = try dir.write("projects/-other/old.jsonl", "")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -50)], ofItemAtPath: other.path)

        #expect(try r.newest(harness: .claude, cwd: "/repo") == new)
        #expect(try r.locate(harness: .claude, sessionId: "old", cwd: "/repo") == old)
        #expect(try r.locate(harness: .claude, sessionId: "old") == other)
        #expect(throws: TranscriptError.notFound("gone")) { try r.locate(harness: .claude, sessionId: "gone") }
        #expect(throws: TranscriptError.notFound("../x")) { try r.locate(harness: .claude, sessionId: "../x") }
        #expect(throws: TranscriptError.notFound("/none")) { try r.newest(harness: .claude, cwd: "/none") }
        #expect(throws: TranscriptError.unsupportedHarness(.pi)) { try r.newest(harness: .pi, cwd: "/repo") }
    }
}
