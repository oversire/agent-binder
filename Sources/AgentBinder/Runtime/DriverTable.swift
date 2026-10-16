/// The built-in drivers. The native driver is not built in: the app registers it with
/// ``Runtime/setDriver(_:for:)``.
enum DriverTable {
    static func builtIn() -> [Harness: any Driver] {
        [
            .claude: ClaudeDriver(), .codex: CodexDriver(), .opencode: OpenCodeDriver(.opencode),
            .opencode2: OpenCodeDriver(.opencode2), .pi: PiDriver(), .copilot: ACPDriver(.copilot),
            .cursor: ACPDriver(.cursor),
            .gemini: ACPDriver(.gemini), .fake: FakeDriver(),
        ]
    }
}
