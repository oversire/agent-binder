import Foundation

extension PermissionPolicy {
    /// The trust flags of a harness. Only the auto mode adds them.
    func trustFlags(_ h: Harness) -> [String] {
        guard mode == .auto else { return [] }
        switch h {
        case .cursor: return ["--trust"]
        case .pi: return ["--approve"]
        default: return []
        }
    }

    /// The value of the Claude `--permission-mode` flag.
    var claudePermissionMode: String {
        switch mode {
        case .auto: return "bypassPermissions"
        case .autoEdit: return "acceptEdits"
        default: return "default"
        }
    }

    /// The `permission` block of the OpenCode config. Without it OpenCode allows edits and commands.
    var openCodePermission: JSONValue? {
        switch mode {
        case .ask: return ["edit": "ask", "bash": "ask", "webfetch": "ask"]
        case .autoEdit: return ["edit": "allow", "bash": "ask", "webfetch": "ask"]
        case .auto: return ["edit": "allow", "bash": "allow", "webfetch": "allow"]
        case .inherit: return nil
        }
    }

    /// The Codex approval policy. The sandbox stays `workspace-write` in every mode:
    /// an unattended library must not give a child the whole disk.
    var codexApprovalPolicy: String {
        mode == .auto ? "never" : "on-request"
    }
}
