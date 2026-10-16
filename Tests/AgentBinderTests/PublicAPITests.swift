import AgentBinder
import Foundation
import Testing

@Suite("PermissionPolicyTests")
struct PermissionPolicyTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var policy: PermissionPolicy
        var kind: ToolKind
        var tool: String
        var allows: Bool
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "ask never answers an edit", policy: .init(mode: .ask), kind: .edit, tool: "Edit", allows: false),
        Case(name: "ask never answers an exec", policy: .init(mode: .ask), kind: .exec, tool: "Bash", allows: false),
        Case(name: "the default mode is ask", policy: .init(), kind: .edit, tool: "Edit", allows: false),
        Case(
            name: "inherit never answers an edit", policy: .init(mode: .inherit), kind: .edit, tool: "Edit",
            allows: false),
        Case(
            name: "inherit answers an allowed tool", policy: .init(mode: .inherit, allowTools: ["Bash"]), kind: .exec,
            tool: "Bash", allows: true),
        Case(
            name: "ask allows an exact tool", policy: .init(allowTools: ["Bash"]), kind: .exec, tool: "Bash",
            allows: true),
        Case(
            name: "the allow list is case sensitive", policy: .init(allowTools: ["Bash"]), kind: .exec, tool: "bash",
            allows: false),
        Case(
            name: "a trailing star allows the prefix", policy: .init(allowTools: ["mcp__sling__*"]), kind: .mcp,
            tool: "mcp__sling__foo", allows: true),
        Case(
            name: "a trailing star stays in the prefix", policy: .init(allowTools: ["mcp__sling__*"]), kind: .mcp,
            tool: "mcp__other__foo", allows: false),
        Case(
            name: "a trailing star matches the bare prefix", policy: .init(allowTools: ["mcp__sling__*"]), kind: .mcp,
            tool: "mcp__sling__", allows: true),
        Case(
            name: "a bare star allows each tool", policy: .init(allowTools: ["*"]), kind: .other, tool: "x",
            allows: true),
        Case(
            name: "an empty tool is never allowed", policy: .init(allowTools: ["*"]), kind: .other, tool: "",
            allows: false),
        Case(
            name: "an empty pattern allows nothing", policy: .init(allowTools: [""]), kind: .other, tool: "x",
            allows: false),
        Case(name: "auto_edit answers edits", policy: .init(mode: .autoEdit), kind: .edit, tool: "Write", allows: true),
        Case(
            name: "auto_edit does not answer exec", policy: .init(mode: .autoEdit), kind: .exec, tool: "Bash",
            allows: false),
        Case(
            name: "auto_edit answers an allowed tool", policy: .init(mode: .autoEdit, allowTools: ["Bash"]),
            kind: .exec,
            tool: "Bash", allows: true),
        Case(
            name: "auto answers each request", policy: .init(mode: .auto), kind: .other, tool: "Whatever", allows: true),
        Case(name: "auto answers an empty tool", policy: .init(mode: .auto), kind: .other, tool: "", allows: true),
    ]

    @Test(arguments: cases)
    func answer(_ c: Case) {
        let d = c.policy.answer(kind: c.kind, tool: c.tool)
        if c.allows {
            #expect(d == .allow())
        } else {
            #expect(d == nil)
        }
    }

    @Test func modeRawValues() {
        #expect(PermissionPolicy.Mode.allCases.map(\.rawValue) == ["ask", "auto_edit", "auto", "inherit"])
    }
}

@Suite("WindowKeyTests")
struct WindowKeyTests {
    @Test(arguments: [
        (300, WindowKey.fiveHour), (1440, .daily), (10080, .weekly), (43200, .monthly), (60, .custom), (0, .custom),
    ])
    func fromMinutes(_ minutes: Int, _ key: WindowKey) {
        #expect(WindowKey(minutes: minutes) == key)
    }

    @Test func rawValues() {
        #expect(WindowKey.fiveHour.rawValue == "five_hour")
        #expect(WindowKey.custom.rawValue == "custom")
    }
}

@Suite("HarnessTests")
struct HarnessTests {
    @Test func builtInOrder() {
        #expect(
            Harness.allBuiltIn.map(\.rawValue) == [
                "claude", "codex", "opencode", "opencode2", "pi", "copilot", "cursor", "gemini", "fake", "native",
            ])
    }

    @Test func binaryNames() {
        #expect(Harness.cursor.binaryName == "cursor-agent")
        for h in Harness.allBuiltIn where h != .cursor { #expect(h.binaryName == h.rawValue) }
        #expect(Harness("my-agent").binaryName == "my-agent")
    }

    @Test func customNamesAndCoding() throws {
        let h = Harness("custom")
        #expect(h == Harness(rawValue: "custom"))
        #expect(h.description == "custom")
        let data = try JSONEncoder().encode([Harness.claude, h])
        #expect(String(decoding: data, as: UTF8.self) == #"["claude","custom"]"#)
        #expect(try JSONDecoder().decode([Harness].self, from: data) == [.claude, h])
    }
}

