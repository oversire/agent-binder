import Foundation
import Testing

@testable import AgentBinder
@testable import AgentBinderNative

@Suite("FileToolsTests")
struct FileToolsTests {
    let dir: Scratch
    let fs: FileTools

    init() throws {
        dir = try Scratch()
        fs = FileTools(
            root: dir.url, environment: ["PATH": "/usr/bin:/bin", "MARK": "m1"], bashTimeout: .seconds(2),
            maxFileBytes: 64)
    }

    func run(_ name: String, _ json: String) async throws -> ToolResult {
        let t = try #require(try await fs.tools().first { $0.spec.name == name })
        return try await t.call(Data(json.utf8))
    }

    @Test func specs() async throws {
        let specs = try await fs.tools().map(\.spec)
        #expect(specs.map(\.name) == ["bash", "read", "write", "edit", "glob", "grep"])
        #expect(specs.map(\.annotations.kind) == [.exec, .read, .edit, .edit, .search, .search])
        #expect(specs.map(\.needsApproval) == [true, false, true, true, false, false])
        #expect(fs.name == "fs")
        await fs.close()
    }

    @Test func readWriteEdit() async throws {
        #expect(try await run("write", #"{"path":"a/b.txt","content":"one two"}"#).content.text == "wrote a/b.txt")
        #expect(try await run("read", #"{"path":"./a/../a/b.txt"}"#).content.text == "one two")
        #expect(
            try await run("edit", #"{"path":"a/b.txt","old_string":"two","new_string":"2"}"#).content.text
                == "edited a/b.txt")
        #expect(dir.read("a/b.txt") == "one 2")
        try dir.write("dup.txt", "x x")
        let dup = try await run("edit", #"{"path":"dup.txt","old_string":"x","new_string":"y"}"#)
        #expect(dup.isError && dup.content.text == "old_string matched 2 times; must be unique")
        let none = try await run("edit", #"{"path":"dup.txt","old_string":"z","new_string":"y"}"#)
        #expect(none.content.text == "old_string not found")
        _ = try await run("edit", #"{"path":"new.txt","old_string":"","new_string":"fresh"}"#)
        #expect(dir.read("new.txt") == nil)
        try dir.write("empty.txt", "")
        _ = try await run("edit", #"{"path":"empty.txt","old_string":"","new_string":"fresh"}"#)
        #expect(dir.read("empty.txt") == "fresh")
    }

    @Test func sizeLimits() async throws {
        try dir.write("big.txt", String(repeating: "x", count: 65))
        #expect(try await run("read", #"{"path":"big.txt"}"#).content.text == "file exceeds the size limit")
        let w = try await run("write", "{\"path\":\"w.txt\",\"content\":\"\(String(repeating: "y", count: 65))\"}")
        #expect(w.isError && dir.read("w.txt") == nil)
        #expect(
            FileTools(root: dir.url, environment: [:], maxFileBytes: 0).maxFileBytes == FileTools.defaultMaxFileBytes)
    }

    @Test(arguments: ["/etc/passwd", "../x", "a/../../x", "", ".", "a/.."])
    func pathEscapes(_ p: String) async throws {
        let r = try await run("read", "{\"path\":\"\(p)\"}")
        #expect(r.isError && r.content.text == "path escapes the workspace root")
    }

    // Changed on purpose: a symlink out of the root is refused.
    @Test func symlinkEscape() async throws {
        let out = try Scratch()
        try out.write("secret.txt", "s")
        try FileManager.default.createSymbolicLink(
            at: dir.url.appendingPathComponent("link"), withDestinationURL: out.url)
        let r = try await run("read", #"{"path":"link/secret.txt"}"#)
        #expect(r.content.text == "path escapes the workspace root")
        let w = try await run("write", #"{"path":"link/new.txt","content":"x"}"#)
        #expect(w.isError && out.read("new.txt") == nil)
    }

    // Fixed on purpose: `**` matches zero or more segments.
    @Test func globDeep() async throws {
        for f in ["top.go", "a/mid.go", "a/b/c/deep.go", "a/b/note.md", ".git/x.go"] { try dir.write(f, "") }
        #expect(try await run("glob", #"{"pattern":"**/*.go"}"#).content.text == "a/b/c/deep.go\na/mid.go\ntop.go")
        #expect(try await run("glob", #"{"pattern":"a/**/*.md"}"#).content.text == "a/b/note.md")
        #expect(try await run("glob", #"{"pattern":"*.md"}"#).content.text == "a/b/note.md")
        #expect(try await run("glob", #"{"pattern":"*.rs"}"#).content.text == "(no matches)")
        #expect(try await run("glob", "{}").content.text.split(separator: "\n").count == 4)
        #expect(Glob("a/?.[ch]").matches("a/x.c") && !Glob("a/*").matches("a/b/c"))
    }

    @Test func globAndGrepCaps() async throws {
        for i in 0..<210 { try dir.write(String(format: "f%03d.txt", i), "hit\nhit\n") }
        #expect(try await run("glob", #"{"pattern":"*.txt"}"#).content.text.split(separator: "\n").count == 200)
        #expect(try await run("grep", #"{"pattern":"hit"}"#).content.text.split(separator: "\n").count == 100)
    }

    @Test func grep() async throws {
        try dir.write("a.txt", "alpha\nbeta " + String(repeating: "z", count: 300))
        try dir.write("sub/b.txt", "beta")
        let out = try await run("grep", #"{"pattern":"^beta"}"#).content.text
        #expect(out.hasPrefix("a.txt:2:beta zz") && out.hasSuffix("…\nsub/b.txt:1:beta"))
        #expect(try await run("grep", #"{"pattern":"beta","path":"sub"}"#).content.text == "sub/b.txt:1:beta")
        #expect(try await run("grep", #"{"pattern":"gamma"}"#).content.text == "(no matches)")
        #expect(try await run("grep", #"{"pattern":"("}"#).content.text.hasPrefix("bad pattern:"))
    }

    // Fixed on purpose: bash gets the full environment, PATH too, and runs in the root.
    @Test func bash() async throws {
        let env = try await run("bash", #"{"command":"echo $MARK; pwd -P; echo err >&2"}"#).content.text
        #expect(env.hasPrefix("m1\n/") && env.hasSuffix("/\(dir.url.lastPathComponent)\nerr\n"))
        #expect(try await run("bash", #"{"command":"ls / >/dev/null && exit 3"}"#).content.text == "\nexit code 3")
        #expect(try await run("bash", #"{"command":"  "}"#).content.text == "empty command")
        let long = try await run("bash", #"{"command":"head -c 9000 /dev/zero | tr '\\0' a"}"#).content.text
        #expect(long.utf8.count == 8000 + "…".utf8.count && long.hasSuffix("…"))
    }

    // Fixed on purpose: a timeout kills the group, so a background child does not hold the pipe.
    @Test func bashTimeout() async throws {
        let start = ContinuousClock.now
        let r = try await run("bash", #"{"command":"echo start; (sleep 30 &); sleep 30"}"#).content.text
        #expect(r == "start\n\ncommand timed out after 2.0 seconds")
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func bashCancel() async throws {
        let t = Task { try await run("bash", #"{"command":"sleep 30"}"#) }
        try await Task.sleep(for: .milliseconds(200))
        t.cancel()
        let start = ContinuousClock.now
        _ = try? await t.value
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
