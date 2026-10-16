# Fixtures

Recorded vendor frames for the driver tests.

## Source

The first set came once, as plain data, from the reference project trebi-ai/agent-wire at commit `ed24a97` (2026-10-16): `testdata/claude/**` and `testdata/models/*.json`.
This repository owns the files now. It records new fixtures itself.

## Layout

- `<harness>/<name>.ndjson`: one vendor frame on each line.
- `<harness>/<name>.expected.json`: the event list that the driver must emit for the frames (golden file).
- `models/*.json`: replies of the model-list requests.

## Record a new fixture

Set `AGENTBINDER_RECORD=<dir>` on a live run. The frame log then writes each frame that the child sends to `<dir>/<harness>-<time>.ndjson`.

## Write the golden files again

Run `AGENTBINDER_UPDATE_GOLDEN=1 swift test`. Examine the diff before you commit it.