@Suite("ErrorCodeTests")
struct ErrorCodeTests {
    static let all: [AgentBinderError] = [
        .noDriver(.claude), .binaryNotFound(.claude, searched: ["/bin"]), .sandboxed,
        .belowVersionFloor(.claude, version: "1.0.0", floor: "2.0.0"), .handshakeFailed("x"), .handshakeTimeout,
        .resumeUnsupported, .unsupported("x"), .turnActive, .noActiveTurn, .sessionClosed, .frameTooLarge,
        .invalidRequest("x"), .homeRequired(feature: "skills"), .launch("x"), .timeout("x"),
        .vendor(code: 1, message: "x"),
    ]

    @Test func codesAreUniqueAndStable() {
        let codes = Self.all.map(\.code)
        #expect(Set(codes).count == codes.count)
        #expect(
            codes == [
                "no_driver", "binary_not_found", "sandboxed", "below_version_floor", "handshake_failed",
                "handshake_timeout", "resume_unsupported", "unsupported", "turn_active", "no_active_turn",
                "session_closed", "frame_too_large", "invalid_request", "home_required", "launch", "timeout",
                "vendor_error",
            ])
        for c in codes { #expect(c.wholeMatch(of: /[a-z]+(_[a-z]+)*/) != nil) }
    }
}

/// Uses each public type through the public import only, so an API break fails the build.
@Suite("APISurfaceTests")
struct APISurfaceTests {
    final class Files: FileSystemAccess {
        func readTextFile(_ path: String) async throws -> String { "" }
        func writeTextFile(_ path: String, content: String) async throws {}
    }

    struct Custom: ModelListing, LimitsReading, SelfDetecting {
        var name: String { "custom" }
        func start(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
            _ = runtime.clientName
            _ = runtime.clientVersion
            _ = runtime.maxFrameBytes
            _ = runtime.logger
            _ = runtime.nextID()
            _ = await runtime.childEnvironment([:])
            let bin = try await runtime.resolveBinary(r.harness, override: r.binary)
            _ = await runtime.version(of: bin)
            _ = await runtime.helpText(of: bin)
            _ = await runtime.supportsFlag("--x", binary: bin)
            runtime.track(key: "k", harness: r.harness, pid: 1, pgid: nil, argv: [])
            runtime.untrack(key: "k")
            runtime.onRuntimeClose {}
            throw AgentBinderError.unsupported("custom")
        }
        func resume(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
            throw AgentBinderError.resumeUnsupported
        }
        func models(_ q: ModelQuery, runtime: RuntimeContext) async throws -> [ModelInfo] { [] }
        func readLimits(_ q: ModelQuery, runtime: RuntimeContext) async throws -> Limits { Limits() }
        func detect(runtime: RuntimeContext) async throws -> Detection {
            Detection(
                harness: Harness("custom"), path: nil, version: nil, supported: true, ready: true, auth: .ok,
                authDetail: nil, features: Features(mcpInject: .session, skillsInject: .instructions), detail: nil)
        }
    }

    func uses(_ s: any Session) async throws {
        _ = s.harness
        _ = s.id
        _ = s.pid
        _ = s.lastError
        for await e in s.events {
            _ = (e.kind.name, e.at, e.turn, e.sessionID, e.raw)
            switch e.kind {
            case .initialized, .exit: break
            case .assistant(let t, let d), .thought(let t, let d): _ = (t, d)
            case .user(let t): _ = t
            case .tool(let t): _ = (t.id, t.name, t.kind, t.input, t.output, t.status, t.paths, t.exitCode)
            case .permission(let p):
                _ = (p.id, p.tool, p.kind, p.question, p.input, p.options, p.toolUseID)
                try await s.answer(p.id, .allow(message: nil, updatedInput: nil))
            case .result(let r): _ = (r.subtype, r.isError, r.text, r.sessionID, r.usage, r.endReason, r.code)
            case .error(let w): _ = (w.message, w.code, w.endReason, w.text)
            case .usage(let u): _ = (u.input, u.output, u.cacheRead, u.cacheCreation, u.model, u.costUSD)
            case .status(let st, let t): _ = (st, t)
            case .limits(let l):
                _ = (l.plan, l.rejected, l.windows.map { ($0.key, $0.scope, $0.minutes, $0.usedPercent, $0.resetsAt) })
            }
        }
        let d: Delivery = try await s.send(
            Prompt("x", kind: "followup", attachments: [.file(URL(fileURLWithPath: "/a.png"))]))
        _ = d
        try await s.prompt(Prompt("x", attachments: [.data(Data(), mime: "image/png")]))
        try await s.interrupt()
        if let m = s as? any ModelSettable { try await m.setModel("m") }
        if let m = s as? any SessionModelListing { _ = await m.offeredModels }
        if let m = s as? any Steerable { try await m.steer(Prompt("x")) }
        await s.close()
        await s.kill()
    }

