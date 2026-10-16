import Foundation

/// One prepared child command.
///
/// A driver adds its protocol arguments and starts the process. The protocol half of a session
/// (`thread/start`, `POST /session`, `session/new`) belongs to the driver.
struct Launch: Sendable, Equatable {
    var binary: URL
    var arguments: [String]
    var environment: [String: String]
    /// The temp folders that the session close removes.
    var tempPaths: [URL] = []
    /// The text that the driver sends on the wire. It is nil when a flag took it.
    var instructions: String?
    /// True for the resume form, for drivers that change protocol methods.
    var resume: Bool

    /// Removes the temp folders.
    func cleanup() {
        for p in tempPaths { try? FileManager.default.removeItem(at: p) }
    }
}

/// Finds the executable of a harness.
protocol BinaryResolving: Sendable {
    func resolve(_ name: String, harness: Harness, override: URL?) async throws -> URL
}

extension BinaryResolver: BinaryResolving {}

/// Tells if a CLI lists a flag in its `--help` text.
protocol FlagProbing: Sendable {
    func supportsFlag(_ binary: URL, _ flag: String) async -> Bool
}

/// Turns a ``StartRequest`` into a ``Launch``: the binary, the harness flags, the child environment
/// and the temp paths.
struct LaunchBuilder: Sendable {
    /// The client name in the vendor markers, for example `"agentbinder"`.
    var clientName: String
    var resolver: any BinaryResolving
    var flags: any FlagProbing

    init(clientName: String = "agentbinder", resolver: any BinaryResolving, flags: any FlagProbing) {
        self.clientName = clientName.isEmpty ? "agentbinder" : clientName
        self.resolver = resolver
        self.flags = flags
    }

    /// Builds the child command. A ``StartRequest/baseCommand`` skips the whole builder.
    ///
    /// On an error it removes the temp folders that it made.
    func prepare(_ req: StartRequest, resume: Bool) async throws -> Launch {
        if let base = req.baseCommand, !base.isEmpty {
            guard !base[0].trimmingCharacters(in: .whitespaces).isEmpty else {
                throw AgentBinderError.invalidRequest("\(req.harness): empty base command")
            }
            return Launch(
                binary: URL(fileURLWithPath: base[0]), arguments: Array(base.dropFirst()),
                environment: req.environment, resume: resume)
        }
        let bin = try await resolver.resolve(req.harness.binaryName, harness: req.harness, override: req.binary)
        var l = Launch(binary: bin, arguments: [], environment: req.environment, resume: resume)
        do {
            addClientEnvironment(req, &l)
            addHomeEnvironment(req, &l)
            addSessionArguments(req, &l)
            addModelAndEffort(req, &l)
            addPermissionArguments(req, &l)
            try addMCPServers(req, &l)
            addOpenCodeConfig(req, &l)
            let index = try await addSkills(req, &l)
            await addInstructions(req, &l, Instructions.join(req.instructions, skillIndex: index))
        } catch {
            l.cleanup()
            throw error
        }
        l.arguments += req.extraArguments
        return l
    }

    // The vendor sees an SDK-class client, never the plain CLI, because the stream-json wire is the SDK wire.
    private func addClientEnvironment(_ req: StartRequest, _ l: inout Launch) {
        guard req.harness == .claude else { return }
        l.environment["CLAUDE_CODE_ENTRYPOINT"] = clientName + "-cli"
        l.environment["CLAUDE_AGENT_SDK_VERSION"] = clientName + "-cli/1"
    }

    // No home changes nothing: the login, MCP servers and skills of the user stay visible.
    private func addHomeEnvironment(_ req: StartRequest, _ l: inout Launch) {
        guard let home = req.home?.path else { return }
        switch req.harness {
        case .claude:
            l.environment["CLAUDE_CONFIG_DIR"] = home
            // An empty value keeps the default credential store (the Keychain) while the config is isolated.
            if req.rawBool("shared_auth") == true { l.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = "" }
            l.environment["DISABLE_AUTOUPDATER"] = "1"
            l.environment["DISABLE_UPDATES"] = "1"
        case .codex:
            l.environment["CODEX_HOME"] = home
        case .opencode, .opencode2:
            l.environment["OPENCODE_CONFIG_DIR"] = home
        case .pi:
            l.environment["PI_CODING_AGENT_DIR"] = home
            // An isolated home must never update itself during a run.
            l.environment["PI_SKIP_VERSION_CHECK"] = "1"
            l.environment["PI_TELEMETRY"] = "0"
        case .cursor:
            l.environment["CURSOR_CONFIG_DIR"] = home
            l.environment["CURSOR_DATA_DIR"] = home
        default: break
        }
    }

    // Codex, OpenCode, Gemini and the ACP agents take the id on the wire.
    private func addSessionArguments(_ req: StartRequest, _ l: inout Launch) {
        guard let id = req.sessionID, !id.isEmpty else { return }
        switch req.harness {
        case .claude: l.arguments.append(l.resume ? "--resume=\(id)" : "--session-id=\(id)")
        case .pi: l.arguments += l.resume ? ["--session", id] : ["--session-id", id]
        case .copilot where l.resume: l.arguments += ["--resume", id]
        default: break
        }
    }

    private func addModelAndEffort(_ req: StartRequest, _ l: inout Launch) {
        if let model = req.model, !model.isEmpty {
            switch req.harness {
            case .claude, .pi, .copilot, .gemini: l.arguments += ["--model", model]
            default: break
            }
        }
        guard let effort = req.effort?.rawValue, !effort.isEmpty else { return }
        switch req.harness {
        case .claude, .pi, .copilot: l.arguments += ["--effort", effort]
        case .codex: l.arguments += ["-c", "model_reasoning_effort=\(effort)"]
        default: break
        }
    }

