# Changelog

All notable changes to this project are recorded in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Package skeleton: the `AgentBinder` and `AgentBinderNative` products.
- The Claude driver: stream-json with the control channel (initialize, `can_use_tool`, interrupt, `set_model`), steer, a model probe and rate-limit windows.
- `ToolStatus.cancelled`: a tool that was open when the turn or the process ended.
- The Codex driver: `codex app-server` over JSON-RPC (threads, turns, steer, interrupt, approvals), a paged model list and a limits read.
- The ACP drivers for Copilot, Cursor and Gemini: the handshake with the session load and the authentication, prompts, cancel, permissions, the client file system and the session models.
- The pi driver: `pi --mode rpc` with prompts, steer, abort, permissions, `set_model` and a model probe.
- The OpenCode drivers: `opencode serve` over HTTP and server-sent events, for the 1.x wire (`opencode`) and the 2.x wire (`opencode2`). Sessions with the same binary, environment and arguments share one server. The pool stops an idle server after 60 s.
- The native loop (`AgentBinderNative`): `NativeDriver` runs a model loop in process with the `Model` protocol, tool sets (`FileTools`, `MCPToolSet`, `FuncTool`), approvals, skills, a message store (`FileStore`, `MemoryStore`) and compaction (`SummaryCompactor`).
- The native providers: `AnthropicModel` (Messages API) and `OpenAIModel` (Chat Completions API and compatible gateways), on `URLSession` with server-sent events. They retry before the first byte of the response, and a failure is a `ProviderError` with a stable `code`.
- The live tier (`scripts/test-live.sh`): it runs real turns on the local CLI logins and writes a report to `.build/live-report.md`. The `agentbinder-mcp-helper` executable is its stdio MCP server. It is not a product.

### Known behavior

- Claude: the `init` event has no model name. The model is in the raw frame of the event.
- Claude: the pending permission inputs stay after a result and after the exit, as in the vendor wire.
- Codex: an error reply to any request gives an `rpc_error` event, also when a caller got the error.
- Codex: a session that saw one `turn/completed` gives no classified error when the process ends in a later turn.
- ACP: `usage_update` puts the used context in `input` and the context size in `output`.
- ACP: a one-shot turn closes the standard input after the prompt.
- pi: the deltas of `message_update` and the full text of `message_end` both give assistant events. Use the `delta` flag to drop one.
- pi: when `message_start` and `message_end` both have content, the blocks repeat.
- pi: a steer works on the wire, but `Features.steer` stays false until a live turn proves it.
- OpenCode: an `opencode` request on a 2.x binary uses the 2.x wire, and its session reports `opencode2`.
- OpenCode: the result of a turn has no text and no usage. The `usage` events carry the usage.
- OpenCode: a stopped or dead server ends each of its sessions with the error code `server_exited`.
- OpenCode 2.x: an interrupt ends the turn with an `interrupted` result. The aborted step gives no error event.
- OpenCode 2.x: the instructions go to the `/experimental` route of 2.0.26. On a 404 the driver uses the older route.
- ACP: each stdio MCP server has `args` and `env`, and each HTTP server has `headers`, also when they are empty. Gemini rejects a server without `env`.
- ACP: `authenticate` waits at most 15 s. A stale Cursor login never answers it, so the start fails with the vendor auth error, not a handshake timeout.
- pi: RPC mode sends no session event. The driver reads the session id from `get_state`.
- OpenCode: the permission mode goes to the `permission` block of `OPENCODE_CONFIG_CONTENT`. Without it OpenCode allows edits and commands with no question. The `inherit` mode with no MCP servers sets no config.
- ACP: a model list with a repeated id keeps the first entry. Copilot 1.0.71 lists `auto` twice.
- ACP: an `agent_message_chunk` gives an assistant event with `delta: true`. The chunks are parts of one message.
- Copilot: the MCP servers go in a temp file for `--additional-mcp-config`. Copilot 1.0.98 ignores the stdio servers of ACP `session/new`, so the driver sends an empty list.
- OpenCode 2.x: a permission answer sends `decision` for 2.0.26 and `reply` for older 2.x builds.
- Native: the built-in tools work on the disk. `Features.fileSystem` is false, and `StartRequest.fileSystem` has no effect.
- Native: the `allowed-tools` key of a skill is read, but it does not limit the tools.
- Native: an MCP tool call always needs approval, also when the server marks the tool read-only.

### Changed on purpose (from the reference behavior)

