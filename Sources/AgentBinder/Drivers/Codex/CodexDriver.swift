import Foundation

/// Drives `codex app-server` over JSON-RPC 2.0 on stdin and stdout. It has no version floor.
struct CodexDriver: Driver, ModelListing, LimitsReading {
    static let modelPageWait: Duration = .seconds(20)
    static let limitsWait: Duration = .seconds(15)
    static let maxModelPages = 50

    /// Makes the driver.
    init() {}

    /// The name of the driver.
    var name: String { Harness.codex.rawValue }

    /// Starts a new thread. A session id in the request is not sent: the server picks the thread id.
    func start(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        var req = r
        req.sessionID = nil
        return try await open(req, runtime, resume: false)
    }

    /// Resumes the thread in ``StartRequest/sessionID``.
    func resume(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        guard let id = r.sessionID, !id.isEmpty else {
            throw AgentBinderError.invalidRequest("codex: resume needs a session id")
        }
        return try await open(r, runtime, resume: true)
    }

    private func open(_ r: StartRequest, _ ctx: RuntimeContext, resume: Bool) async throws -> any Session {
        var l = try await ctx.launchBuilder.prepare(r, resume: resume)
        l.arguments.append("app-server")
        let adapter = CodexAdapter(Self.config(r, l, ctx))
        let wire = try await ctx.startWire(r, l, adapter: adapter)
        wire.onClose(adapter.cleanup)
        if let id = adapter.threadID { wire.setID(id) }
        if let one = r.oneShot, !one.prompt.isEmpty {
            do {
                try await wire.prompt(Prompt(one.prompt, kind: "job"))
            } catch {
                await wire.kill()
                throw error
            }
            wire.closeInput()
        }
        return CodexSession(wire: wire, adapter: adapter)
    }

    static func config(_ r: StartRequest, _ l: Launch, _ ctx: RuntimeContext) -> CodexConfig {
        var c = CodexConfig()
        c.clientName = ctx.clientName.isEmpty ? "agentbinder" : ctx.clientName
        c.clientVersion = ctx.clientVersion
        c.model = r.model
        c.effort = r.effort?.rawValue
        c.cwd = r.workingDirectory.path
        // An unattended library must not give the child the whole disk.
        c.approvalPolicy = r.rawString("approvalPolicy") ?? r.permissions.codexApprovalPolicy
        c.sandbox = r.rawString("sandbox") ?? "workspace-write"
        c.resumeID = l.resume ? r.sessionID : nil
        c.instructions = l.instructions
        c.handshakeTimeout = r.handshakeTimeout.flatMap { $0 > .zero ? $0 : nil } ?? .seconds(30)
        c.policy = r.permissions
        return c
    }

    /// Lists the models of `model/list`, page by page. Hidden models are left out.
    func models(_ q: ModelQuery, runtime ctx: RuntimeContext) async throws -> [ModelInfo] {
        let found = Locked<[ModelInfo]>([])
        try await probe(q, ctx) { peer in
            var cursor: String?
            for _ in 0..<Self.maxModelPages {
                let params: JSONValue = cursor.map { ["cursor": .string($0)] } ?? [:]
                let page = try await CodexAdapter.call(peer, "model/list", params, timeout: Self.modelPageWait)
                guard let data = page["data"]?.array else {
                    throw AgentBinderError.invalidRequest("codex model/list: decode response: no data array")
                }
                let list = data.compactMap { m -> ModelInfo? in
                    let id = [m["model"].stringValue, m["id"].stringValue].first { !$0.isEmpty }
                    guard let id, m["hidden"]?.bool != true else { return nil }
                    return ModelInfo(
                        id: id, name: m["displayName"]?.string, description: m["description"]?.string,
                        isDefault: m["isDefault"]?.bool ?? false)
                }
                found.withLock { $0 += list }
                cursor = page["nextCursor"]?.string
                if (cursor ?? "").isEmpty { break }
            }
        }
        return found.value
    }

    /// Reads `account/rateLimits/read`. Unlike the live session, an error reply throws.
    func readLimits(_ q: ModelQuery, runtime ctx: RuntimeContext) async throws -> Limits {
        let found = Locked(Limits())
        try await probe(q, ctx) { peer in
            let body = try await CodexAdapter.call(
                peer, "account/rateLimits/read", ["excludeResetCreditDetails": true], timeout: Self.limitsWait)
            if let l = Limits(codex: body) { found.withLock { $0 = l } }
        }
        return found.value
    }

    // One short-lived app-server: initialize, initialized, then the body.
    private func probe(
        _ q: ModelQuery, _ ctx: RuntimeContext, _ body: @escaping @Sendable (JSONRPCPeer) async throws -> Void
    ) async throws {
        let (r, done) = try Probe.request(.codex, q)
        defer { done() }
        var l = try await ctx.launchBuilder.prepare(r, resume: false)
        l.arguments.append("app-server")
        let info = Self.config(r, l, ctx).clientInfo
        let peer = JSONRPCPeer()
        let adapter = ProbeAdapter(
            run: { w in
                peer.attach(w)
                try await CodexAdapter.call(peer, "initialize", info, timeout: Self.modelPageWait)
                try await peer.notify("initialized", params: [:])
                try await body(peer)
            },
            parse: { _ = peer.handle($0) })
        try await Probe.exchange(r, l, adapter: adapter, context: ctx)
    }
}
