import Foundation
import Testing

@testable import AgentBinder

private let sh = URL(fileURLWithPath: "/bin/sh")

private struct FlagStub: FlagProbing {
    var flags: Set<String> = []
    func supportsFlag(_ binary: URL, _ flag: String) async -> Bool { flags.contains(flag) }
}

private func builder(client: String = "agentbinder", flags: Set<String> = []) -> LaunchBuilder {
    let resolver = BinaryResolver(.init(useLoginShellPath: false, environment: ["PATH": "/nonexistent"]))
    return LaunchBuilder(clientName: client, resolver: resolver, flags: FlagStub(flags: flags))
}

private func request(_ h: Harness, binary: URL? = sh) -> StartRequest {
    StartRequest(harness: h, workingDirectory: URL(fileURLWithPath: "/tmp"), binary: binary)
}

private func value(after key: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
    return args[i + 1]
}

private func hasPair(_ args: [String], _ key: String, _ value: String) -> Bool {
    zip(args, args.dropFirst()).contains { $0 == key && $1 == value }
}

private func mode(_ path: String) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private let claudeClient = [
    "CLAUDE_CODE_ENTRYPOINT": "agentbinder-cli",
    "CLAUDE_AGENT_SDK_VERSION": "agentbinder-cli/1",
]

private func claudeHome(_ home: String) -> [String: String] {
    claudeClient.merging(
        ["CLAUDE_CONFIG_DIR": home, "DISABLE_AUTOUPDATER": "1", "DISABLE_UPDATES": "1"]) { $1 }
}

private let stdioServer = MCPServer.stdio(name: "local", command: "cmd", args: ["a", "b"], env: ["K": "V"])
private let httpServer = MCPServer.http(
    name: "remote", url: URL(string: "https://example.test/mcp")!, headers: ["Authorization": "token"])

struct GoldenCase: Sendable, CustomTestStringConvertible {
    var name: String
    var req: StartRequest
    var resume = false
    var args: [String] = []
    var env: [String: String] = [:]
    var testDescription: String { name }
}

private let home = "/tmp/agentbinder-golden-home"

