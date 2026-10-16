import Foundation

/// Renders MCP servers into the launch shape of each harness.
///
/// The servers of the user always stay loaded: the servers of a session are an addition.
public enum MCPRender {
    /// The Claude and pi config file text: `{"mcpServers": {...}}`.
    public static func claudeConfig(_ servers: [MCPServer]) -> String {
        JSONValue.object(["mcpServers": claudeServers(servers)]).prettyString + "\n"
    }

    /// The Codex `-c mcp_servers.<name>...` overrides.
    ///
    /// They never hold a secret value. A stdio server lists its env keys in `env_vars`, and an HTTP
    /// server maps each header to an env var in `env_http_headers`. The process must carry
    /// ``codexEnvironment(_:)``.
    public static func codexArguments(_ servers: [MCPServer]) -> [String] {
        var args: [String] = []
        for s in servers where !s.name.isEmpty {
            let prefix = "mcp_servers.\(s.name)."
            switch s.transport {
            case .http(let url, let headers):
                args += ["-c", prefix + "url=" + toml(url.absoluteString)]
                if !headers.isEmpty {
                    let table = headers.keys.sorted().map { toml($0) + " = " + toml(headerVariable(s.name, $0)) }
                    args += ["-c", prefix + "env_http_headers={" + table.joined(separator: ", ") + "}"]
                }
            case .stdio(let command, let a, let env):
                guard !command.isEmpty else { continue }
                args += ["-c", prefix + "command=" + toml(command)]
                if !a.isEmpty { args += ["-c", prefix + "args=" + tomlList(a)] }
                if !env.isEmpty { args += ["-c", prefix + "env_vars=" + tomlList(env.keys.sorted())] }
            }
        }
        return args
    }

    /// The env that the Codex process must carry for ``codexArguments(_:)``.
    ///
    /// Codex has one process env, so two servers that set one key to two values throw.
    public static func codexEnvironment(_ servers: [MCPServer]) throws -> [String: String] {
        var env: [String: String] = [:]
        func set(_ k: String, _ v: String) throws {
            if let prev = env[k], prev != v {
                throw AgentBinderError.invalidRequest("codex MCP env \(k) has two different values")
            }
            env[k] = v
        }
        for s in servers where !s.name.isEmpty {
            switch s.transport {
            case .http(_, let headers):
                for (h, v) in headers { try set(headerVariable(s.name, h), v) }
            case .stdio(let command, _, let e):
                guard !command.isEmpty else { continue }
                for (k, v) in e { try set(k, v) }
            }
        }
        return env
    }

    /// The value of `OPENCODE_CONFIG_CONTENT` that carries the servers.
    public static func openCodeConfigContent(_ servers: [MCPServer]) -> String {
        var mcp: [String: JSONValue] = [:]
        for s in servers where !s.name.isEmpty {
            switch s.transport {
            case .http(let url, let headers):
                var e: [String: JSONValue] = ["type": "remote", "url": .string(url.absoluteString)]
                if !headers.isEmpty { e["headers"] = strings(headers) }
                mcp[s.name] = .object(e)
            case .stdio(let command, let args, let env):
                guard !command.isEmpty else { continue }
                var e: [String: JSONValue] = [
                    "type": "local", "command": .array(([command] + args).map(JSONValue.string)),
                ]
                if !env.isEmpty { e["environment"] = strings(env) }
                mcp[s.name] = .object(e)
            }
        }
        return JSONValue.object(["mcp": .object(mcp)]).jsonString
    }

    /// The OpenCode config content with a `permission` block. A nil block gives the MCP part only.
    static func openCodeConfigContent(_ servers: [MCPServer], permission: JSONValue?) -> String {
        guard let permission, var v = JSONValue.parse(Data(openCodeConfigContent(servers).utf8))?.object else {
            return openCodeConfigContent(servers)
        }
        v["permission"] = permission
        return JSONValue.object(v).jsonString
    }

    /// The Copilot `--additional-mcp-config` file. Each server needs a `type` and a `tools` list.
    static func copilotConfig(_ servers: [MCPServer]) -> String {
        let all = claudeServers(servers).object ?? [:]
        let out = all.mapValues { v -> JSONValue in
            guard var e = v.object else { return v }
            e["type"] = e["type"] ?? "local"
            e["tools"] = ["*"]
            return .object(e)
        }
        return JSONValue.object(["mcpServers": .object(out)]).prettyString + "\n"
    }

    /// The name of the env var that carries one header value, for example
    /// `AGENTBINDER_MCP_GITHUB_AUTHORIZATION`.
    public static func headerVariable(_ server: String, _ header: String) -> String {
        "AGENTBINDER_MCP_" + envWord(server) + "_" + envWord(header)
    }

    // MARK: internal shapes

    /// The value of the `mcpServers` key for Claude and pi.
    static func claudeServers(_ servers: [MCPServer]) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for s in servers where !s.name.isEmpty {
            switch s.transport {
            case .http(let url, let headers):
                var e: [String: JSONValue] = ["type": "http", "url": .string(url.absoluteString)]
                if !headers.isEmpty { e["headers"] = strings(headers) }
                out[s.name] = .object(e)
            case .stdio(let command, let args, let env):
                guard !command.isEmpty else { continue }
                var e: [String: JSONValue] = ["command": .string(command)]
                if !args.isEmpty { e["args"] = .array(args.map(JSONValue.string)) }
                if !env.isEmpty { e["env"] = strings(env) }
                out[s.name] = .object(e)
            }
        }
        return .object(out)
    }

    /// The ACP `mcpServers` parameter. HTTP servers go only to an agent with `mcpCapabilities.http`.
    static func acpServers(_ servers: [MCPServer], http: Bool) -> JSONValue {
        var out: [JSONValue] = []
        func pairs(_ m: [String: String]) -> JSONValue {
            .array(m.keys.sorted().map { ["name": .string($0), "value": .string(m[$0]!)] })
        }
        for s in servers where !s.name.isEmpty {
            switch s.transport {
            case .http(let url, let headers):
                guard http else { continue }
                out.append(
                    [
                        "name": .string(s.name), "type": "http", "url": .string(url.absoluteString),
                        "headers": pairs(headers),
                    ])
            case .stdio(let command, let args, let env):
                guard !command.isEmpty else { continue }
                // Quirk: Gemini rejects a stdio server without `env`. The ACP schema requires `args` and `env`.
                out.append(
                    [
                        "name": .string(s.name), "command": .string(command),
                        "args": .array(args.map(JSONValue.string)),
                        "env": pairs(env),
                    ])
            }
        }
        return .array(out)
    }

    private static func strings(_ m: [String: String]) -> JSONValue {
        .object(m.mapValues(JSONValue.string))
    }

    // JSON string escapes are a superset of the TOML basic-string escapes, so JSON text is valid TOML.
    private static func toml(_ s: String) -> String { JSONValue.quote(s) }

    private static func tomlList(_ v: [String]) -> String {
        "[" + v.map(toml).joined(separator: ", ") + "]"
    }

    private static func envWord(_ s: String) -> String {
        String(
            s.unicodeScalars.map { u -> Character in
                switch u {
                case "A"..."Z", "0"..."9": return Character(u)
                case "a"..."z": return Character(UnicodeScalar(u.value - 32)!)
                default: return "_"
                }
            })
    }
}