    private func addPermissionArguments(_ req: StartRequest, _ l: inout Launch) {
        l.arguments += req.permissions.trustFlags(req.harness)
        guard req.harness == .claude else { return }
        // Without `stdio` the CLI answers prompts itself and never sends can_use_tool.
        // It is not a permission mode, so the inherit mode keeps it.
        if !Self.hasFlag(req.extraArguments, "--permission-prompt-tool") {
            l.arguments += ["--permission-prompt-tool", "stdio"]
        }
        if req.permissions.mode != .inherit {
            l.arguments += ["--permission-mode", req.permissions.claudePermissionMode]
        }
    }

    // The config content is part of the server fingerprint, so a session never lands on a server that
    // started for other MCP servers or another permission mode. The inherit mode with no servers keeps
    // the config of the operator.
    private func addOpenCodeConfig(_ req: StartRequest, _ l: inout Launch) {
        guard req.harness == .opencode || req.harness == .opencode2 else { return }
        let permission = req.permissions.openCodePermission
        guard !req.mcpServers.isEmpty || permission != nil else { return }
        l.environment["OPENCODE_CONFIG_CONTENT"] = MCPRender.openCodeConfigContent(
            req.mcpServers, permission: permission)
    }

    private func addMCPServers(_ req: StartRequest, _ l: inout Launch) throws {
        guard !req.mcpServers.isEmpty else { return }
        switch req.harness {
        case .claude:
            let dir = try ConfigFiles.sessionDirectory(.claude, purpose: "mcp")
            l.tempPaths.append(dir)
            let path = dir.appendingPathComponent("mcp.json")
            try ConfigFiles.write(Data(MCPRender.claudeConfig(req.mcpServers).utf8), to: path)
            l.arguments += ["--mcp-config", path.path]
            if req.rawBool("strict_mcp") == true { l.arguments.append("--strict-mcp-config") }
        case .codex:
            for (k, v) in try MCPRender.codexEnvironment(req.mcpServers) {
                if let prev = l.environment[k], prev != v {
                    throw AgentBinderError.invalidRequest("codex MCP env \(k) conflicts with the session env")
                }
                l.environment[k] = v
            }
            l.arguments += MCPRender.codexArguments(req.mcpServers)
        case .opencode, .opencode2:
            // addOpenCodeConfig sets the config content.
            break
        case .copilot:
            // Quirk: Copilot ignores the stdio servers of ACP session/new. It loads this file.
            let dir = try ConfigFiles.sessionDirectory(.copilot, purpose: "mcp")
            l.tempPaths.append(dir)
            let path = dir.appendingPathComponent("mcp-config.json")
            try ConfigFiles.write(Data(MCPRender.copilotConfig(req.mcpServers).utf8), to: path)
            l.arguments += ["--additional-mcp-config", "@" + path.path]
        case .pi:
            guard let home = req.home else { throw AgentBinderError.homeRequired(feature: "MCP injection") }
            try ConfigFiles.write(
                Data(MCPRender.claudeConfig(req.mcpServers).utf8), to: home.appendingPathComponent("mcp.json"))
        default:
            // The ACP driver sends the servers in session/new, session/load or session/resume.
            break
        }
    }

    // Returns the index text. It is empty when the harness loads the skills itself.
    private func addSkills(_ req: StartRequest, _ l: inout Launch) async throws -> String {
        guard !req.skills.isEmpty else { return "" }
        let skills = try req.skills.map(LoadedSkill.init)
        switch req.harness {
        case .claude:
            let dir = try ConfigFiles.sessionDirectory(.claude, purpose: "plugin")
            l.tempPaths.append(dir)
            try SkillOverlay.writeClaudePlugin(at: dir, skills)
            l.arguments += ["--plugin-dir", dir.path]
            return ""
        case .codex, .opencode, .opencode2:
            // Without a home the consumer chose the config of the user, so do not graft a folder into it.
            guard let home = req.home else { return SkillOverlay.index(skills) }
            let folder = req.harness == .codex ? "skills" : "skill"
            try SkillOverlay.link(skills, into: home.appendingPathComponent(folder))
            return ""
        case .pi:
            if await flags.supportsFlag(l.binary, "--skill") {
                for s in skills { l.arguments += ["--skill", s.directory.path] }
                return ""
            }
            guard let home = req.home else { return SkillOverlay.index(skills) }
            try SkillOverlay.link(skills, into: home.appendingPathComponent("skills"))
            return ""
        default:
            return SkillOverlay.index(skills)
        }
    }

    private func addInstructions(_ req: StartRequest, _ l: inout Launch, _ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            l.instructions = nil
            return
        }
        l.instructions = text
        switch req.harness {
        case .claude:
            // One argv element. --append-system-prompt takes text, not a file, so a very large
            // instruction set belongs in a skill.
            l.arguments += ["--append-system-prompt", text]
            l.instructions = nil
        case .pi:
            if await flags.supportsFlag(l.binary, "--append-system-prompt") {
                l.arguments += ["--append-system-prompt", text]
                l.instructions = nil
            }
        case .fake:
            l.instructions = nil
        default: break
        }
    }

    /// True when `args` holds the flag, as `--flag` or `--flag=value`.
    static func hasFlag(_ args: [String], _ flag: String) -> Bool {
        args.contains { $0 == flag || $0.hasPrefix(flag + "=") }
    }
}
