import AgentBinder
import Foundation

/// The driver of the in-process harness `Harness.native`.
///
/// Register it with `runtime.setDriver(NativeDriver(config), for: .native)`. A session runs the model
/// loop in this process: it needs no CLI and no child process.
public final class NativeDriver: SelfDetecting {
    /// The driver name.
    public let name = "native"
    let config: NativeConfig

    private struct State {
        var closed = false
        var seq = 0
        var owned: [Int: [any ToolSet]] = [:]
    }

    private let state = Locked(State())

    /// Makes a driver.
    public init(_ config: NativeConfig) { self.config = config }

    /// Opens a new session. A request with no session id gets a new id.
    public func start(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        try await open(r, id: r.sessionID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased(), runtime)
    }

    /// Opens a session with its stored history.
    public func resume(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        guard let id = r.sessionID, !id.isEmpty else {
            throw AgentBinderError.invalidRequest("native session needs a session id")
        }
        return try await open(r, id: id, runtime)
    }

    /// Reports the credential state. The harness is always supported.
    public func detect(runtime: RuntimeContext) async throws -> Detection {
        var d = Detection(harness: .native, supported: true, auth: .ok)
        guard let resolve = config.credentials else { return d }
        do {
            if try await resolve().apiKey.isEmpty {
                d.auth = .missing
                d.authDetail = "no API key"
            }
        } catch {
            d.auth = .missing
            d.authDetail = String(describing: error)
        }
        return d
    }

    /// Closes the tool sets of each open session and refuses new sessions.
    public func close() async {
        let sets = state.withLock { s -> [any ToolSet] in
            s.closed = true
            defer { s.owned = [:] }
            return s.owned.values.flatMap { $0 }
        }
        for t in sets { await t.close() }
    }

    // MARK: open

    private func open(_ r: StartRequest, id: String, _ ctx: RuntimeContext) async throws -> any Session {
        if state.value.closed { throw NativeError.config("native driver is closed") }
        let creds: Credentials
        if let c = r.credentials {
            creds = c
        } else if let resolve = config.credentials {
            creds = try await resolve()
        } else {
            throw NativeError.config("native session needs credentials")
        }
        let model = try config.newModel(creds, r.model)

        var owned: [any ToolSet] = []
        func fail(_ e: any Error) async -> any Error {
            for t in owned { await t.close() }
            return e
        }
        var sets = config.toolSets
        do {
            for f in config.toolSetFactories {
                let t = try await f()
                owned.append(t)
                sets.append(t)
            }
            let parent = await ctx.childEnvironment([:])
            for m in r.mcpServers {
                let t = try await MCPToolSet.connect(m, environment: parent)
                owned.append(t)
                sets.append(t)
            }
            if config.builtinTools {
                var env = await ctx.childEnvironment(r.environment)
                // A command must not read the provider keys of the host, unless the request sets them.
                for k in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"] where r.environment[k] == nil { env[k] = nil }
                let t = FileTools(root: r.workingDirectory, environment: env, maxFileBytes: config.maxFileBytes)
                owned.append(t)
                sets.append(t)
            }
        } catch {
            throw await fail(error)
        }

        var table = ToolTable()
        do {
            for s in sets {
                do {
                    for t in try await s.tools() { table.add(t) }
                } catch {
                    throw NativeError.config("native: toolset \(s.name): \(error)")
                }
            }
        } catch {
            throw await fail(error)
        }

        let catalog: SkillCatalog
        do {
            catalog = try SkillCatalog(r.skills)
        } catch {
            throw await fail(error)
        }
        // Changed on purpose: activate_skill is there only when there are skills.
        if let t = catalog.tool { table.add(t) }
        let system = [r.instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", catalog.prompt]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")

        var history: [Message] = []
        if let store = config.store {
            do {
                history = try await store.load(id)
            } catch let e as NativeError where e == .notFound {
                history = []
            } catch {
                throw await fail(error)
            }
        }

        let mine = owned
        let key = state.withLock { s -> Int in
            s.seq += 1
            s.owned[s.seq] = mine
            return s.seq
        }
        let s = NativeSession(
            id: id, model: model, tools: table, system: system, history: history, config: config,
            permissions: r.permissions, effort: r.effort?.rawValue ?? ""
        ) { [weak self] in
            let sets = self?.state.withLock { $0.owned.removeValue(forKey: key) } ?? []
            for t in sets { await t.close() }
        }
        s.start()
        if let one = r.oneShot { try await s.oneShot(Prompt(one.prompt)) }
        return s
    }
}

/// The tools of a session by name. A later tool with the same name wins, and the order stays stable
/// for prompt caching.
struct ToolTable: Sendable {
    private(set) var tools: [any Tool] = []
    private var index: [String: Int] = [:]

    // Fixed on purpose: the specs keep the insertion order, so the request bytes are stable.
    mutating func add(_ t: any Tool) {
        if let i = index[t.spec.name] {
            tools[i] = t
        } else {
            index[t.spec.name] = tools.count
            tools.append(t)
        }
    }

    subscript(name: String) -> (any Tool)? { index[name].map { tools[$0] } }

    var specs: [ToolSpec] { tools.map(\.spec) }
}
