# Compatibility

This page lists the vendor CLI versions that the live tier verified for AgentBinder 0.1.0. The live run was on 2026-10-16, on macOS 15.7.

The live tier uses the login of each CLI on the test machine. A case that fails because of the local login or the local model is "blocked". It is not a library failure. To run the tier, see [The tests of this repository](../README.md#the-tests-of-this-repository).

## Summary

| Harness | Version | Status | Cases that pass |
| --- | --- | --- | --- |
| `claude` | Claude Code 2.1.302 | verified | 9 of 9 |
| `codex` | codex-cli 0.163.0 | verified, 2 cases blocked | 7 of 9 |
| `opencode` | opencode 2.0.26 (2.x wire) | verified | 7 of 7 |
| `opencode2` | opencode 2.0.26 | verified | 7 of 7 |
| `copilot` | GitHub Copilot CLI 1.0.98 | verified | 7 of 7 |
| `gemini` | Gemini CLI 0.17.0 | blocked by the local login | 0 of 7 |
| `pi` | pi 0.84.1 | blocked by the local login | 0 of 6 |
| `cursor` | not run | not verified | none |

OpenCode 1.x is not verified. The test machine has only 2.0.26, and an `opencode` request on a 2.x binary uses the 2.x wire.

## Cases

Each case is one file in `Tests/LiveTests`:

- **one turn**: one prompt gives one result with the expected text.
- **permission**: a denied tool call does not change the disk.
- **resume**: a second session continues the first one.
- **interrupt**: an interrupt ends the turn.
- **steer**: a steer message changes a running turn.
- **models**: the model list is not empty, and a model change works.
- **limits**: the rate limits read works.
- **mcp**: the agent calls a tool of a stdio MCP server that the library adds.
- **skills**: the agent uses a skill that the library adds.

A harness that does not have a feature skips its case. The number of cases is different for each harness for this reason.

## Blocked cases

- **codex limits**: the ChatGPT usage endpoint rejects the local token (HTTP 401). The library gives the vendor error.
- **codex mcp**: Codex loads the server (`codex mcp list` shows it). The local model (a ZAI model) replies with no tool call. A plain `codex exec` has the same result.
- **gemini**: the local login needs `GOOGLE_CLOUD_PROJECT`. Each case stops at "Authentication required".
- **pi**: the OAuth refresh of the local login fails (`invalid_grant`). No turn completes. The `mcp` case also needs `StartRequest.home`.
- **cursor**: the local login is stale, so the tier did not run Cursor. The ACP driver has fixture tests for the Cursor wire.

## Vendor quirks

The live run found vendor quirks. The [CHANGELOG](../CHANGELOG.md) lists them under "Known behavior". Each quirk has a fixture test.
