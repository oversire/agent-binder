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

### Known behavior

- Claude: the `init` event has no model name. The model is in the raw frame of the event.
- Claude: the pending permission inputs stay after a result and after the exit, as in the vendor wire.
- Codex: an error reply to any request gives an `rpc_error` event, also when a caller got the error.
- Codex: a session that saw one `turn/completed` gives no classified error when the process ends in a later turn.

### Changed on purpose (from the reference behavior)

- Codex: a turn that ends before the `turn/start` reply arrives does not stay active.
- Codex: an `error` notification with no message takes the error text or its JSON.
- Codex: a JSON-RPC error of the model or limits probe names its method, for example `codex model/list: ...`.