private func golden() -> [GoldenCase] {
    func r(_ h: Harness, _ edit: (inout StartRequest) -> Void = { _ in }) -> StartRequest {
        var req = request(h)
        edit(&req)
        return req
    }
    let homeURL = URL(fileURLWithPath: home)
    let piHome = ["PI_CODING_AGENT_DIR": home, "PI_SKIP_VERSION_CHECK": "1", "PI_TELEMETRY": "0"]
    let claudeTail = ["--permission-prompt-tool", "stdio", "--permission-mode", "default"]
    return [
        GoldenCase(
            name: "claude new session id", req: r(.claude) { $0.sessionID = "sid-1" },
            args: ["--session-id=sid-1"] + claudeTail, env: claudeClient),
        GoldenCase(
            name: "claude resume", req: r(.claude) { $0.sessionID = "sid-1" }, resume: true,
            args: ["--resume=sid-1"] + claudeTail, env: claudeClient),
        GoldenCase(
            name: "claude model and effort",
            req: r(.claude) {
                $0.model = "claude-opus-4-1"
                $0.effort = .high
            },
            args: ["--model", "claude-opus-4-1", "--effort", "high"] + claudeTail, env: claudeClient),
        GoldenCase(
            name: "claude auto", req: r(.claude) { $0.permissions = .init(mode: .auto) },
            args: ["--permission-prompt-tool", "stdio", "--permission-mode", "bypassPermissions"], env: claudeClient),
        GoldenCase(
            name: "claude auto edit", req: r(.claude) { $0.permissions = .init(mode: .autoEdit) },
            args: ["--permission-prompt-tool", "stdio", "--permission-mode", "acceptEdits"], env: claudeClient),
        GoldenCase(
            name: "claude inherit keeps stdio without a mode flag",
            req: r(.claude) { $0.permissions = .init(mode: .inherit) },
            args: ["--permission-prompt-tool", "stdio"], env: claudeClient),
        GoldenCase(
            name: "claude extra prompt tool wins",
            req: r(.claude) { $0.extraArguments = ["--permission-prompt-tool", "my-bridge"] },
            args: ["--permission-mode", "default", "--permission-prompt-tool", "my-bridge"], env: claudeClient),
        GoldenCase(
            name: "claude extra prompt tool equals form wins",
            req: r(.claude) {
                $0.effort = .low
                $0.extraArguments = ["--permission-prompt-tool=my-bridge"]
            },
            args: ["--effort", "low", "--permission-mode", "default", "--permission-prompt-tool=my-bridge"],
            env: claudeClient),
        GoldenCase(
            name: "opencode auto has no stdio callback", req: r(.opencode) { $0.permissions = .init(mode: .auto) }),
        GoldenCase(
            name: "claude isolated home", req: r(.claude) { $0.home = homeURL }, args: claudeTail,
            env: claudeHome(home)),
        GoldenCase(
            name: "claude shared auth keeps the keychain",
            req: r(.claude) {
                $0.home = homeURL
                $0.raw = ["shared_auth": .bool(true)]
            },
            args: claudeTail, env: claudeHome(home).merging(["CLAUDE_SECURESTORAGE_CONFIG_DIR": ""]) { $1 }),
        GoldenCase(
            name: "claude shared auth off",
            req: r(.claude) {
                $0.home = homeURL
                $0.raw = ["shared_auth": .bool(false)]
            },
            args: claudeTail, env: claudeHome(home)),
        GoldenCase(name: "codex session id stays on the wire", req: r(.codex) { $0.sessionID = "t-1" }),
        GoldenCase(
            name: "codex effort override and no model flag",
            req: r(.codex) {
                $0.model = "gpt-5-codex"
                $0.effort = .high
            },
            args: ["-c", "model_reasoning_effort=high"]),
        GoldenCase(name: "codex isolated home", req: r(.codex) { $0.home = homeURL }, env: ["CODEX_HOME": home]),
        GoldenCase(name: "codex no home", req: r(.codex)),
        GoldenCase(
            name: "opencode isolated home", req: r(.opencode) { $0.home = homeURL },
            env: ["OPENCODE_CONFIG_DIR": home]),
        GoldenCase(
            name: "pi new session id",
            req: r(.pi) {
                $0.sessionID = "pi-1"
                $0.home = homeURL
            },
            args: ["--session-id", "pi-1"], env: piHome),
        GoldenCase(
            name: "pi resume",
            req: r(.pi) {
                $0.sessionID = "pi-1"
                $0.home = homeURL
            },
            resume: true, args: ["--session", "pi-1"], env: piHome),
        GoldenCase(name: "pi auto approves", req: r(.pi) { $0.permissions = .init(mode: .auto) }, args: ["--approve"]),
        GoldenCase(name: "pi ask has no trust flag", req: r(.pi) { $0.permissions = .init(mode: .ask) }),
        GoldenCase(
            name: "cursor isolated home", req: r(.cursor) { $0.home = homeURL },
            env: ["CURSOR_CONFIG_DIR": home, "CURSOR_DATA_DIR": home]),
        GoldenCase(
            name: "cursor auto trusts", req: r(.cursor) { $0.permissions = .init(mode: .auto) }, args: ["--trust"]),
        GoldenCase(
            name: "cursor auto edit has no trust flag", req: r(.cursor) { $0.permissions = .init(mode: .autoEdit) }),
        GoldenCase(name: "copilot new session id has no flag", req: r(.copilot) { $0.sessionID = "cp-1" }),
        GoldenCase(
            name: "copilot resume", req: r(.copilot) { $0.sessionID = "cp-1" }, resume: true,
            args: ["--resume", "cp-1"]),
        GoldenCase(
            name: "copilot model effort and no trust flag",
            req: r(.copilot) {
                $0.model = "gpt-5"
                $0.effort = .low
                $0.permissions = .init(mode: .auto)
            },
            args: ["--model", "gpt-5", "--effort", "low"]),
        GoldenCase(
            name: "gemini model without effort",
            req: r(.gemini) {
                $0.model = "gemini-2.5-pro"
                $0.effort = .high
            },
            args: ["--model", "gemini-2.5-pro"]),
        GoldenCase(
            name: "extra args land last",
            req: r(.claude) {
                $0.model = "m"
                $0.extraArguments = ["--settings", "hooks.json"]
                $0.environment = ["RUN_ID": "r1"]
            },
            args: ["--model", "m"] + claudeTail + ["--settings", "hooks.json"],
            env: claudeClient.merging(["RUN_ID": "r1"]) { $1 }),
        GoldenCase(
            name: "codex extra args land last",
            req: r(.codex) {
                $0.effort = .low
                $0.extraArguments = ["-c", "notify=true"]
            },
            args: ["-c", "model_reasoning_effort=low", "-c", "notify=true"]),
    ]
}

