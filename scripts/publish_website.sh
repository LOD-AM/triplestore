#!/usr/bin/env bash
# Hand the live release to the website (LOD-AM/website#21): push its publications to the branch
# `data-release` of LOD-AM/website, where a workflow (.github/workflows/data-release.yml there)
# checks them, adds the AAT labels and a changelog entry and opens a pull request. The owner
# merges it; the website's usual build then deploys the entity pages.
#
#   sudo scripts/publish_website.sh      (normally run by scripts/update_published.sh)
#
# Only the files of releases/live/ go out: the release the triplestore checked and serves, which
# holds only released publications. The branch is rebuilt on the latest website `main` each time:
#   data/published/*.ttl        = the release's publications (a publication no longer released is removed)
#   data/release-manifest.json  = the release's manifest (provenance; no figures about the full graph)
# Nothing is pushed if `main` or the branch already has exactly these publications, so a
# re-run (daily timer, pipeline --force with unchanged data) does nothing.
# Config (.env): LODAM_WEBSITE_REPO (git@github.com:LOD-AM/website.git; unset = skipped),
# LODAM_WEBSITE_SSH_KEY (default /root/.ssh/lodam-website: a deploy key of LOD-AM/website with write access).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
[ -f .env ] && set -a && . ./.env && set +a
log() { echo "publish-website: $*"; }
REPO=${LODAM_WEBSITE_REPO:-}
[ -n "$REPO" ] || { log "LODAM_WEBSITE_REPO is not set in .env; the website is not updated"; exit 0; }
R=${LODAM_RELEASES:-$ROOT/releases}
LIVE=$R/live
BRANCH=data-release
W=$R/website                     # a checkout of the website, used only by this script
[ -f "$LIVE/manifest.json" ] || { log "no live release yet; nothing to hand over"; exit 0; }

if [[ $REPO == *:* && $REPO != /* ]]; then   # SSH remote: only this key, only GitHub's pinned host key
  export GIT_SSH_COMMAND="ssh -i ${LODAM_WEBSITE_SSH_KEY:-/root/.ssh/lodam-website} -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$ROOT/deploy/github_known_hosts"
fi
g() { git -C "$W" -c user.name="LOD-AM triplestore" -c user.email=noreply@lod-am.net "$@"; }

# The release's files, as its manifest lists them (sha256 checked once more before they leave)
files=$(python3 - "$LIVE" <<'PY'
import hashlib, json, re, sys
from pathlib import Path
d = Path(sys.argv[1]); m = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
for p in m["publications"]["files"]:
    name = p["file"]
    if not re.fullmatch(r"published/[A-Za-z0-9_.-]+\.ttl", name):
        sys.exit(f"FAIL: bad file name in the live manifest: {name!r}")
    if hashlib.sha256((d / name).read_bytes()).hexdigest() != p["sha256"]:
        sys.exit(f"FAIL: {name} differs from the live manifest")
    print(name)
PY
)
sha=$(sha256sum "$LIVE/manifest.json" | cut -c1-12)

if [ ! -d "$W/.git" ]; then rm -rf "$W"; git init --quiet -b main "$W"; g remote add origin "$REPO"; fi
g remote set-url origin "$REPO"
g fetch --quiet --depth 1 origin "+refs/heads/main:refs/remotes/origin/main"
has_branch=false
if g ls-remote --exit-code --heads origin "$BRANCH" > /dev/null; then
  g fetch --quiet --depth 1 origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"; has_branch=true
fi
g checkout --quiet --force -B "$BRANCH" origin/main
g clean --quiet -fdx
[ -d "$W/data/published" ] || { log "FAIL: the website has no data/published/ (wrong repository?)"; exit 1; }
find "$W/data/published" -maxdepth 1 -name '*.ttl' -delete
while read -r f; do cp "$LIVE/$f" "$W/data/published/"; done <<< "$files"
g add -A data/published            # staged, so new and removed files count in the comparisons

if g diff --cached --quiet origin/main -- data/published; then
  log "the website's main already has the publications of release $sha; nothing to do"; exit 0
fi
if $has_branch && g diff --cached --quiet "origin/$BRANCH" -- data/published; then
  log "release $sha is already on the branch $BRANCH (pull request waiting for the owner); nothing to do"; exit 0
fi
cp "$LIVE/manifest.json" "$W/data/release-manifest.json"
g add data/release-manifest.json
m() { python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print(m['pipeline']['commit'][:7], m['knowledge_graph']['commit'][:7])" "$LIVE/manifest.json"; }
read -r pc kc <<< "$(m)"
g commit --quiet -m "Data release $sha" \
  -m "The release live in the triplestore (manifest sha256 $sha…), from LOD-AM/pipeline $pc and LOD-AM/knowledge-graph $kc. Pushed by scripts/publish_website.sh of LOD-AM/triplestore (website#21)."
g push --quiet --force origin "HEAD:refs/heads/$BRANCH"
log "release $sha pushed to $BRANCH of the website; its workflow opens the pull request"
