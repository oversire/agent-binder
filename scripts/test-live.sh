#!/bin/sh
# Runs the live tier against the vendor CLIs of this machine.
# Usage: scripts/test-live.sh claude,codex   (or: all)
# It writes the summary to .build/live-report.md.
set -u
cd "$(dirname "$0")/.."
if [ $# -lt 1 ]; then
  echo "usage: $0 <harness>[,<harness>...] | all" >&2
  exit 2
fi
# The live tier uses the login of the CLI, never an API key from the environment.
unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY CLAUDE_CODE_OAUTH_TOKEN || true
/bin/rm -rf .build/live-results
swift build --product agentbinder-mcp-helper || exit 1
AGENTBINDER_LIVE="$1" swift test --filter AgentBinderLiveTests --no-parallel
status=$?

report=.build/live-report.md
{
  echo "# Live test report"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%MZ). macOS $(sw_vers -productVersion)."
  echo
  echo "| Harness | Version | Case | Result |"
  echo "| --- | --- | --- | --- |"
  if [ -d .build/live-results ]; then
    cat .build/live-results/*.txt 2>/dev/null | sort | awk -F '\t' '{ printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }'
  fi
} > "$report"
echo "report: $report"
exit $status