@Suite("LaunchBuilderTests")
struct LaunchBuilderTests {
    @Test(arguments: golden())
    func goldenBuild(_ c: GoldenCase) async throws {
        let l = try await builder().prepare(c.req, resume: c.resume)
        #expect(l.binary == sh)
        #expect(l.arguments == c.args)
        #expect(l.environment == c.env)
        #expect(l.resume == c.resume)
        #expect(l.tempPaths.isEmpty)
    }

    @Test func clientNameReachesTheMarker() async throws {
        let l = try await builder(client: "sling").prepare(request(.claude), resume: false)
        #expect(l.environment == ["CLAUDE_CODE_ENTRYPOINT": "sling-cli", "CLAUDE_AGENT_SDK_VERSION": "sling-cli/1"])
    }

    @Test func baseCommandSkipsTheBuilder() async throws {
        var req = request(.claude)
        req.home = URL(fileURLWithPath: home)
        req.environment = ["HOOK": "1"]
        req.baseCommand = ["/bin/sh", "-c", "echo hi", "--model", "x"]
        let l = try await builder().prepare(req, resume: true)
        #expect(l.binary == sh)
        #expect(l.arguments == ["-c", "echo hi", "--model", "x"])
        #expect(l.environment == ["HOOK": "1"])
        #expect(l.resume)
    }

    @Test func emptyBaseCommandThrows() async {
        var req = request(.claude)
        req.baseCommand = ["   "]
        await #expect(throws: AgentBinderError.invalidRequest("claude: empty base command")) {
            try await builder().prepare(req, resume: false)
        }
    }

    @Test func missingBinaryNamesTheSearchPath() async {
        let req = request(Harness("launchtest-missing-binary"), binary: nil)
        do {
            _ = try await builder().prepare(req, resume: false)
            Issue.record("no error")
        } catch let e as AgentBinderError {
            #expect(e.code == "binary_not_found")
            #expect("\(e)".contains("launchtest-missing-binary"))
            #expect("\(e)".contains("/nonexistent"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func unknownHarnessIsAGenericLaunch() async throws {
        var req = request(Harness("launchtest-unknown"))
        req.extraArguments = ["--x"]
        let l = try await builder().prepare(req, resume: false)
        #expect(l.binary == sh)
        #expect(l.arguments == ["--x"])
        #expect(l.environment.isEmpty)
    }
}

// Serialized: two tests count the Claude MCP temp folders.
@Suite("MCPRenderTests", .serialized)
struct MCPRenderTests {
    @Test func failedPrepareRemovesTheTempFolders() async throws {
        var req = request(.claude)
        req.mcpServers = [stdioServer]
        req.skills = [Skill(directory: URL(fileURLWithPath: "/nonexistent/skill"))]
        let before = try tempFolders()
        await #expect(throws: AgentBinderError.self) { try await builder().prepare(req, resume: false) }
        #expect(try tempFolders() == before)
    }

    private func tempFolders() throws -> Set<String> {
        let all = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
        return Set(all.filter { $0.hasPrefix("agentbinder-claude-mcp-") })
    }
    @Test func claudeConfigFile() async throws {
        var req = request(.claude)
        req.mcpServers = [stdioServer, httpServer]
        let l = try await builder().prepare(req, resume: false)
        defer { l.cleanup() }

        let path = try #require(value(after: "--mcp-config", in: l.arguments))
        #expect(!l.arguments.contains("--strict-mcp-config"))
        #expect(try mode(path) == 0o600)
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        #expect(try mode(dir.path) == 0o700)
        #expect(dir.lastPathComponent.hasPrefix("agentbinder-claude-mcp-"))

        let doc = try #require(JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        let local = try #require(doc.at("mcpServers", "local"))
        #expect(local["command"]?.string == "cmd")
        #expect(local["args"] == ["a", "b"])
        #expect(local.at("env", "K")?.string == "V")
        let remote = try #require(doc.at("mcpServers", "remote"))
        #expect(remote["type"]?.string == "http")
        #expect(remote["url"]?.string == "https://example.test/mcp")

        l.cleanup()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func claudeStrictOptIn() async throws {
        var req = request(.claude)
        req.mcpServers = [stdioServer]
        req.raw = ["strict_mcp": .bool(true)]
        let l = try await builder().prepare(req, resume: false)
        defer { l.cleanup() }
        #expect(l.arguments.contains("--strict-mcp-config"))
    }

    @Test func codexArguments() async throws {
        var req = request(.codex)
        req.mcpServers = [stdioServer, httpServer]
        let l = try await builder().prepare(req, resume: false)
        #expect(
            l.arguments == [
                "-c", #"mcp_servers.local.command="cmd""#,
                "-c", #"mcp_servers.local.args=["a", "b"]"#,
                "-c", #"mcp_servers.local.env_vars=["K"]"#,
                "-c", #"mcp_servers.remote.url="https://example.test/mcp""#,
                "-c",
                #"mcp_servers.remote.env_http_headers={"Authorization" = "AGENTBINDER_MCP_REMOTE_AUTHORIZATION"}"#,
            ])
        #expect(l.environment == ["K": "V", "AGENTBINDER_MCP_REMOTE_AUTHORIZATION": "token"])
    }

