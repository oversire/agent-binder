import Foundation

/// Drives an Agent Client Protocol agent: Copilot, Cursor or Gemini. It has no version floor.
struct ACPDriver: Driver, ModelListing {
    static let createChatWait: Duration = .seconds(30)

    let variant: ACPVariant

    /// Makes the driver of one agent.
    init(_ variant: ACPVariant) { self.variant = variant }

    /// The name of the driver.
    var name: String { variant.harness.rawValue }

    /// Starts a new session. A Cursor start makes a new chat with `cursor-agent create-chat` first.
    func start(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        try await open(r, runtime, resume: false)
    }

    /// Loads the session in ``StartRequest/sessionID``. It throws ``AgentBinderError/resumeUnsupported``
    /// when the agent cannot load it.
    func resume(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        guard let id = r.sessionID, !id.isEmpty else { throw AgentBinderError.resumeUnsupported }
        return try await open(r, runtime, resume: true)
    }

    private func open(_ r: StartRequest, _ ctx: RuntimeContext, resume: Bool) async throws -> any Session {
        var req = r
        var fresh = false
        if variant == .cursor && !resume {
            // The agent has no method that opens a chat that it does not know.
            req.sessionID = try await Self.createChat(req, ctx)
            fresh = true
        }
        let l = try await launch(req, ctx, resume: resume)
        let adapter = ACPAdapter(config(req, l, ctx, resume: resume, fresh: fresh))
        let wire = try await ctx.startWire(req, l, adapter: adapter)
        if let id = adapter.sessionID { wire.setID(id) }
        // Quirk: stdin closes after session/prompt, so a later permission reply cannot go out.
        // Use a one-shot turn with the auto mode.
        if let one = r.oneShot, !one.prompt.isEmpty {
            do {
                try await wire.prompt(Prompt(one.prompt, kind: "job"))
            } catch {
                await wire.kill()
                throw error
            }
            wire.closeInput()
        }
        return ACPSession(wire: wire, adapter: adapter)
    }

    private func launch(_ r: StartRequest, _ ctx: RuntimeContext, resume: Bool) async throws -> Launch {
        var l = try await ctx.launchBuilder.prepare(r, resume: resume)
        let bin = l.binary
        l.arguments = await variant.arguments(l.arguments) { await ctx.helpText(of: bin) }
        return l
    }

    func config(_ r: StartRequest, _ l: Launch, _ ctx: RuntimeContext, resume: Bool, fresh: Bool) -> ACPConfig {
        var c = ACPConfig(variant: variant)
        c.clientName = ctx.clientName.isEmpty ? "agentbinder" : ctx.clientName
        c.clientVersion = ctx.clientVersion
        c.cwd = r.workingDirectory.path
        c.model = r.model
        // Copilot gets the servers in a launch flag.
        c.mcpServers = variant.harness == .copilot ? [] : r.mcpServers
        c.instructions = l.instructions
        // auth_method is an alias.
        c.authMethod = r.rawString("acp_auth_method") ?? r.rawString("auth_method")
        c.sessionID = r.sessionID
        c.resume = resume
        c.fresh = fresh
        c.handshakeTimeout = r.handshakeTimeout.flatMap { $0 > .zero ? $0 : nil } ?? .seconds(45)
        c.policy = r.permissions
        c.fileSystem = r.fileSystem
        return c
    }

    /// Runs `cursor-agent create-chat` with the parent environment and returns the chat id.
    static func createChat(_ r: StartRequest, _ ctx: RuntimeContext) async throws -> String {
        let bin = try await ctx.resolveBinary(.cursor, override: r.binary)
        let out = await Probe.run(
            bin, ["create-chat"], environment: await ctx.childEnvironment([:]), timeout: createChatWait)
        let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.code == 0 else {
            let why = out.code.map { "exit code \($0)" } ?? "no exit"
            throw AgentBinderError.launch("cursor create-chat: \(why) (\(text))")
        }
        let id = ACPVariant.lastIdentifier(out.text)
        guard !id.isEmpty else { throw AgentBinderError.launch("cursor create-chat returned no chat id") }
        return id
    }

    /// Opens a session with no MCP servers and reads its model list. It never calls `authenticate`,
    /// so a list call cannot start a login.
    func models(_ q: ModelQuery, runtime ctx: RuntimeContext) async throws -> [ModelInfo] {
        let (r, done) = try Probe.request(variant.harness, q)
        defer { done() }
        let l = try await launch(r, ctx, resume: false)
        var c = config(r, l, ctx, resume: false, fresh: false)
        c.mcpServers = []
        let adapter = ACPAdapter(c)
        let probe = ProbeAdapter(
            run: { w in
                adapter.attach(w)
                try await adapter.initialize()
                _ = try await adapter.newSession()
            },
            parse: { adapter.route($0) })
        try await Probe.exchange(r, l, adapter: probe, context: ctx)
        let list = adapter.offeredModels
        guard !list.isEmpty else { throw AgentBinderError.unsupported("\(variant.rawValue) offered no models") }
        return list
    }
}
