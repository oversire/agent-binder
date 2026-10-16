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