    @Test func codexSecretsStayInTheEnvironment() throws {
        let servers = [
            MCPServer.stdio(name: "gh", command: "gh-mcp", env: ["GH_TOKEN": "s3cret-env"]),
            MCPServer.http(
                name: "api-x", url: URL(string: "https://x.test/mcp")!,
                headers: ["Authorization": "Bearer s3cret-hdr", "X-Org": "acme"]),
        ]
        let args = MCPRender.codexArguments(servers)
        let joined = args.joined(separator: " ")
        for secret in ["s3cret-env", "s3cret-hdr", "acme"] { #expect(!joined.contains(secret)) }
        #expect(hasPair(args, "-c", #"mcp_servers.gh.env_vars=["GH_TOKEN"]"#))
        #expect(
            hasPair(
                args, "-c",
                #"mcp_servers.api-x.env_http_headers={"Authorization" = "AGENTBINDER_MCP_API_X_AUTHORIZATION", "X-Org" = "AGENTBINDER_MCP_API_X_X_ORG"}"#
            ))
        #expect(
            try MCPRender.codexEnvironment(servers) == [
                "GH_TOKEN": "s3cret-env",
                "AGENTBINDER_MCP_API_X_AUTHORIZATION": "Bearer s3cret-hdr",
                "AGENTBINDER_MCP_API_X_X_ORG": "acme",
            ])
    }

    @Test func codexEnvironmentConflict() async throws {
        let same = [
            MCPServer.stdio(name: "a", command: "a", env: ["TOKEN": "x"]),
            MCPServer.stdio(name: "b", command: "b", env: ["TOKEN": "x"]),
        ]
        _ = try MCPRender.codexEnvironment(same)
        let diff = [
            MCPServer.stdio(name: "a", command: "a", env: ["TOKEN": "x"]),
            MCPServer.stdio(name: "b", command: "b", env: ["TOKEN": "y"]),
        ]
        #expect(throws: AgentBinderError.self) { try MCPRender.codexEnvironment(diff) }

        var req = request(.codex)
        req.environment = ["TOKEN": "job"]
        req.mcpServers = same
        await #expect(throws: AgentBinderError.self) { try await builder().prepare(req, resume: false) }
    }

    @Test func openCodeConfigContent() async throws {
        var req = request(.opencode)
        req.mcpServers = [stdioServer, httpServer]
        let l = try await builder().prepare(req, resume: false)
        let content = try #require(l.environment["OPENCODE_CONFIG_CONTENT"])
        let cfg = try #require(JSONValue.parse(content))
        let local = try #require(cfg.at("mcp", "local"))
        #expect(local["type"]?.string == "local")
        #expect(local["command"] == ["cmd", "a", "b"])
        #expect(local.at("environment", "K")?.string == "V")
        let remote = try #require(cfg.at("mcp", "remote"))
        #expect(remote["type"]?.string == "remote")
        #expect(remote["url"]?.string == "https://example.test/mcp")
    }

    @Test func piNeedsAHome() async throws {
        var req = request(.pi)
        req.mcpServers = [stdioServer]
        await #expect(throws: AgentBinderError.homeRequired(feature: "MCP injection")) {
            try await builder().prepare(req, resume: false)
        }

        let dir = try TempDir()
        req.home = dir.url
        let l = try await builder().prepare(req, resume: false)
        defer { l.cleanup() }
        let path = dir.url.appendingPathComponent("mcp.json").path
        let doc = try #require(JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        #expect(doc.at("mcpServers", "local", "command")?.string == "cmd")
        #expect(try mode(path) == 0o600)
    }

    @Test(arguments: [Harness.copilot, .cursor, .gemini])
    func acpHarnessesRenderNothing(_ h: Harness) async throws {
        var req = request(h)
        req.mcpServers = [stdioServer, httpServer]
        let l = try await builder().prepare(req, resume: false)
        #expect(l.environment.isEmpty)
        for a in l.arguments {
            #expect(!a.lowercased().contains("mcp") && !a.contains("local") && !a.contains("remote"))
        }
    }

    @Test func acpServers() {
        let stdioWant: JSONValue = [
            "name": "local", "command": "cmd", "args": ["a", "b"], "env": [["name": "K", "value": "V"]],
        ]
        let httpWant: JSONValue = [
            "name": "remote", "type": "http", "url": "https://example.test/mcp",
            "headers": [["name": "Authorization", "value": "token"]],
        ]
        #expect(MCPRender.acpServers([stdioServer], http: true) == [stdioWant])
        #expect(MCPRender.acpServers([httpServer], http: true) == [httpWant])
        #expect(MCPRender.acpServers([httpServer], http: false) == [])
        #expect(MCPRender.acpServers([httpServer, stdioServer], http: false) == [stdioWant])
    }

    @Test func codexTOMLEscapes() {
        let s = MCPServer.stdio(name: "q", command: #"/a "b"\c"#, args: [#"x"y"#])
        #expect(
            MCPRender.codexArguments([s]) == [
                "-c", #"mcp_servers.q.command="/a \"b\"\\c""#, "-c", #"mcp_servers.q.args=["x\"y"]"#,
            ])
    }

    @Test func headerVariableName() {
        #expect(MCPRender.headerVariable("api-x", "X-Org") == "AGENTBINDER_MCP_API_X_X_ORG")
        #expect(MCPRender.headerVariable("gh", "authorization") == "AGENTBINDER_MCP_GH_AUTHORIZATION")
    }
}

