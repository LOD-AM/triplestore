#!/usr/bin/env bash
# Test of scripts/publish_website.sh (LOD-AM/website#21) against a local stand-in of the website
# repository: no Fuseki, no Docker, no network. Runs a copy of the script in a temporary checkout,
# so a server's .env (LODAM_WEBSITE_REPO) is never read.
#   bash scripts/test_publish_website.sh
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/co/scripts" "$T/co/deploy"
cp scripts/publish_website.sh "$T/co/scripts/"; cp deploy/github_known_hosts "$T/co/deploy/"
export LODAM_RELEASES=$T/releases LODAM_WEBSITE_REPO=$T/website.git
G=(git -c user.name=test -c user.email=test@example.invalid -c init.defaultBranch=main)
fail() { echo "FAIL $1"; tail -20 "$T/out" 2>/dev/null; exit 1; }
run() { "$T/co/scripts/publish_website.sh" > "$T/out" 2>&1; }
show() { git -C "$T/website.git" show "$1" 2>/dev/null; }
files() { git -C "$T/website.git" ls-tree -r --name-only "$1" -- data/ 2>/dev/null | tr '\n' ' '; }

# the website: main with an older release and other files
"${G[@]}" init --quiet --bare "$T/website.git"
"${G[@]}" init --quiet "$T/site"; mkdir -p "$T/site/data/published" "$T/site/data/vocab"
echo '<urn:old> <urn:p> "old" .' > "$T/site/data/published/old.ttl"
echo '<urn:v> <urn:p> "vocab" .' > "$T/site/data/vocab/topics.ttl"
echo "site" > "$T/site/README.md"
"${G[@]}" -C "$T/site" add -A; "${G[@]}" -C "$T/site" commit --quiet -m init; "${G[@]}" -C "$T/site" push --quiet "$T/website.git" HEAD:main

live() { # ttl files...: a live release as update_published.sh leaves it
  rm -rf "$T/releases/live"; mkdir -p "$T/releases/live/published"
  for f in "$@"; do echo "<urn:$f> <urn:p> \"$f\" ." > "$T/releases/live/published/$f.ttl"; done
  echo combined > "$T/releases/live/combined.ttl"; echo x > "$T/releases/live/manifest.sha256"
  python3 - "$T/releases/live" <<'PY'
import hashlib, json, sys
from pathlib import Path
d = Path(sys.argv[1])
files = [{"key": f.stem, "file": f"published/{f.name}", "sha256": hashlib.sha256(f.read_bytes()).hexdigest(), "triples": 1}
         for f in sorted((d / "published").glob("*.ttl"))]
(d / "manifest.json").write_text(json.dumps({"manifest_version": 2, "pipeline": {"commit": "a" * 40},
    "knowledge_graph": {"commit": "b" * 40}, "publications": {"files": files}}))
PY
}

LODAM_WEBSITE_REPO='' run && grep -q "not set" "$T/out" || fail "0: without LODAM_WEBSITE_REPO it must skip"
echo "ok   0 skipped without LODAM_WEBSITE_REPO"

live a; run || fail "1: first hand-over"
[ "$(files data-release)" = "data/published/a.ttl data/release-manifest.json data/vocab/topics.ttl " ] \
  || fail "1: branch content: $(files data-release)"
[ "$(files main)" = "data/published/old.ttl data/vocab/topics.ttl " ] || fail "1: main was changed"
show data-release:README.md | grep -q site || fail "1: the rest of the website is missing on the branch"
! show data-release:data/published/combined.ttl > /dev/null || fail "1: combined.ttl handed over"
echo "ok   1 branch data-release: the live publications (old one removed) + manifest; main untouched"

c1=$(git -C "$T/website.git" rev-parse data-release)
run && grep -q "already on the branch" "$T/out" && [ "$(git -C "$T/website.git" rev-parse data-release)" = "$c1" ] \
  || fail "2: re-run should do nothing"
echo "ok   2 same release again: nothing pushed"

live a b; run || fail "3: changed release"
[ "$(files data-release)" = "data/published/a.ttl data/published/b.ttl data/release-manifest.json data/vocab/topics.ttl " ] \
  || fail "3: branch content: $(files data-release)"
echo "ok   3 changed release replaces the branch"

git -C "$T/website.git" update-ref refs/heads/main refs/heads/data-release   # the owner merged
run && grep -q "main already has" "$T/out" || fail "4: after the merge nothing should happen"
echo "ok   4 after the merge: nothing to do"

c2=$(git -C "$T/website.git" rev-parse data-release)
live a c; echo tampered >> "$T/releases/live/published/c.ttl"
! run && grep -q "differs from the live manifest" "$T/out" && [ "$(git -C "$T/website.git" rev-parse data-release)" = "$c2" ] \
  || fail "5: a file that differs from the manifest must stop the hand-over"
echo "ok   5 file differs from the manifest: refused, nothing pushed"
