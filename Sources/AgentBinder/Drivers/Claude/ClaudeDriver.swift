import Foundation

/// Drives Claude Code 2.0.0 or later over stream-json on stdin and stdout.
struct ClaudeDriver: Driver, ModelListing {
    /// The models that ``models(_:runtime:)`` returns when the CLI offers no list.
    static let aliases = [
        ModelInfo(id: "default", name: "Default", isDefault: true), ModelInfo(id: "opus", name: "Opus"),
        ModelInfo(id: "sonnet", name: "Sonnet"), ModelInfo(id: "haiku", name: "Haiku"),
    ]

    static let wireArguments = ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
    static let inputArguments = ["--input-format", "stream-json"]

    /// Makes the driver.
    init() {}

    /// The name of the driver.
    var name: String { Harness.claude.rawValue }

    /// Starts a new session.
    func start(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        try await open(r, runtime, resume: false)
    }

    /// Resumes the session in ``StartRequest/sessionID``.
    func resume(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        try await open(r, runtime, resume: true)
    }

    private func open(_ r: StartRequest, _ ctx: RuntimeContext, resume: Bool) async throws -> any Session {
        var l = try await Self.prepare(r, ctx, resume: resume)
        l.arguments = Self.arguments(l.arguments, oneShot: r.oneShot != nil)
        let adapter = ClaudeAdapter(policy: r.permissions) { ClaudeAdapter.requestID(ctx.nextID()) }
        let wire = try await ctx.startWire(r, l, adapter: adapter)
        if let id = r.sessionID, !id.isEmpty { wire.setID(id) }
        // Stdin stays open in one-shot mode, because the CLI still asks for permissions.
        if let one = r.oneShot, !one.prompt.isEmpty {
            do {
                try await wire.prompt(Prompt(one.prompt, kind: "job"))
            } catch {
                await wire.kill()
                throw error
            }
        }
        return ClaudeSession(wire: wire, adapter: adapter)
    }

    /// The command line of a session: the wire flags, then the launch arguments.
    ///
    /// Without `--permission-prompt-tool stdio` the CLI answers prompts itself and never sends
    /// `can_use_tool`, so a base command gets it too, and the inherit mode keeps it.
    static func arguments(_ launch: [String], oneShot: Bool) -> [String] {
        var args = wireArguments + inputArguments
        if oneShot { args.append("--print") }
        args += launch
        if !LaunchBuilder.hasFlag(args, "--permission-prompt-tool") { args += ["--permission-prompt-tool", "stdio"] }
        return args
    }

    // A base command also gets the version check.
    private static func prepare(_ r: StartRequest, _ ctx: RuntimeContext, resume: Bool) async throws -> Launch {
        let l = try await ctx.launchBuilder.prepare(r, resume: resume)
        do {
            try await checkVersion(l.binary, ctx)
        } catch {
            l.cleanup()
            throw error
        }
        return l
    }

    static func checkVersion(_ bin: URL, _ ctx: RuntimeContext) async throws {
        let floor = Runtime.versionFloor(.claude) ?? "2.0.0"
        guard let v = await ctx.version(of: bin), !v.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AgentBinderError.launch(
                "claude: cannot determine --version for \(bin.path); pin a CLI >= \(floor) or use another runtime")
        }
        guard semverAtLeast(v, floor) else {
            throw AgentBinderError.belowVersionFloor(.claude, version: firstToken(v), floor: floor)
        }
    }

    /// Asks a short-lived CLI for the models of its `initialize` reply. An empty list gives ``aliases``.
    ///
    /// The probe always runs in a new temp folder and ignores ``ModelQuery/workingDirectory``, so a
    /// project config cannot change the list. It has no partial messages and loads no user MCP servers.
    func models(_ q: ModelQuery, runtime ctx: RuntimeContext) async throws -> [ModelInfo] {
        var query = q
        query.workingDirectory = nil
        let (r, done) = try Probe.request(.claude, query)
        defer { done() }
        var l = try await Self.prepare(r, ctx, resume: false)
        l.arguments = Array(Self.wireArguments.dropLast()) + Self.inputArguments + l.arguments + ["--strict-mcp-config"]
        let adapter = ClaudeAdapter(policy: PermissionPolicy()) { ClaudeAdapter.requestID(ctx.nextID()) }
        let found = Locked<[ModelInfo]>([])
        let probe = ProbeAdapter(
            run: { w in
                adapter.attach(w)
                let res = try await adapter.control(["subtype": "initialize", "hooks": .null])
                found.withLock { $0 = ClaudeFrames.models(res) ?? [] }
            },
            parse: { _ = adapter.parse($0) })
        try await Probe.exchange(r, l, adapter: probe, context: ctx)
        let list = found.value
        return list.isEmpty ? Self.aliases : list
    }
}
