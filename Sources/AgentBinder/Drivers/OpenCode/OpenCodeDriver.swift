import Foundation

/// Drives `opencode serve` over REST and its event stream. Sessions with the same fingerprint share
/// one server.
///
/// The `opencode` harness reads `--version`: a 2.x binary gets the 2.x wire, and its sessions report
/// `opencode2`. The `opencode2` harness always uses the 2.x wire. Neither has a version floor.
struct OpenCodeDriver: Driver, ModelListing {
    static let modelPollWait: Duration = .seconds(10)

    let harness: Harness

    init(_ harness: Harness) { self.harness = harness }

    var name: String { harness.rawValue }

    func start(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        try await open(r, runtime, resume: false)
    }

    func resume(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        guard let id = r.sessionID, !id.isEmpty else {
            throw AgentBinderError.invalidRequest("\(harness): resume needs a session id")
        }
        return try await open(r, runtime, resume: true)
    }

    func wire(_ binary: URL, _ ctx: RuntimeContext) async -> OpenCodeWire {
        harness == .opencode2 ? .v2 : OpenCodeWire(versionLine: await ctx.version(of: binary))
    }

    private func open(_ r: StartRequest, _ ctx: RuntimeContext, resume: Bool) async throws -> any Session {
        let l = try await ctx.launchBuilder.prepare(r, resume: resume)
        let w = await wire(l.binary, ctx)
        let lease: OpenCodeLease
        do {
            lease = try await OpenCodeLease.acquire(w, l, ctx)
        } catch {
            l.cleanup()
            throw error
        }
        let s: any OpenCodeOpened
        do {
            // Quirk: the server does not replay events from before the stream connects.
            // Fixed on purpose: a stream that does not connect fails the start.
            try await lease.server.ensureStreamReady(r.workingDirectory.path)
            s =
                w == .v1
                ? try await OpenCodeOpen.v1(r, l, lease, resume: resume)
                : try await OpenCodeOpen.v2(r, l, lease, resume: resume, environment: ctx.environment)
        } catch {
            lease.release()
            l.cleanup()
            throw error
        }
        s.onClose(l.cleanup)
        if let one = r.oneShot, !one.prompt.isEmpty {
            s.endAfterTurn()
            do {
                try await s.prompt(Prompt(one.prompt, kind: "job"))
            } catch {
                await s.kill()
                throw error
            }
        }
        return s
    }

    // MARK: models

    /// Asks a server: `/config/providers` on 1.x, `/api/model` on 2.x. On 1.x a server that does not
    /// start falls back to `opencode models`.
    func models(_ q: ModelQuery, runtime ctx: RuntimeContext) async throws -> [ModelInfo] {
        let (r, done) = try Probe.request(harness, q)
        defer { done() }
        let l = try await ctx.launchBuilder.prepare(r, resume: false)
        defer { l.cleanup() }
        let w = await wire(l.binary, ctx)
        let dir = r.workingDirectory.path
        let lease: OpenCodeLease
        do {
            lease = try await OpenCodeLease.acquire(w, l, ctx)
        } catch {
            guard w == .v1 else { throw error }
            let list = await Self.cliModels(l, ctx, directory: r.workingDirectory)
            if list.isEmpty { throw error }
            return list.sorted { $0.id < $1.id }
        }
        defer { lease.release() }
        let list =
            w == .v1 ? try await Self.v1Models(lease.server.http, dir) : try await Self.v2Models(lease.server.http, dir)
        return list.sorted { $0.id < $1.id }
    }

    static func v1Models(_ http: OpenCodeHTTP, _ dir: String) async throws -> [ModelInfo] {
        let providers = try await http.call("GET", "/config/providers", directory: dir)
        let config = try? await http.call("GET", "/config", directory: dir)
        return v1Models(providers: providers, config: config)
    }

    /// The models of `/config/providers`. The default is the model of `/config`; the default map of
    /// the providers reply is not used.
    static func v1Models(providers: JSONValue, config: JSONValue?) -> [ModelInfo] {
        var out: [ModelInfo] = []
        for p in providers["providers"]?.array ?? [] {
            let pid = p["id"].stringValue
            for (key, m) in p["models"]?.object ?? [:] {
                let mid = m["id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? key
                let name = [m["name"].stringValue, m["id"].stringValue, key].first { !$0.isEmpty }
                let note = [p["name"].stringValue, ModelInfo.contextText(Int(m.at("limit", "context")?.double ?? 0))]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                out.append(ModelInfo(id: pid + "/" + mid, name: name, description: note.isEmpty ? nil : note))
            }
        }
        if let d = config.flatMap(configModel) {
            for i in out.indices { out[i].isDefault = out[i].id == d }
        }
        return out
    }

    /// The `model` of a config: a string, or an object `{providerID, model}`.
    static func configModel(_ c: JSONValue) -> String? {
        guard let m = c["model"] else { return nil }
        if let s = m.string { return s.isEmpty ? nil : s }
        let model = m["model"].stringValue
        guard !model.isEmpty else { return nil }
        let p = m["providerID"].stringValue
        return p.isEmpty ? model : p + "/" + model
    }

    // Quirk: a new server loads its catalog after it is ready, and answers an empty list first.
    static func v2Models(
        _ http: OpenCodeHTTP, _ dir: String, wait: Duration = modelPollWait
    ) async throws
        -> [ModelInfo]
    {
        let q = [URLQueryItem(name: "location[directory]", value: dir)]
        let end = ContinuousClock.now + wait
        var list = try await http.call("GET", "/model", query: q)
        while (list.array ?? []).isEmpty && ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(500))
            list = try await http.call("GET", "/model", query: q)
        }
        let def = try? await http.call("GET", "/model/default", query: q)
        return v2Models(list: list, default: def)
    }

    /// The enabled models of `/api/model`. The default is the reply of `/api/model/default`.
    static func v2Models(list: JSONValue, default def: JSONValue?) -> [ModelInfo] {
        func id(_ m: JSONValue) -> String {
            let mid = [m["modelID"].stringValue, m["id"].stringValue].first { !$0.isEmpty } ?? ""
            let p = m["providerID"].stringValue
            return p.isEmpty ? mid : p + "/" + mid
        }
        let defID = def.flatMap { d in
            [d["modelID"].stringValue, d["id"].stringValue].contains { !$0.isEmpty } ? id(d) : nil
        }
        return (list.array ?? []).compactMap { m in
            guard m["enabled"]?.bool != false else { return nil }
            let i = id(m)
            guard !i.isEmpty else { return nil }
            let name = [m["name"].stringValue, m["modelID"].stringValue, m["id"].stringValue].first { !$0.isEmpty }
            let note = ModelInfo.contextText(Int(m.at("limit", "context")?.double ?? 0))
            return ModelInfo(id: i, name: name, description: note.isEmpty ? nil : note, isDefault: i == defID)
        }
    }

    /// The lines of `opencode models` that look like `provider/model`.
    static func cliModels(_ l: Launch, _ ctx: RuntimeContext, directory: URL) async -> [ModelInfo] {
        let out = await Probe.run(
            l.binary, ["models"], environment: await ctx.childEnvironment(l.environment), timeout: .seconds(15),
            directory: directory)
        guard out.code == 0 else { return [] }
        return cliModels(out.text)
    }

    static func cliModels(_ text: String) -> [ModelInfo] {
        text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let halves = line.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard halves.count == 2, !halves[0].isEmpty, !halves[1].isEmpty, !line.contains(where: \.isWhitespace)
            else { return nil }
            return ModelInfo(id: line)
        }
    }
}

