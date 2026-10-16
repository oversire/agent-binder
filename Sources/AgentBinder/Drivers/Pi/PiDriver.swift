import Foundation

/// Drives `pi --mode rpc` over NDJSON on stdin and stdout. It has no version floor.
struct PiDriver: Driver, ModelListing {
    /// Makes the driver.
    init() {}

    /// The name of the driver.
    var name: String { Harness.pi.rawValue }

    /// Starts a session. A session id in the request goes to `--session-id`.
    func start(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        try await open(r, runtime, resume: false)
    }

    /// Resumes the session in ``StartRequest/sessionID`` with `--session`.
    func resume(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        guard let id = r.sessionID, !id.isEmpty else {
            throw AgentBinderError.invalidRequest("pi: resume needs a session id")
        }
        return try await open(r, runtime, resume: true)
    }

    private func open(_ r: StartRequest, _ ctx: RuntimeContext, resume: Bool) async throws -> any Session {
        var l = try await ctx.launchBuilder.prepare(r, resume: resume)
        Self.addMode(&l)
        let adapter = PiAdapter(policy: r.permissions, instructions: l.instructions)
        let wire = try await ctx.startWire(r, l, adapter: adapter)
        if let id = r.sessionID, !id.isEmpty { wire.setID(id) }
        if let one = r.oneShot, !one.prompt.isEmpty {
            do {
                try await wire.prompt(Prompt(one.prompt, kind: "job"))
            } catch {
                await wire.kill()
                throw error
            }
            wire.closeInput()
        }
        return PiSession(wire: wire, adapter: adapter)
    }

    static func addMode(_ l: inout Launch) {
        if !LaunchBuilder.hasFlag(l.arguments, "--mode") && !LaunchBuilder.hasFlag(l.arguments, "--rpc") {
            l.arguments += ["--mode", "rpc"]
        }
    }

    /// Runs `pi --mode rpc --no-session`: `get_available_models`, then `get_state` for the default.
    /// The ids are `provider/model`.
    func models(_ q: ModelQuery, runtime ctx: RuntimeContext) async throws -> [ModelInfo] {
        let (r, done) = try Probe.request(.pi, q)
        defer { done() }
        var l = try await ctx.launchBuilder.prepare(r, resume: false)
        defer { l.cleanup() }
        Self.addMode(&l)
        if !LaunchBuilder.hasFlag(l.arguments, "--no-session") { l.arguments.append("--no-session") }
        let adapter = PiAdapter(policy: r.permissions)
        let found = Locked<[ModelInfo]>([])
        let probe = ProbeAdapter(
            run: { w in
                adapter.commands.attach(w)
                var list = try Self.models(try await adapter.commands.request(["type": "get_available_models"]))
                // The default is optional.
                if let state = try? await adapter.commands.request(["type": "get_state"]) {
                    Self.markDefault(&list, state)
                }
                let picked = list
                found.withLock { $0 = picked }
            },
            parse: { _ = adapter.parse($0) })
        try await Probe.exchange(r, l, adapter: probe, context: ctx)
        return found.value
    }

    /// The models of a `get_available_models` data object. Entries with no id or no provider are left out.
    static func models(_ data: JSONValue) throws -> [ModelInfo] {
        guard let list = data["models"]?.array else {
            throw AgentBinderError.invalidRequest("pi get_available_models: decode response: no models array")
        }
        return list.compactMap { m in
            let id = m["id"].stringValue
            let provider = m["provider"].stringValue
            guard !id.isEmpty, !provider.isEmpty else { return nil }
            let window = ModelInfo.contextText(Int(m["contextWindow"]?.double ?? 0))
            return ModelInfo(
                id: provider + "/" + id, name: m["name"]?.string, description: window.isEmpty ? nil : window)
        }
    }

    /// Marks the current model of a `get_state` data object.
    static func markDefault(_ list: inout [ModelInfo], _ state: JSONValue) {
        let id = state.at("model", "id").stringValue
        guard !id.isEmpty else { return }
        let current = state.at("model", "provider").stringValue + "/" + id
        for i in list.indices { list[i].isDefault = list[i].id == current }
    }
}
