# Fixtures

Recorded vendor frames for the driver tests.

## Source

The first set came once, as plain data, from the reference project trebi-ai/agent-wire at commit `ed24a97` (2026-10-16): `testdata/claude/**` and `testdata/models/*.json`.
This repository owns the files now. It records new fixtures itself.
`fake/` holds hand-written frames of the fake harness.
`claude/shapes.ndjson` holds hand-written Claude frame shapes that the recorded streams do not have.
`codex/notifications.ndjson` holds hand-written Codex app-server notifications. Record real Codex turns on the first live run.
`acp/updates.ndjson` holds hand-written ACP `session/update` notifications. The Copilot, Cursor and Gemini drivers share it. Record real turns on the first live run.
`pi/lifecycle.ndjson` is a pi 0.84.1 turn from the reference project. `pi/shapes.ndjson` holds hand-written pi frame shapes.
`native/*.sse` hold hand-written provider streams: Anthropic Messages (`anthropic-*`) and OpenAI Chat Completions (`openai-*`). Record real streams on the first live run.
`opencode/turn.ndjson` and `opencode2/turn.ndjson` hold hand-written bus events of one turn on the 1.x and the 2.x wire. Record real turns on the first live run.

## Layout

- `<harness>/<name>.ndjson`: one vendor frame on each line.
- `<harness>/<name>.expected.json`: the event list that the driver must emit for the frames (golden file).
- `models/*.json`: replies of the model-list requests.
- `native/<provider>-<name>.sse`: one provider response body (server-sent events).

## Record a new fixture

Set `AGENTBINDER_RECORD=<dir>` on a live run. The session then writes each frame that the child sends, as it is, to `<dir>/<harness>-<time>-<n>.ndjson`.
Examine the file for secrets before you commit it.

## Write the golden files again

Run `AGENTBINDER_UPDATE_GOLDEN=1 swift test`. Examine the diff before you commit it.
