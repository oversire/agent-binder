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

    /// The Codex approval policy. The sandbox stays `workspace-write` in every mode:
    /// an unattended library must not give a child the whole disk.
    var codexApprovalPolicy: String {
        mode == .auto ? "never" : "on-request"
    }
}
