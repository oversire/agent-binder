import Foundation
import Testing

@testable import AgentBinder

@Suite("ShellWordsTests")
struct ShellWordsTests {
    @Test(
        arguments: [
            ("", []),
            (" \t\n ", []),
            ("a b c", ["a", "b", "c"]),
            ("  a\t\tb\n c  ", ["a", "b", "c"]),
            ("'a b' c", ["a b", "c"]),
            (#"'a\tb'"#, [#"a\tb"#]),
            (#""a b" c"#, ["a b", "c"]),
            (#""a\"b""#, [#"a"b"#]),
            (#""a\\b""#, [#"a\b"#]),
            (#""a\nb""#, [#"a\nb"#]),
            (#"a\ b"#, ["a b"]),
            (#"a\"b"#, [#"a"b"#]),
            (#"a\\b"#, [#"a\b"#]),
            (#"a """#, ["a", ""]),
            ("a ''", ["a", ""]),
            (#""a b"#, ["a b"]),
            ("'a b", ["a b"]),
            (#"a\"#, [#"a\"#]),
            (#"--append-system-prompt "/tmp/a b/c.md""#, ["--append-system-prompt", "/tmp/a b/c.md"]),
            (#"-c """#, ["-c", ""]),
        ] as [(String, [String])])
    func split(_ input: String, _ want: [String]) {
        #expect(ShellWords.split(input) == want)
    }
}

@Suite("FrontmatterTests")
struct FrontmatterTests {
    @Test(
        arguments: [
            (
                "---\nname: my-skill\ndescription: A short description.\n---\nbody\n",
                ["name": "my-skill", "description": "A short description."]
            ),
            (
                "---\nname: folded\ndescription: >\n  first line\n  second line\n---\nbody\n",
                ["name": "folded", "description": "first line second line\n"]
            ),
            (
                "---\ndescription: |\n  line one\n  line two\nname: literal\n---\n",
                ["name": "literal", "description": "line one\nline two\n"]
            ),
            (
                "---\nname: \"quoted name\"\ndescription: \"say \\\"hi\\\"\"\n---\n",
                ["name": "quoted name", "description": #"say "hi""#]
            ),
            (
                "---\nname: 'single quoted'\ndescription: 'it''s here'\n---\n",
                ["name": "single quoted", "description": "it's here"]
            ),
            (
                "---\nname: my-skill # for the session\ndescription: plain\n---\n",
                ["name": "my-skill", "description": "plain"]
            ),
            ("---\r\nname: crlf\r\n---\r\n", ["name": "crlf"]),
            ("# just a body\n", [:]),
        ] as [(String, [String: String])])
    func parse(_ text: String, _ want: [String: String]) {
        #expect(Frontmatter(text).values == want)
    }

    @Test func nestedMappingIsSkipped() {
        let f = Frontmatter(
            "---\nname: nested\nmeta:\n  owner: team\n  tags:\n    - a\ndescription: after nested\n---\n")
        #expect(f["name"] == "nested")
        #expect(f["description"] == "after nested")
        #expect(f["owner"] == nil)
    }
}

@Suite("ToolClassifierTests")
struct ToolClassifierTests {
    @Test(arguments: [
        ("Read", ToolKind.read), ("read_file", .read), ("Bash", .exec), ("commandExecution", .exec),
        ("Edit", .edit), ("fileChange", .edit), ("MultiEdit", .edit), ("str_replace", .edit), ("Grep", .search),
        ("Glob", .search), ("webSearch", .search), ("mcp__sling__echo", .mcp), ("mcpToolCall", .mcp),
        ("notebook_edit", .edit), ("", .other), ("FrobnicateEverything", .other),
    ])
    func kind(_ name: String, _ want: ToolKind) {
        #expect(ToolClassifier.kind(for: name) == want)
    }

    @Test(
        arguments: [
            (ToolKind.edit, #"{"file_path":"/a","path":"/b","notebook_path":"/c"}"#, ["/a", "/b", "/c"]),
            (.edit, #"{"file_path":"/x","path":"/x"}"#, ["/x"]),
            (.edit, #"{"content":"x"}"#, []),
            (.read, #"{"file_path":"/a"}"#, []),
            (.exec, #"{"path":"/a"}"#, []),
            (.edit, #"{"file_path":"#, []),
            (.edit, "", []),
        ] as [(ToolKind, String, [String])])
    func paths(_ kind: ToolKind, _ input: String, _ want: [String]) {
        #expect(ToolClassifier.paths(kind: kind, input: input) == want)
    }

    @Test(arguments: [
        ("Read", #"{"command":"ls"}"#, ToolKind.read),
        ("someVendorTool", #"{"path":"/a"}"#, .edit),
        ("someVendorTool", #"{"file_path":"/a"}"#, .edit),
        ("someVendorTool", #"{"old_string":"a"}"#, .edit),
        ("someVendorTool", #"{"command":"ls"}"#, .exec),
        ("someVendorTool", #"{"cmd":"ls"}"#, .exec),
        ("someVendorTool", #"{"text":"hi"}"#, .other),
        ("someVendorTool", "{", .other),
        ("someVendorTool", "", .other),
    ])
    func permissionKind(_ tool: String, _ input: String, _ want: ToolKind) {
        #expect(ToolClassifier.permissionKind(name: tool, input: input) == want)
    }
}

@Suite("AttachmentTests")
struct AttachmentTests {
    @Test func load() throws {
        let dir = try TempDir()
        let png = try dir.write("pic.png", "png-bytes")
        let jpg = try dir.write("pic.JPG", "jpg-bytes")
        let json = try dir.write("data.json", #"{"a":1}"#)
        let bin = try dir.write("blob", "raw")
        let cases: [(PromptAttachment, String, String)] = [
            (.data(Data("inline".utf8), mime: ""), "inline", "application/octet-stream"),
            (.file(png), "png-bytes", "image/png"),
            (.file(jpg), "jpg-bytes", "image/jpeg"),
            (.file(json), #"{"a":1}"#, "application/json"),
            (.file(bin), "raw", "application/octet-stream"),
            (.file(png, mime: "text/csv"), "png-bytes", "text/csv"),
        ]
        for (a, data, mime) in cases {
            let l = try a.load()
            #expect(String(decoding: l.data, as: UTF8.self) == data)
            #expect(l.mime == mime)
        }
        #expect(try PromptAttachment.file(png).load().base64 == Data("png-bytes".utf8).base64EncodedString())
        #expect(throws: AgentBinderError.self) { try PromptAttachment.data(Data(), mime: "text/plain").load() }
        #expect(throws: AgentBinderError.self) {
            try PromptAttachment.file(dir.url.appendingPathComponent("none")).load()
        }
    }

    @Test func imagesComeFirst() {
        let items: [PromptAttachment] = [
            .file(URL(fileURLWithPath: "/a.json")), .file(URL(fileURLWithPath: "/b.png")),
            .file(URL(fileURLWithPath: "/c.txt")), .file(URL(fileURLWithPath: "/d.jpg")),
            .file(URL(fileURLWithPath: "/e.bin"), mime: "image/png"),
        ]
        let names = PromptAttachment.sorted(items).map { a -> String in
            if case .file(let u) = a.source { return u.lastPathComponent }
            return ""
        }
        #expect(names == ["b.png", "d.jpg", "e.bin", "a.json", "c.txt"])
    }
}

@Suite("ClassifierTests")
struct ClassifierTests {
    @Test(arguments: [
        ("Invalid API key", FailureClass.auth, "invalid_credentials"),
        ("rate_limit_error: too many requests", .limit, "rate_limited"),
        ("You are out of credits", .limit, "credits_exhausted"),
        ("entitlement check failed", .entitlement, "plan_refused"),
        ("Please run /login", .auth, "not_logged_in"),
        ("token has been revoked", .auth, "token_revoked"),
        ("overloaded_error", .overloaded, "capacity"),
        ("unrecognized subcommand 'app-server'", .protocol, "cli_too_old"),
        ("parse error: invalid frame", .protocol, "wire_drift"),
    ])
    func vendorTexts(_ text: String, _ cls: FailureClass, _ code: String) {
        let c = Classifier.classify(text)
        #expect(c.cls == cls)
        #expect(c.code == code)
        #expect(c.message == text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test(arguments: [
        "I read 429 files and found 401 issues", "the cache holds 1503 entries", "error 14290", "status 4290",
    ])
    func proseStaysUnknown(_ text: String) {
        #expect(Classifier.classify(text).cls == .unknown)
    }

    @Test(arguments: [
        ("429", FailureClass.limit), ("(429)", .limit), ("HTTP 429", .limit), ("api error (503)", .overloaded),
        ("status code: 401", .auth),
    ])
    func statusNumberNeedsErrorContext(_ text: String, _ cls: FailureClass) {
        #expect(Classifier.classify(text).cls == cls)
    }

    // The caller must pass error-shaped text only. Prose with a cue word classifies.
    @Test func capacityProseIsAKnownFalsePositive() {
        let c = Classifier.classify("capacity planning")
        #expect(c.cls == .overloaded)
        #expect(c.code == "capacity")
    }

    @Test func statusAlone() {
        let c = Classifier.classify("", status: 401)
        #expect(c.cls == .auth)
        #expect(c.code == "http_401")
        #expect(c.endReason == .auth)
        #expect(Classifier.classify("", status: 503).cls == .overloaded)
        #expect(Classifier.classify("", status: 0).cls == .unknown)
        #expect(Classifier.classify("", status: 402).cls == .limit)
        #expect(Classifier.classify("", status: 403).cls == .auth)
        #expect(Classifier.classify("").endReason == .failed)
    }

    @Test func harnessPrefix() {
        let c = Classifier.classify("rate_limit_error: too many requests", harness: .codex)
        #expect(c.cls == .limit)
        #expect(c.code == "codex.rate_limited")
        #expect(Classifier.classify("rate_limit_error", harness: .claude).code == "claude.rate_limited")
    }

    @Test func turnResult() {
        let maxTurns = Classifier.classify(TurnResult(subtype: "error_max_turns", isError: true))
        #expect(maxTurns.cls == FailureClass.none)
        #expect(maxTurns.code.contains("error_max_turns"))
        let credits = Classifier.classify(
            TurnResult(subtype: "error_during_execution", isError: true, text: "You are out of credits"))
        #expect(credits.cls == .limit)
        #expect(credits.code == "credits_exhausted")
    }
}

@Suite("SemverTests")
struct SemverTests {
    @Test(arguments: [
        ("1.2.3", "1.2.3", true), ("1.2.4", "1.2.3", true), ("1.3.0", "1.2.9", true), ("2.0", "1.9.9", true),
        ("1.2.2", "1.2.3", false), ("0.9.9", "1.0.0", false), ("v1.2.3", "1.2.3", true),
        ("1.2.3-beta.1", "1.2.3", true), ("2.1.0 (Claude Code)", "2.0.0", true), ("codex", "1.0.0", false),
        ("", "1.0.0", false), ("1", "1.0.0", false),
    ])
    func atLeast(_ got: String, _ want: String, _ ok: Bool) {
        #expect(semverAtLeast(got, want) == ok)
    }

    @Test func parse() {
        #expect(parseSemver("0.48.1\n") ?? (0, 0, 0) == (0, 48, 1))
        #expect(parseSemver("1.x") == nil)
    }
}
