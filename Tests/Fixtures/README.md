# Fixtures

Recorded vendor frames for the driver tests.

## Source

The first set came once, as plain data, from the reference project trebi-ai/agent-wire at commit `ed24a97` (2026-10-16): `testdata/claude/**` and `testdata/models/*.json`.
This repository owns the files now. It records new fixtures itself.
`fake/` holds hand-written frames of the fake harness.
`claude/shapes.ndjson` holds hand-written Claude frame shapes that the recorded streams do not have.

## Layout

- `<harness>/<name>.ndjson`: one vendor frame on each line.
- `<harness>/<name>.expected.json`: the event list that the driver must emit for the frames (golden file).
- `models/*.json`: replies of the model-list requests.

## Record a new fixture

Set `AGENTBINDER_RECORD=<dir>` on a live run. The session then writes each frame that the child sends, as it is, to `<dir>/<harness>-<time>-<n>.ndjson`.
Examine the file for secrets before you commit it.

## Write the golden files again

Run `AGENTBINDER_UPDATE_GOLDEN=1 swift test`. Examine the diff before you commit it.
