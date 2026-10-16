#!/bin/sh
# Fails when the line coverage of Sources/AgentBinder is below the gate (default 80 %).
set -eu
gate="${COVERAGE_GATE:-80}"
cd "$(dirname "$0")/.."
if [ "${SKIP_TEST:-0}" != "1" ]; then
  swift test --enable-code-coverage --skip AgentBinderLiveTests >/dev/null
fi
bin_dir="$(swift build --show-bin-path)"
profdata="$bin_dir/codecov/default.profdata"
xctest="$(find "$bin_dir" -maxdepth 1 -name '*.xctest' | head -1)"
exe="$xctest/Contents/MacOS/$(basename "$xctest" .xctest)"
report="$(xcrun llvm-cov report "$exe" -instr-profile "$profdata" Sources/AgentBinder)"
echo "$report" | tail -1
# The last percent column of llvm-cov report is the line coverage.
pct="$(echo "$report" | tail -1 | awk '{n=0; for (i=1; i<=NF; i++) if ($i ~ /%$/) {n++; v[n]=$i}; print v[3]}' | tr -d '%')"
awk -v p="$pct" -v g="$gate" 'BEGIN { if (p + 0 < g + 0) { printf "coverage %s%% is below %s%%\n", p, g; exit 1 } printf "coverage %s%% (gate %s%%)\n", p, g }'
