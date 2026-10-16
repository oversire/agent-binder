#!/bin/sh
# Compares the public symbols of AgentBinder with api/AgentBinder.symbols.txt.
# Fails when a public symbol has no DocC comment.
# Use --update to write the file again after a reviewed API change.
set -eu
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swift build --target AgentBinder >/dev/null
# The tool does not write a graph that did not change, so remove the old one first.
find .build -name 'AgentBinder.symbols.json' -path '*symbolgraph*' -delete
swift package dump-symbol-graph --minimum-access-level public >"$out/log" 2>&1 || { cat "$out/log"; exit 1; }
graph="$(find .build -name 'AgentBinder.symbols.json' -path '*symbolgraph*' | head -1)"
python3 - "$graph" "$out/undocumented.txt" >"$out/symbols.txt" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
lines = set()
undocumented = set()
for s in g["symbols"]:
    if s.get("accessLevel") not in ("public", "open"):
        continue
    # The standard library adds these to each actor. They change with the toolchain.
    if s["pathComponents"][-1] in ("assertIsolated(_:file:line:)", "assumeIsolated(_:file:line:)", "preconditionIsolated(_:file:line:)"):
        continue
    decl = "".join(f["spelling"] for f in s.get("declarationFragments", []))
    path = ".".join(s["pathComponents"])
    lines.add(f'{s["kind"]["identifier"]} {path} :: {decl}')
    # Members from a standard protocol (Codable, Equatable, ...) come from the module of the protocol.
    loc = s.get("location", {}).get("uri", "")
    if "Sources/AgentBinder/" in loc and not s.get("docComment"):
        undocumented.add(f'{path} ({loc.split("Sources/")[-1]})')
open(sys.argv[2], "w").write("\n".join(sorted(undocumented)))
print("\n".join(sorted(lines)))
PY
if [ -s "$out/undocumented.txt" ]; then
  echo "Public symbols without a DocC comment:" >&2
  cat "$out/undocumented.txt" >&2
  echo >&2
  exit 1
fi
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
