import Foundation

// The live tier runs only when AGENTBINDER_LIVE names the harnesses, for example "claude,codex".
enum LiveGate {
    static var harnesses: Set<String> {
        let raw = ProcessInfo.processInfo.environment["AGENTBINDER_LIVE"] ?? ""
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static func enabled(_ harness: String) -> Bool { harnesses.contains(harness) }
}
