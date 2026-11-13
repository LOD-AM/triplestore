#!/usr/bin/env bash
# Checks that the "LOD-AM project" block at the end of CLAUDE.md is identical
# to the one in LOD-AM/knowledge-graph (the source of truth).
# Usage: scripts/check_shared_block.sh [path/to/source/CLAUDE.md]
# Without an argument the source is fetched from knowledge-graph's main branch.
set -euo pipefail

MARKER='^## LOD-AM project \(shared block'
SOURCE_URL="https://raw.githubusercontent.com/LOD-AM/knowledge-graph/main/CLAUDE.md"
cd "$(dirname "$0")/.."

block() { sed -nE "/$MARKER/,\$p" "$1"; }

src=$(mktemp); trap 'rm -f "$src"' EXIT
if [ $# -ge 1 ]; then cp "$1" "$src"; else curl -fsSL --retry 3 "$SOURCE_URL" -o "$src"; fi

if [ -z "$(block CLAUDE.md)" ]; then
  echo "FAIL: CLAUDE.md has no '## LOD-AM project (shared block ...)' section"; exit 1
fi
if [ -z "$(block "$src")" ]; then
  echo "WARNING: the source CLAUDE.md has no shared block yet; nothing to compare."; exit 0
fi
if diff -u <(block "$src") <(block CLAUDE.md) > /dev/null; then
  echo "ok: shared LOD-AM block matches knowledge-graph"
else
  echo "FAIL: shared LOD-AM block differs from knowledge-graph (- source, + this repo):"
  diff -u <(block "$src") <(block CLAUDE.md) || true
  echo "Change the block in LOD-AM/knowledge-graph first, then copy it here unchanged."
  exit 1
fi
