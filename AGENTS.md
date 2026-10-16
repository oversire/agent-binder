# Rules for agents in this repository

AgentBinder is a Swift library. It drives the coding-agent CLIs on a Mac over their structured protocols.

## Rules

- The library knows vendors. It does not know consumers. Do not add app paths or UI text.
- Do not add global mutable state. All state belongs to one `Runtime`.
- The `AgentBinder` target has no dependencies. Only `AgentBinderNative` imports the MCP SDK.
- Do not use `Foundation.Process` in `Sources/`. Use `ChildProcess` (posix_spawn with a process group).
- Give each vendor quirk a short comment and a fixture test.
- Add a fixture in `Tests/Fixtures/<harness>/` for each new frame shape.
- The Go project trebi-ai/agent-wire is a historical reference only. Do not add links to it in code.
- All public types are `Sendable`. Each public symbol has a DocC comment.
- The library ships no UI text. Errors carry a stable machine `code`.

## Commands

```sh
swift build
swift test
swift test --sanitize=thread
swift format lint --strict -r Sources Tests
scripts/coverage.sh
scripts/api-check.sh
scripts/test-live.sh claude
```
