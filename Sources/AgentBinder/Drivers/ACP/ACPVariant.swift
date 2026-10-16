import Foundation

/// One ACP agent: its command line, its login pick and its quirks.
enum ACPVariant: String, Sendable {
    case copilot
    case cursor
    case gemini

    var harness: Harness {
        switch self {
        case .copilot: return .copilot
        case .cursor: return .cursor
        case .gemini: return .gemini
        }
    }

    /// The launch arguments plus the flag or subcommand of the ACP transport.
    ///
    /// `help` is the `--help` text. Only Gemini reads it.
    func arguments(_ launch: [String], help: () async -> String) async -> [String] {
        switch self {
        case .copilot:
            return LaunchBuilder.hasFlag(launch, "--acp") ? launch : launch + ["--acp"]
        case .cursor:
            // `acp` is a hidden subcommand that `--help` does not list. It replaces the run-mode flags,
            // and the session id goes on the wire.
            return Self.stripCursorArguments(launch) + ["acp"]
        case .gemini:
            // A binary with neither flag fails loudly in the handshake, not in a silent TUI.
            let text = await help()
            if text.contains("--experimental-acp") { return launch + ["--experimental-acp"] }
            if text.contains("--acp") { return launch + ["--acp"] }
            return launch + ["--experimental-acp"]
        }
    }

    static func stripCursorArguments(_ args: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--resume" || a == "--continue" || a == "-c" {
                i += 2
                continue
            }
            if !a.hasPrefix("--resume=") && !a.hasPrefix("--continue=") { out.append(a) }
            i += 1
        }
        return out
    }

    /// The `authenticate` method: the first one, then the last one that names the vendor login.
    func authMethod(_ methods: [String]) -> String? {
        guard var pick = methods.first else { return nil }
        for m in methods {
            switch self {
            case .cursor where m.contains("cursor_login"): pick = m
            case .copilot where m.contains("github") || m.contains("device"): pick = m
            default: break
            }
        }
        return pick
    }

    /// The chat id in the `cursor-agent create-chat` output: the first UUID, else the last line.
    static func lastIdentifier(_ text: String) -> String {
        var last = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            last = line
            for field in line.split(whereSeparator: \.isWhitespace) {
                let f = field.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,"))
                if isUUID(f) { return f }
            }
        }
        return last.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    private static func isUUID(_ s: String) -> Bool {
        let c = Array(s.utf8)
        guard c.count == 36 else { return false }
        for (i, b) in c.enumerated() {
            if [8, 13, 18, 23].contains(i) {
                if b != UInt8(ascii: "-") { return false }
            } else if !(b >= 48 && b <= 57 || b >= 97 && b <= 102 || b >= 65 && b <= 70) {
                return false
            }
        }
        return true
    }
}
