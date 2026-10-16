import Foundation

/// The environment of a child.
enum ChildEnvironment {
    /// A parent Claude Code process sets this marker. A harness child that inherits it mistrusts the wire.
    private static let claudeCodeMarker = "CLAUDECODE"

    /// Merges the base environment, the search PATH and the overrides. The overrides win.
    /// Do not log the values: they can hold secrets.
    static func merge(base: [String: String], overrides: [String: String], path: String?) -> [String: String] {
        var env = base
        env.removeValue(forKey: claudeCodeMarker)
        if let path, !path.isEmpty { env["PATH"] = path }
        for (k, v) in overrides where !k.isEmpty && k != claudeCodeMarker { env[k] = v }
        return env
    }
}
