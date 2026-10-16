# AgentBinder

AgentBinder is a native Swift library for Mac apps. It drives the coding-agent CLIs that are installed on the Mac over their own structured protocols:

| Harness | CLI | Protocol |
| --- | --- | --- |
| `claude` | Claude Code | stream-json |
| `codex` | Codex | app-server JSON-RPC |
| `opencode`, `opencode2` | OpenCode 1.x, 2.x | HTTP server and SSE |
| `pi` | pi | RPC mode |
| `copilot`, `cursor`, `gemini` | Copilot CLI, Cursor Agent, Gemini CLI | ACP |
| `fake` | `/bin/sh` script | test vocabulary |

The app gets one event model for all harnesses. Each CLI uses its own login (Keychain, `~/.claude`, `~/.codex`). The library never reads, copies or stores a vendor token.

The `AgentBinderNative` product runs a model loop in process, for an app with no CLI installed:

```swift
import AgentBinderNative

await rt.setDriver(NativeDriver(NativeConfig(newModel: { creds, name in try makeModel(creds, name) }, builtinTools: true)), for: .native)
let s = try await rt.start(StartRequest(harness: .native, workingDirectory: dir, credentials: creds))
```

The model comes from the app (a type that conforms to `Model`). The built-in tools (`bash`, `read`, `write`, `edit`, `glob`, `grep`) stay inside the working folder, and `bash` does not get the API keys of the host.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/oversire/agent-binder.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "AgentBinder", package: "agent-binder")]),
]
```

Requirements: macOS 13 or later, Swift 6.0 or later.

## Quick start

```swift
import AgentBinder

let rt = Runtime(options: .init(clientName: "my-app", clientVersion: "1.0.0"))
let session = try await rt.start(StartRequest(
    harness: .claude,
    workingDirectory: URL(fileURLWithPath: "/path/to/project"),
    instructions: "Read AGENTS.md first.",
    permissions: .init(mode: .ask)))
try await session.prompt(Prompt("Summarize this project."))
for await ev in session.events {
    switch ev.kind {
    case .assistant(let text, _): print(text, terminator: "")
    case .permission(let p): try await session.answer(p.id, .allow())
    case .result(let r): print("\n", r.usage)
    case .exit(let code, let error, _): print("ended", code ?? 0, error ?? "")
    default: break
    }
}
```

## Constraints of the host app

1. **No App Sandbox.** A sandboxed app cannot run `~/.local/bin/claude` or read the vendor homes. The runtime finds the sandbox: `detect()` reports `.sandboxed`, and `start()` throws `AgentBinderError.sandboxed`.
2. **The PATH of a GUI app.** An app that Finder starts has only `/usr/bin:/bin:/usr/sbin:/sbin`. The binary resolver reads the `PATH` of the login shell of the user one time, then searches known folders (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`, `~/.npm-global/bin`, nvm). `StartRequest.binary` overrides the search.
3. **Developer ID distribution.** Ship the app with Developer ID outside the Mac App Store.

## Documentation

The DocC documentation is on the [Swift Package Index](https://swiftpackageindex.com/oversire/agent-binder/documentation).

## License

MIT. See [LICENSE](LICENSE).
