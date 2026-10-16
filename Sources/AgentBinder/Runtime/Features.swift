extension Features {
    /// The static capability table of a harness. A feature that needs ``StartRequest/home`` degrades
    /// at run time; it does not leave this table.
    static func builtIn(_ h: Harness) -> Features {
        switch h {
        case .claude:
            return Features(
                mcpInject: .flags, skillsInject: .native, instructions: true, attachments: true, resume: true,
                permissions: true, models: true, setModel: true, steer: true)
        case .codex:
            return Features(
                mcpInject: .flags, skillsInject: .overlay, instructions: true, attachments: true, resume: true,
                permissions: true, models: true, setModel: true, steer: true)
        case .opencode, .opencode2:
            return Features(
                mcpInject: .flags, skillsInject: .overlay, instructions: true, attachments: true, resume: true,
                permissions: true, models: true, setModel: true)
        case .pi:
            // The session can steer, but no live turn has proved it yet.
            return Features(
                mcpInject: .flags, skillsInject: .native, instructions: true, resume: true, permissions: true,
                models: true, setModel: true)
        case .copilot, .cursor, .gemini:
            // Models and setModel work only when the agent offers a model list.
            return Features(
                mcpInject: .session, skillsInject: .instructions, instructions: true, attachments: true, resume: true,
                permissions: true, fileSystem: true, models: true, setModel: true)
        case .native:
            // The built-in tools work on the disk, not through StartRequest.fileSystem.
            return Features(
                mcpInject: .session, skillsInject: .native, instructions: true, attachments: true, resume: true,
                permissions: true)
        case .fake:
            return Features(
                skillsInject: .instructions, instructions: true, resume: true, permissions: true, models: true,
                setModel: true, steer: true)
        default:
            return Features(skillsInject: .instructions)
        }
    }
}
