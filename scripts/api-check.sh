#!/bin/sh
# Compares the public symbols of AgentBinder with api/AgentBinder.symbols.txt.
# Use --update to write the file again after a reviewed API change.
set -eu
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swift build --target AgentBinder >/dev/null
swift package dump-symbol-graph --minimum-access-level public >"$out/log" 2>&1 || { cat "$out/log"; exit 1; }
graph="$(find .build -name 'AgentBinder.symbols.json' -newer Package.swift | head -1)"
python3 - "$graph" >"$out/symbols.txt" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
lines = set()
for s in g["symbols"]:
    if s.get("accessLevel") not in ("public", "open"):
        continue
    decl = "".join(f["spelling"] for f in s.get("declarationFragments", []))
    path = ".".join(s["pathComponents"])
    lines.add(f'{s["kind"]["identifier"]} {path} :: {decl}')
print("\n".join(sorted(lines)))
PY
if [ "${1:-}" = "--update" ]; then
  cp "$out/symbols.txt" api/AgentBinder.symbols.txt
  echo "api/AgentBinder.symbols.txt updated"
  exit 0
fi
if ! diff -u api/AgentBinder.symbols.txt "$out/symbols.txt"; then
  echo "The public API changed. Review the diff, then run scripts/api-check.sh --update." >&2
  exit 1
fi
echo "public API unchanged"
