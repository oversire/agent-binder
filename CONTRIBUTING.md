# Contributing

## Before you open a pull request

1. Run `swift build -Xswiftc -warnings-as-errors`.
2. Run `swift test` and `swift test --sanitize=thread`.
3. Run `swift format lint --strict -r Sources Tests`.
4. Run `scripts/api-check.sh`. When you change the public API on purpose, run `scripts/api-check.sh --update` and commit the new `api/AgentBinder.symbols.txt`.
5. Add an entry to `CHANGELOG.md` under "Unreleased".

## Fixtures

The driver tests read recorded vendor frames from `Tests/Fixtures/<harness>/`.
To record a new fixture, set `AGENTBINDER_RECORD=<dir>` on a live run. Each frame goes to `<dir>/<harness>-<time>.ndjson`.
To write the expected event lists again, run `AGENTBINDER_UPDATE_GOLDEN=1 swift test`. Examine the diff before you commit it.

## Live tests

The live tier uses the real vendor CLIs and the login of your machine. It never runs in CI.
Run `scripts/test-live.sh claude,codex` before a release.