    @Test func surface() async throws {
        let rt = Runtime(
            options: Runtime.Options(
                clientName: "app", clientVersion: "1.0", ledger: nil, logger: nil, fingerprintIgnoreEnvironment: [],
                maxFrameBytes: 1 << 20, onStderr: nil, authCacheTTL: .seconds(1), modelCacheTTL: .seconds(1),
                binarySearchPaths: [], useLoginShellPath: false))
        await rt.setDriver(Custom(), for: Harness("custom"))
        #expect(await rt.driver(for: Harness("custom"))?.name == "custom")
        let det = await rt.detect(Harness("custom"))
        _ = (det.harness, det.path, det.version, det.supported, det.ready, det.auth, det.authDetail, det.detail)
        let f = det.features
        _ = (f.mcpInject, f.skillsInject, f.instructions, f.attachments, f.resume, f.permissions, f.fileSystem)
        _ = (f.models, f.setModel, f.steer)
        _ = await rt.detectAll()
        _ = try await rt.models(Harness("custom"), query: ModelQuery(binary: nil, home: nil, environment: [:]))
        _ = try await rt.limits(Harness("custom"))
        await rt.invalidateModels(.claude)
        await rt.invalidateDetect(.claude)
        await rt.reconcile()

        let r = StartRequest(
            harness: .fake, workingDirectory: URL(fileURLWithPath: "/tmp"), binary: nil, environment: [:], home: nil,
            sessionID: nil, model: "m", effort: .high, instructions: "i",
            permissions: PermissionPolicy(mode: .autoEdit, allowTools: ["Bash"]),
            mcpServers: [
                .stdio(name: "a", command: "x", args: [], env: [:]),
                .http(name: "b", url: URL(string: "https://example.com")!, headers: [:]),
                MCPServer(name: "c", transport: .stdio(command: "x", args: [], env: [:])),
            ],
            skills: [Skill(name: nil, directory: URL(fileURLWithPath: "/tmp"))],
            credentials: Credentials(format: .anthropic, apiKey: "k"), oneShot: OneShot(prompt: "p"),
            handshakeTimeout: .seconds(5), extraArguments: [], baseCommand: nil,
            raw: ["strict_mcp": .bool(true), "sandbox": .string("x")], frameLog: nil, fileSystem: Files(),
            onStderr: { _, _ in })
        #expect(r.rawBool("strict_mcp") == true)
        #expect(r.rawString("sandbox") == "x")
        _ = [Effort.low, .medium, .max]
        await #expect(throws: AgentBinderError.binaryNotFound(Harness("custom"), searched: [])) {
            _ = try await rt.start(StartRequest(harness: Harness("custom"), workingDirectory: r.workingDirectory))
        }

        let tr = Tracker()
        tr.promptWritten()
        let snap: Tracker.Snapshot = tr.observe(Event(.status(.running, text: nil)))
        _ = (snap.state, snap.stalled, Tracker.stallThreshold)

        let c: Classification = Classifier.classify("rate limit exceeded", status: 429, harness: .claude)
        _ = (c.cls, c.code, c.message, FailureClass.limit)
        _ = Classifier.classify(TurnResult(isError: true))
        _ = ShellWords.split("a 'b c'")
        _ = MCPRender.claudeConfig([])
        _ = AuthState.missing
        _ = [Detection.Detail.notInstalled, .belowFloor("1"), .sandboxed, .noDriver]
        _ = [SkillSupport.none, .native, .overlay, .instructions]
        _ = [MCPCapability.none, .flags, .session]
        _ = [SessionStatus.unknown, .running, .waiting, .idle]
        _ = [EndReason.auth, .limit, .entitlement, .overloaded, .protocol, .failed, .launch, .unknown]
        _ = [Delivery.steered, .prompted, .held]
        _ = [ToolStatus.started, .completed, .failed]
        _ = ToolKind.allCases
        _ = Decision.deny("no")
        _ = FakeDriver(script: "true", workingDirectory: nil, modelList: [], steers: true)
        _ = FakeDriver.defaultScript
        _ = AgentBinder.version
        await rt.close()
    }
}