/// One reference on a pooled server. ``release()`` runs once.
struct OpenCodeLease: Sendable {
    let server: OpenCodeServer
    let release: @Sendable () -> Void

    // Fixed on purpose: the launch arguments (extra arguments, base command arguments) reach `serve`.
    static func acquire(_ w: OpenCodeWire, _ l: Launch, _ ctx: RuntimeContext) async throws -> OpenCodeLease {
        let pool = ctx.openCode
        let s = try await pool.acquire(
            w, binary: l.binary, environment: l.environment, arguments: l.arguments, context: ctx)
        let once = Locked(false)
        return OpenCodeLease(server: s) {
            let first = once.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if first { Task { await pool.release(s) } }
        }
    }
}

/// The session surface that the driver needs after the open.
protocol OpenCodeOpened: Session, CloseObserving {
    func endAfterTurn()
}

extension OpenCodeSession: OpenCodeOpened {}

/// The create and resume sequences of each wire.
enum OpenCodeOpen {
    static func v1(
        _ r: StartRequest, _ l: Launch, _ lease: OpenCodeLease, resume: Bool
    ) async throws
        -> OpenCodeV1Session
    {
        let http = lease.server.http
        let dir = r.workingDirectory.path
        let id = try await sessionID(r, http, dir, resume: resume, create: [:])
        let s = OpenCodeV1Session(
            id: id,
            dialect: OpenCodeV1Dialect(
                sessionID: id, directory: dir, model: r.model, effort: r.effort?.rawValue, instructions: l.instructions),
            server: lease.server, policy: r.permissions, release: lease.release)
        s.markLive()
        return s
    }

    /// V2 needs an explicit model on create: a provider default with a dead credential fails each turn.
    /// So the request model, else the model of the operator config, goes in the create body.
    static func v2(
        _ r: StartRequest, _ l: Launch, _ lease: OpenCodeLease, resume: Bool, environment: [String: String]
    ) async throws -> OpenCodeV2Session {
        let http = lease.server.http
        let dir = r.workingDirectory.path
        let effort = r.effort?.rawValue
        var create: [String: JSONValue] = ["location": ["directory": .string(dir)]]
        let model = r.model ?? OpenCodeV2Dialect.operatorModel(environment: environment.merging(l.environment) { $1 })
        if let ref = OpenCodeV2Dialect.modelRef(model, variant: effort) { create["model"] = ref }
        let id = try await sessionID(r, http, dir, resume: resume, create: .object(create))
        let s = OpenCodeV2Session(
            id: id, dialect: OpenCodeV2Dialect(sessionID: id, directory: dir, variant: effort), server: lease.server,
            policy: r.permissions, release: lease.release)
        // Quirk: session.created comes during the create call, before the session is routable.
        s.markLive()
        do {
            try await http.callFirstFound(OpenCodeV2Dialect.instructionsCalls(id, l.instructions))
            if resume, let c = OpenCodeV2Dialect.setModelCall("/session/\(id)", r.model ?? "", effort) {
                try await http.call(c)
            }
        } catch {
            await s.kill()
            throw error
        }
        return s
    }

    private static func sessionID(
        _ r: StartRequest, _ http: OpenCodeHTTP, _ dir: String, resume: Bool, create: JSONValue
    ) async throws -> String {
        let h = http.wire.harness
        if resume, let id = r.sessionID {
            do {
                try await http.call("GET", "/session/\(id)", directory: dir)
            } catch {
                throw AgentBinderError.resumeUnsupported
            }
            return id
        }
        let v: JSONValue
        do {
            v = try await http.call("POST", "/session", directory: dir, body: create)
        } catch {
            throw AgentBinderError.handshakeFailed("\(h) session create: \(error)")
        }
        let id = v["id"].stringValue
        guard !id.isEmpty else { throw AgentBinderError.handshakeFailed("\(h): session has no id") }
        return id
    }
}
