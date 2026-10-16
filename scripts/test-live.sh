#!/bin/sh
# Runs the live tier against the vendor CLIs of this machine. Usage: scripts/test-live.sh claude,codex
set -eu
cd "$(dirname "$0")/.."
if [ $# -lt 1 ]; then
  echo "usage: $0 <harness>[,<harness>...]" >&2
  exit 2
fi
# The live tier uses the login of the CLI, never an API key from the environment.
unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY CLAUDE_CODE_OAUTH_TOKEN || true
AGENTBINDER_LIVE="$1" swift test --filter AgentBinderLiveTests
