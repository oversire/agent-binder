# AgentBinder

[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Foversire%2Fagent-binder%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/oversire/agent-binder)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Foversire%2Fagent-binder%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/oversire/agent-binder)
[![CI](https://github.com/oversire/agent-binder/actions/workflows/ci.yml/badge.svg)](https://github.com/oversire/agent-binder/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

AgentBinder is a native Swift library for Mac apps. It drives the coding-agent CLIs that are installed on the Mac over their own structured protocols. The app gets one event model for all of them. Each CLI uses its own login (Keychain, `~/.claude`, `~/.codex`). The library never reads, copies or stores a vendor token.

The `AgentBinderNative` product adds a model loop in process, for an app with no CLI installed.

macOS only: macOS 13 or later, Swift 6.1 or later (Xcode 16.3 or later).

- [Install](#install)
- [Quick start](#quick-start)
- [Harnesses](#harnesses)
- [Requirements of the host app](#requirements-of-the-host-app)
- [Detection](#detection)
- [Sessions and events](#sessions-and-events)
- [Permissions](#permissions)
- [Input during a turn](#input-during-a-turn)
- [Session setup](#session-setup)
- [Models and limits](#models-and-limits)
- [Errors](#errors)
- [The native loop](#the-native-loop)
- [Testing](#testing)
- [Custom drivers](#custom-drivers)
- [Compatibility](#compatibility)

## Install

```swift
dependencies: [
    .package(url: "https://github.com/oversire/agent-binder.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "AgentBinder", package: "agent-binder"),
        // Only for the in-process model loop:
        .product(name: "AgentBinderNative", package: "agent-binder"),
    ]),
]
```

`AgentBinder` has no dependencies. `AgentBinderNative` adds the MCP Swift SDK and swift-log.

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
    case .assistant(let text, let delta): if delta { print(text, terminator: "") }
    case .permission(let p): try await session.answer(p.id, .allow())
    case .result(let r): print("\n", r.usage); await session.close()
    case .exit(let code, let error, _): print("ended", code ?? 0, error ?? "")
    default: break
    }
}
await rt.close()
```

The event stream has one consumer. It ends after the `exit` event. `rt.close()` closes all live sessions of the runtime.

## Harnesses

| Harness | Binary | Protocol | Login | MCP | Skills | Steer |
| --- | --- | --- | --- | --- | --- | --- |
| `claude` | `claude` (Claude Code 2.0.0 or later) | stream-json | `claude auth login` | flags | native | yes |
| `codex` | `codex` | app-server JSON-RPC | `codex login` | flags | overlay | yes |
| `opencode` | `opencode` 1.x | HTTP server and SSE | `opencode auth login` | flags | overlay | no |
| `opencode2` | `opencode` 2.x | HTTP server and SSE | `opencode auth login` | flags | overlay | no |
| `pi` | `pi` | RPC mode | `/login` in `pi` | home | native | no |
| `copilot` | `copilot` | ACP | `/login` in `copilot` | flags | instructions | no |
| `cursor` | `cursor-agent` | ACP | `cursor-agent login` | session | instructions | no |
| `gemini` | `gemini` | ACP | sign in at the first run of `gemini` | session | instructions | no |
| `fake` | `/bin/sh` | a small NDJSON test vocabulary | none | no | instructions | yes |
| `native` | none (in process) | provider HTTP APIs | an API key in `Credentials` | session | native | no |

All CLI harnesses support instructions, resume, permissions and model lists. `Detection.features` gives the full feature table at run time.

The MCP column tells how the library adds the servers of `StartRequest.mcpServers`:

- **flags**: a config file or command-line flags for this session only. Copilot gets a temp file in `--additional-mcp-config`.
- **home**: a file in the isolated home. Pi needs `StartRequest.home` for MCP servers.
- **session**: the servers go in the ACP `session/new` request, or the native loop connects to them.

The Skills column tells how the library adds `StartRequest.skills`:

- **native**: the CLI loads the skill folders itself (a Claude plugin folder, `pi --skill`).
- **overlay**: links in the skills folder of the isolated home. Without a home, an index of the skills goes into the instructions.
- **instructions**: an index of the skills goes into the instructions.

## Requirements of the host app

1. **No App Sandbox.** A sandboxed app cannot run `~/.local/bin/claude` or read the vendor homes. The runtime finds the sandbox: `detect()` reports `.sandboxed`, and `start()` throws `AgentBinderError.sandboxed`.
2. **The PATH of a GUI app.** An app that Finder starts has only `/usr/bin:/bin:/usr/sbin:/sbin`. The binary resolver reads the `PATH` of the login shell of the user one time. Then it searches known folders (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`, `~/.npm-global/bin`, nvm). `StartRequest.binary` overrides the search. `Runtime.Options.binarySearchPaths` limits the search.
3. **Developer ID distribution.** Ship the app with Developer ID, outside the Mac App Store.

Each child runs in its own process group. `close()` closes stdin, waits 5 s, sends SIGTERM, waits 5 s, then sends SIGKILL to the group. A crash ledger (`Runtime.Options.ledger`) records the live children. Call `rt.reconcile()` at the next launch to kill the children that a crash left.

## Detection

```swift
for d in await rt.detectAll() {
    print(d.harness, d.version ?? "-", d.ready, d.auth, d.authDetail ?? "")
}
```

A `Detection` has the binary path, the version, the login state, the features and a `detail` (`notInstalled`, `belowFloor`, `sandboxed`, `noDriver`). `supported` is true when the binary is present, the version meets the floor and the app is not sandboxed. `ready` is true when `supported` is true and the login probe gives `ok`. Pi, Cursor, Copilot and Gemini have no login probe. Their `auth` is `unknown` and `ready` is false. To use them, start a session and examine the first result.

The login probe is best-effort. It runs the status command of the CLI (`claude auth status`, `codex login status`, `opencode auth list`), or it finds the API key variable of the vendor. It never reads a token. The runtime keeps the probe result for `authCacheTTL` (default 300 s). Call `rt.invalidateDetect(h)` after a login or a logout.

## Sessions and events

`rt.start(_:)` returns after the protocol handshake. `rt.resume(_:)` opens a known session again with `StartRequest.sessionID`.

| Event kind | Content |
| --- | --- |
| `initialized` | The handshake is done. |
| `assistant(text:delta:)` | Answer text. `delta: true` is a piece of a stream. `delta: false` is a full message. |
| `thought(text:delta:)` | Reasoning text. |
| `user(text:)` | A user message that the vendor echoes, for example a steer. |
| `tool(ToolEvent)` | A tool call: id, name, `ToolKind` (`read`, `edit`, `exec`, `mcp`, `search`, `other`), input, output, status and paths. |
| `permission(PermissionRequest)` | The agent asks for approval. Answer with `session.answer(id, decision)`. |
| `result(TurnResult)` | The turn ended: subtype, `isError`, text, usage, `endReason` and `code`. |
| `error(WireError)` | A failure with a stable `code`. |
| `usage(Usage)` | Token counters and cost. |
| `status(SessionStatus, text:)` | `running`, `waiting` or `idle`. |
| `limits(Limits)` | The plan limits of the account, for example from the Claude rate-limit events. |
| `exit(code:error:errorCode:)` | The session ended. It is the last event. |

Each event has the turn number, the vendor session id and the raw frame (`Event.raw`).

A prompt can have attachments:

```swift
try await session.prompt(Prompt("What is in this picture?", attachments: [.file(imageURL)]))
```

Set `StartRequest.oneShot` to write one prompt and close stdin, so the child exits after the turn.

## Permissions

`PermissionPolicy(mode:allowTools:)` sets the approval mode of the session:

| Mode | The library | Claude flag | Codex approval | OpenCode `permission` | Pi, Cursor |
| --- | --- | --- | --- | --- | --- |
| `ask` | Each request becomes a `permission` event. This is the default. | `--permission-mode default` | `on-request` | edit, bash, webfetch: `ask` | no flag |
| `autoEdit` | Allows edits. Other requests become events. | `acceptEdits` | `on-request` | edit: `allow`; bash, webfetch: `ask` | no flag |
| `auto` | Allows each request. | `bypassPermissions` | `never` | all: `allow` | `--approve`, `--trust` |
| `inherit` | Adds no flag. The config of the user decides. Requests become events. | no flag | no flag | not set | no flag |

`allowTools` holds tool name patterns that the library allows with no question in `ask` and `autoEdit`, for example `"mcp__docs__*"`. Codex keeps the sandbox `workspace-write` in each mode, so Codex asks only for actions outside the work folder. The raw override `sandbox` changes it: `read-only` makes Codex ask before each write. OpenCode gets the `permission` block in `OPENCODE_CONFIG_CONTENT`.

```swift
case .permission(let p):
    let ok = p.kind == .read || p.kind == .search
    try await session.answer(p.id, ok ? .allow() : .deny("Read-only session"))
```

`Decision.allow(updatedInput:)` replaces the input of the tool call where the vendor accepts it.

## Input during a turn

- `prompt(_:)` starts a turn. It throws `AgentBinderError.turnActive` while a turn runs, unless the vendor queues prompts itself.
- `steer(_:)` adds input to the running turn. Only `Steerable` sessions have it (Claude, Codex).
- `send(_:)` picks the best path and returns a `Delivery`:
  - `.steered`: the prompt joined the running turn.
  - `.prompted`: a new turn starts now, or the vendor queues it.
  - `.held`: the library holds the prompt and starts a turn when the running turn ends.

When the session ends with held prompts, it sends an `error` event with the code `held_prompt_dropped`.

`interrupt()` asks the harness to stop the current turn. The turn ends with a `result` event.

## Session setup

| Field | Use |
| --- | --- |
| `instructions` | Text for the system prompt or the first prompt, as the vendor allows. |
| `mcpServers` | `MCPServer.stdio(name:command:args:env:)` or `MCPServer.http(name:url:headers:)`. The servers of the user stay loaded. |
| `skills` | `Skill(directory:)` folders with a `SKILL.md` file. |
| `home` | An isolated config home (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `OPENCODE_CONFIG_DIR`, `PI_CODING_AGENT_DIR`, `CURSOR_CONFIG_DIR`). Nil uses the login, MCP servers and skills of the user. An isolated home needs its own login. |
| `model`, `effort` | The vendor model name and the reasoning effort (`low`, `medium`, `high`, `max`). |
| `environment` | Values for the child environment. They win on conflict. |
| `extraArguments` | Arguments after the arguments of the library. |
| `baseCommand` | An expert override. The library runs this command as it is and adds no flags. |
| `raw` | Vendor overrides that the typed fields do not cover: `strict_mcp`, `shared_auth`, `approvalPolicy`, `sandbox`, `auth_method`, `acp_auth_method`. |
| `frameLog` | A file that receives each frame in and out as NDJSON (mode 0600). It does not remove secrets. |
| `fileSystem` | File access for an ACP agent (`fs/readTextFile`, `fs/writeTextFile`). |
| `onStderr` | Receives each stderr line of the child. |

```swift
var r = StartRequest(harness: .codex, workingDirectory: repo)
r.mcpServers = [.stdio(name: "docs", command: "/usr/local/bin/docs-mcp")]
r.skills = [Skill(directory: appSupport.appendingPathComponent("skills/release"))]
r.permissions = PermissionPolicy(mode: .autoEdit, allowTools: ["mcp__docs__*"])
let s = try await rt.start(r)
```

## Models and limits

```swift
let models = try await rt.models(.claude)    // [ModelInfo], kept for modelCacheTTL
if let s = session as? any ModelSettable { try await s.setModel(models[0].id) }
let limits = try await rt.limits(.codex)     // the plan, and windows with the used percent and the reset time
```

`models(_:query:)` lists the models with no live session. `ModelInfo.isDefault` marks the default of the vendor. Call `rt.invalidateModels(h)` to read the list again. A `SessionModelListing` session gives the models of its handshake.

`limits(_:query:)` reads the plan limits where the vendor gives them. Claude also sends `limits` events during a turn.

## Errors

- `AgentBinderError` is the error of the API calls: `binaryNotFound`, `belowVersionFloor`, `sandboxed`, `handshakeTimeout`, `turnActive`, `noActiveTurn`, `resumeUnsupported`, `homeRequired` and more.
- `WireError` (in `error` events and in `Session.lastError`) and `TurnResult` have a stable machine `code` and an `EndReason`: `auth`, `limit`, `entitlement`, `overloaded`, `protocol`, `failed`, `launch` or `unknown`.
- `Classifier.classify(_:status:harness:)` maps vendor error text to a `Classification`.

The library ships no UI text. Map the codes to the text of your app.

## The native loop

`AgentBinderNative` runs a model loop in process. It gives the same events as a CLI harness.

```swift
import AgentBinder
import AgentBinderNative

let config = NativeConfig(
    newModel: { creds, name in
        switch creds.format {
        case .anthropic: return try AnthropicModel(credentials: creds, model: name)
        case .openai: return try OpenAIModel(credentials: creds, model: name)
        }
    },
    builtinTools: true,
    store: FileStore(directory: appSupport.appendingPathComponent("sessions")))
await rt.setDriver(NativeDriver(config), for: .native)
let s = try await rt.start(StartRequest(
    harness: .native, workingDirectory: dir,
    credentials: Credentials(format: .anthropic, apiKey: key)))
```

- **Providers.** `AnthropicModel` calls the Anthropic Messages API. `OpenAIModel` calls the OpenAI Chat Completions API and the gateways that copy it (Ollama, OpenRouter, vLLM, Groq, LM Studio). For a gateway, set `Credentials.baseURL` to its `/v1` URL. An app can also bring its own type that conforms to `Model`.
- **Anthropic defaults.** On the first-party endpoint, prompt caching is on (a top-level `cache_control`). Refusal fallback is also on: when a model refuses a request, the API runs it again on the recommended model in the same stream. Set `AnthropicModel.Options.promptCaching` or `refusalFallback` to false to stop them.
- **Tools.** `builtinTools: true` adds `bash`, `read`, `write`, `edit`, `glob` and `grep`. They stay inside the working folder, and `bash` does not get the API keys of the host. Add your own tools with `FuncTool` in a `StaticToolSet`. Add MCP servers with `StartRequest.mcpServers` or `MCPToolSet.connect`.
- **Approvals.** The `PermissionPolicy` of the request gates the tools. Set `NativeConfig.approver` for your own rules.
- **History.** `FileStore` keeps one JSONL file for each session, so `rt.resume` works after a restart. `MemoryStore` keeps the history in memory. `SummaryCompactor(keepLast:)` folds old messages into a summary when the history is larger than `contextTokens`.
- **Limits.** `maxTurns` limits the model calls of one turn. `beforeCall` and `afterCall` see each model call, for example for a budget.

```swift
struct City: Decodable, Sendable { var city: String }
let weather = FuncTool<City, String>(
    ToolSpec(name: "get_weather", description: "The weather of a city.",
             inputSchema: Data(#"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#.utf8))
) { input in "sunny in \(input.city)" }
let config = NativeConfig(newModel: makeModel, toolSets: [StaticToolSet("app", [weather])])
```

## Testing

The `fake` harness runs a `/bin/sh` script that speaks a small NDJSON vocabulary. Use it to test your event pump with no vendor binary:

```swift
let script = #"""
    read -r line
    echo '{"type":"assistant","text":"hello"}'
    echo '{"type":"result","subtype":"success","text":"hello"}'
    """#
await rt.setDriver(FakeDriver(script: script), for: .fake)
let s = try await rt.start(StartRequest(harness: .fake, workingDirectory: tmp))
```

The session writes one line to the script for each call: `user`, `steer`, `set_model` and `decision`. The script writes `init`, `assistant`, `thought`, `user`, `tool`, `permission`, `usage`, `status`, `result` and `error` lines. See `FakeDriver` for the fields.

### The tests of this repository

```sh
swift test                                # unit and fixture tests
swift test --sanitize=thread
scripts/coverage.sh                       # the gate is 80 %
scripts/test-live.sh claude,codex         # the live tier, or: all
```

The live tier runs the real CLIs with the login of the machine. It refuses to run when `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` or `OPENAI_API_KEY` is set. It writes a summary to `.build/live-report.md`. Set `AGENTBINDER_RECORD=<dir>` to record the frames of each session as new fixtures. The native live tests need `AGENTBINDER_LIVE_NATIVE=1` and `AGENTBINDER_LIVE_ANTHROPIC_KEY` or `AGENTBINDER_LIVE_OPENAI_KEY`.

## Custom drivers

A `Driver` starts and resumes sessions for one protocol. Register it for a harness name:

```swift
extension Harness { static let myAgent = Harness("my-agent") }
await rt.setDriver(MyDriver(), for: .myAgent)
```

The optional protocols `ModelListing`, `LimitsReading` and `SelfDetecting` add model lists, limits and detection. `rt.context` gives the services of the runtime to a driver: the binary resolver, the version probe, the child environment and the logger. `setDriver(nil, for:)` gives back the built-in driver.

## Compatibility

[docs/compat.md](docs/compat.md) lists the vendor versions that the live tier verified. The [CHANGELOG](CHANGELOG.md) lists the changes of each release.

The API reference (DocC) is on the [Swift Package Index](https://swiftpackageindex.com/oversire/agent-binder/documentation/agentbinder).

## License

MIT. See [LICENSE](LICENSE).