@Suite("SkillTests")
struct SkillTests {
    let root: TempDir

    init() throws { root = try TempDir() }

    private func skill(_ name: String, _ body: String) throws -> URL {
        try root.write("\(name)/SKILL.md", body).deletingLastPathComponent()
    }

    private func plain(_ name: String, _ description: String) throws -> URL {
        try skill(name, "---\nname: \(name)\ndescription: \(description)\n---\n# \(name)\n")
    }

    private func expectLink(_ link: URL, to target: URL) throws {
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(URL(fileURLWithPath: dest).resolvingSymlinksInPath() == target.resolvingSymlinksInPath())
    }

    @Test func load() throws {
        let dir = try plain("from-front", "the description")
        let s = try LoadedSkill(Skill(directory: dir))
        #expect(s.name == "from-front")
        #expect(s.description == "the description")
        #expect(s.directory == dir)
        #expect(try LoadedSkill(Skill(name: "explicit", directory: dir)).name == "explicit")

        let noName = try skill("dir-name-wins", "---\ndescription: d\n---\n")
        #expect(try LoadedSkill(Skill(directory: noName)).name == "dir-name-wins")

        let missing = root.url.appendingPathComponent("no-skill-md")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        do {
            _ = try LoadedSkill(Skill(directory: missing))
            Issue.record("no error")
        } catch {
            #expect("\(error)".contains(missing.path))
        }
    }

    @Test func claudePlugin() async throws {
        let a = try plain("alpha", "first skill text")
        let b = try plain("beta", "second skill text")
        var req = request(.claude)
        req.skills = [Skill(directory: a), Skill(directory: b)]
        let l = try await builder().prepare(req, resume: false)
        defer { l.cleanup() }

        let dir = URL(fileURLWithPath: try #require(value(after: "--plugin-dir", in: l.arguments)))
        let meta = try #require(
            JSONValue.parse(try Data(contentsOf: dir.appendingPathComponent(".claude-plugin/plugin.json"))))
        #expect(meta["name"]?.string == SkillOverlay.pluginName)
        try expectLink(dir.appendingPathComponent("skills/alpha"), to: a)
        try expectLink(dir.appendingPathComponent("skills/beta"), to: b)
        #expect(l.instructions == nil)
    }