- Codex: a turn that ends before the `turn/start` reply arrives does not stay active.
- Codex: an `error` notification with no message takes the error text or its JSON.
- Codex: a JSON-RPC error of the model or limits probe names its method, for example `codex model/list: ...`.
- ACP: a resume that the agent refuses throws `resumeUnsupported`. It does not open a new session.
- ACP: an attachment error or a write error does not leave the turn active.
- ACP: the waiting requests fail at once when the process ends.
- ACP: an idle session that ends with code 0 gives no error.
- ACP: the config key `auth_method` is an alias of `acp_auth_method`.
- pi: the error of one turn does not fail the next turn.
- pi: the prompt frame has an id. A refused prompt gives an error and ends the turn.
- pi: a write error does not leave the turn active.
- pi: an idle session that ends with code 0 gives no error, and the waiting commands fail at once on exit.
- pi: a tool event also reads the documented keys `toolCallId`, `toolName`, `args`, `result` and `isError`.
- OpenCode: the launch arguments go to `opencode serve`, and they are part of the server fingerprint.
- OpenCode: the ledger row of a server has the key `<harness>:serve-<pid>`. Its sessions do not add rows.
- OpenCode: an event stream that does not connect fails the start of the session.
- OpenCode: the stream reconnect wait doubles up to 10 s, and a good connection resets it.
- OpenCode 1.x: the `init` event comes from the driver, not from `session.created`.
- OpenCode 1.x: a part text that gets shorter replaces the text. A text of the same length gives no event.
- OpenCode 1.x: a `session.idle` event when no turn runs gives no event.
- OpenCode 1.x: a `usage` event comes only when the message has a cost or a completion time.
- OpenCode: a close sends an interrupt only when a turn runs.
- OpenCode: a stopped server gives an `error` event only when a turn runs.
- Native: a `FuncTool` with a `String` output gives the text as it is, not as a JSON string.
- Native: `Decision.updatedInput` replaces the input of the tool call.
- Native: a permission request gives the status `waiting`, and the answer gives the status `running`.
- Native: an MCP tool name has only `[a-zA-Z0-9_-]` and is at most 64 characters. A duplicate name gets a `_N` suffix.
- Native: the `usage` of a result is the sum of all model calls of the turn.
- Native: a symlink in the workspace that leads out of the root is refused.
- Native: `prompt` returns when the turn starts. It does not wait for the result.
- Native: a start with no session id makes a new id.
- Native: a turn that reaches the call limit gives the result `error_max_turns` with `isError`.
- Native: `activate_skill` is in the tool list only when the session has skills.
- Native: an Anthropic effort sends `thinking: {type: "adaptive"}` and `output_config.effort`, not a thinking budget. The current models refuse `budget_tokens`. The effort `xhigh` is accepted.
- Native: the default Anthropic `max_tokens` is 64000, not 8192.
- Native: Anthropic web search uses the tool `web_search_20260209`.
- Native: Anthropic prompt caching is on by default (top-level `cache_control`).
- Native: on the first-party Anthropic endpoint, refusal fallback is on by default for the models that take it (`fallbacks: "default"` and the beta header). A `fallback` stream part removes the reasoning and the tool calls of the declined attempt.
- Native: on the first-party Anthropic endpoint, client tools send `eager_input_streaming: true`.
- Native: OpenAI sends `max_completion_tokens` on api.openai.com and `max_tokens` on a gateway.
- Native: `OpenAIModel` needs a model name. There is no default.
- Native: an Anthropic reasoning part with no signature is not sent back.

### Fixed on purpose (from the reference behavior)

- Native: the reasoning keeps its provider signature in the history, so the next call can send it back.
- Native: the tool list keeps the insertion order, so the request bytes stay stable for prompt caching.
- Native: a cancel between tool calls gives each open call a `cancelled` result, so the next prompt works.
- Native: compaction does not split a tool call from its result.
- Native: an empty model answer adds no message to the history.
- Native: `bash` gets the full environment of the session, `PATH` too.
- Native: the glob segment `**` matches zero or more segments.
- Native: `MCPToolSet` follows `nextCursor`, and an HTTP server gets the headers on each request.
- Native: a `bash` timeout kills the process group, so a background child cannot hold the output open.
- Native: a permission event has the tool call id in `toolUseID`.
- Native: Anthropic `signature_delta` is kept, so the thinking block can go back on the next call.
- Native: the assistant message keeps the arrival order of reasoning, text and tool calls.
- Native: consecutive Anthropic messages of the same role merge into one message.
- Native: an Anthropic stream that ends with no stop reason is a failure.
- Native: OpenAI sends `stream_options.include_usage`, so the stream reports the usage.
- Native: OpenAI sends `tool_choice` only with tools.
- Native: an OpenAI tool call with an empty input sends `"{}"`.
- Native: the providers never read the environment (base URLs, tokens, organization ids).