    @Test(arguments: [(Harness.codex, "skills"), (.opencode, "skill"), (.opencode2, "skill"), (.pi, "skills")])
    func homeLinks(_ h: Harness, _ folder: String) async throws {
        let a = try plain("alpha", "first skill text")
        let home = try TempDir()
        var req = request(h)
        req.home = home.url
        req.skills = [Skill(directory: a)]
        let l = try await builder().prepare(req, resume: false)
        try expectLink(home.url.appendingPathComponent("\(folder)/alpha"), to: a)
        #expect(l.instructions == nil)

        // A second run replaces the link.
        _ = try await builder().prepare(req, resume: false)
        try expectLink(home.url.appendingPathComponent("\(folder)/alpha"), to: a)
    }

    @Test func piSkillFlag() async throws {
        let a = try plain("alpha", "first skill text")
        var req = request(.pi)
        req.skills = [Skill(directory: a)]
        let l = try await builder(flags: ["--skill"]).prepare(req, resume: false)
        #expect(l.arguments == ["--skill", a.path])
        #expect(l.instructions == nil)
    }

    @Test(arguments: [Harness.codex, .pi, .copilot, .gemini])
    func indexFallback(_ h: Harness) async throws {
        let a = try plain("alpha", "first skill text")
        let b = try plain("beta", "second   skill text")
        var req = request(h)
        req.skills = [Skill(directory: a), Skill(directory: b)]
        let l = try await builder().prepare(req, resume: false)
        let text = try #require(l.instructions)
        for (s, d) in [(a, "first skill text"), (b, "second skill text")] {
            #expect(text.contains(s.lastPathComponent))
            #expect(text.contains(d))
            #expect(text.contains(s.appendingPathComponent("SKILL.md").path))
        }
        #expect(text.contains("Read the file before you do a task"))
    }

    @Test func linkReplacesADanglingLink() throws {
        let a = try plain("alpha", "x")
        let into = root.url.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: into.appendingPathComponent("alpha"), withDestinationURL: URL(fileURLWithPath: "/nonexistent"))
        try SkillOverlay.link([LoadedSkill(Skill(directory: a))], into: into)
        try expectLink(into.appendingPathComponent("alpha"), to: a)
    }
}

@Suite("InstructionsTests")
struct InstructionsTests {
    static let text = "be brief and precise"

    @Test(arguments: [
        (Harness.claude, true), (.codex, false), (.opencode, false), (.opencode2, false), (.copilot, false),
        (.cursor, false), (.gemini, false), (.pi, false),
    ])
    func rendering(_ h: Harness, _ flag: Bool) async throws {
        var req = request(h)
        req.instructions = Self.text
        let l = try await builder().prepare(req, resume: false)
        #expect(hasPair(l.arguments, "--append-system-prompt", Self.text) == flag)
        #expect(l.instructions == (flag ? nil : Self.text))
    }

    @Test func piAppendFlag() async throws {
        var req = request(.pi)
        req.instructions = Self.text
        let l = try await builder(flags: ["--append-system-prompt"]).prepare(req, resume: false)
        #expect(l.arguments == ["--append-system-prompt", Self.text])
        #expect(l.instructions == nil)
    }

    @Test func blankInstructionsAreNil() async throws {
        var req = request(.codex)
        req.instructions = "  \n "
        #expect(try await builder().prepare(req, resume: false).instructions == nil)
    }

    @Test func joinOrder() {
        #expect(Instructions.join("consumer text", skillIndex: "skill index") == "consumer text\n\nskill index")
        #expect(Instructions.join("consumer text", skillIndex: "") == "consumer text")
        #expect(Instructions.join(nil, skillIndex: "skill index") == "skill index")
    }

    @Test func block() {
        #expect(Instructions.block("") == "")
        #expect(Instructions.block("   \n ") == "")
        let want = "<session-instructions>\nhi\n</session-instructions>"
        #expect(Instructions.block("hi") == want)
        #expect(Instructions.withInstructions("hi", "prompt", first: true) == want + "\n\nprompt")
        #expect(Instructions.withInstructions("hi", "prompt", first: false) == "prompt")
        #expect(Instructions.withInstructions("", "prompt", first: true) == "prompt")
        #expect(Instructions.withInstructions(nil, "prompt", first: true) == "prompt")
    }
}
