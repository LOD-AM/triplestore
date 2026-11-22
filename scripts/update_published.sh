#!/usr/bin/env bash
# Pull, check, load and swap a release of the released publications (LOD-AM/planning#7).
#
#   sudo scripts/update_published.sh            fetch the release from the data LXC; load it if new
#   sudo scripts/update_published.sh --force    load it even if it is already live
#   sudo scripts/update_published.sh --rollback put the previous release back
#
# Started by the webhook from the pipeline run (deploy/webhook.py) and by a daily timer as a
# fallback (deploy/), or by hand. Steps:
#   1. fetch: rsync of the pipeline's out/release/ into releases/incoming/. Over SSH with a key the
#      data LXC restricts to reading that directory (rrsync -ro); the data LXC has no access here.
#   2. check (scripts/release.py): all checks passed, clean commits, every listed file present with
#      its sha256 and nothing else; then the triples of each file counted with Jena's riot (the
#      parser Fuseki uses) against the manifest
#   3. load: the publications plus the graph's description in ONE Graph Store PUT into
#      <https://lod-am.net/graph/published>: a single transaction, so queries see the old or the
#      new release, never a mix; then the graph's triple count must match
#   4. rebuild the text index (replacing a graph leaves stale labels; Fuseki stops a few seconds)
#      and run the smoke test
#   5. the release becomes releases/live/, the one before releases/previous/
# Any failure after the load puts the live release back (or empties the graph if there was none),
# so the graph only ever holds a fully checked release.
# Config (.env): LODAM_RELEASE_SOURCE (e.g. lodam-release@data-lxc.lan: or a local directory),
# LODAM_RELEASE_SSH_KEY (default /root/.ssh/lodam-release).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
[ -f .env ] && set -a && . ./.env && set +a
FUSEKI_URL="${FUSEKI_URL:-http://localhost:3030}"
: "${FUSEKI_ADMIN_PASSWORD:?set FUSEKI_ADMIN_PASSWORD (in .env or the environment)}"
GRAPH=https://lod-am.net/graph/published
R=$ROOT/releases
MODE=${1:-update}
log() { echo "update-published: $*"; }

exec 9> "${LODAM_LOCK:-/run/lodam-update-published.lock}"
flock -n 9 || { log "another update is in progress; nothing to do"; exit 0; }

sparql_count() { curl -sS -G -H "Accept: text/csv" --data-urlencode "query=$1" "$FUSEKI_URL/LOD-AM/sparql" | tail -n 1 | tr -d '\r'; }
graph_count() { sparql_count "SELECT (COUNT(*) AS ?n) WHERE { GRAPH <$GRAPH> { ?s ?p ?o } }"; }
gsp() { # method [file]: write <published> with the admin login (password via stdin, not argv)
  local args=(-X "$1"); [ -n "${2:-}" ] && args+=(-H "Content-Type: text/turtle" --data-binary "@$2")
  printf 'user = "admin:%s"\n' "$FUSEKI_ADMIN_PASSWORD" |
    curl -sS -K - --fail-with-body "${args[@]}" "$FUSEKI_URL/LOD-AM/data?graph=$GRAPH" > /dev/null
}
riot() { scripts/riot.sh "$@"; }   # Jena's riot from the Fuseki image (no network, no database)
reindex() { "${LODAM_REINDEX:-scripts/reindex.sh}" 9>&-; }   # the lock stays with this script, not with Fuseki
smoke() { scripts/smoke_test.sh --min-triples "$1"; }

put_back() { # restore the live release after a failed load
  if [ -f "$R/live/combined.ttl" ]; then log "putting the live release back"; gsp PUT "$R/live/combined.ttl"
  else log "no earlier release: emptying <$GRAPH>"; gsp DELETE || true; fi
  reindex || true
}

if [ "$MODE" = --rollback ]; then
  [ -f "$R/previous/combined.ttl" ] || { log "FAIL: no previous release in releases/previous/"; exit 1; }
  gsp PUT "$R/previous/combined.ttl"; reindex; smoke "$(graph_count)"
  rm -rf "$R/rollback-tmp"; mv "$R/live" "$R/rollback-tmp"; mv "$R/previous" "$R/live"; mv "$R/rollback-tmp" "$R/previous"
  log "rolled back: live is $(cat "$R/live/manifest.sha256"), the undone release is in releases/previous/"
  exit 0
fi
[ "$MODE" = update ] || [ "$MODE" = --force ] || { sed -n '2,6p' "$0"; exit 2; }

# 1. fetch
: "${LODAM_RELEASE_SOURCE:?set LODAM_RELEASE_SOURCE in .env (e.g. lodam-release@data-lxc.lan:)}"
mkdir -p "$R"; rm -rf "$R/incoming"; mkdir "$R/incoming"
ssh_opts=()
if [[ $LODAM_RELEASE_SOURCE == *:* ]]; then
  ssh_opts=(-e "ssh -i ${LODAM_RELEASE_SSH_KEY:-/root/.ssh/lodam-release} -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new")
fi
rsync -rt "${ssh_opts[@]}" "${LODAM_RELEASE_SOURCE%/}/" "$R/incoming/"
sha=$(sha256sum "$R/incoming/manifest.json" 2>/dev/null | cut -d' ' -f1 || true)
[ -n "$sha" ] || { log "FAIL: the source has no manifest.json (no release built yet?)"; exit 1; }
if [ "$MODE" != --force ] && [ -f "$R/live/manifest.sha256" ] && [ "$(cat "$R/live/manifest.sha256")" = "$sha" ]; then
  log "release $sha is already live; nothing to do"; exit 0
fi

# 2. check
listed=$(python3 scripts/release.py verify "$R/incoming")
while read -r file triples; do
  out=$(riot --count "$R/incoming/$file" 2>&1) || true
  got=$(sed -n 's/.*Triples = \([0-9,]*\).*/\1/p' <<< "$out" | tr -d ',')
  [ -n "$got" ] || { log "FAIL: riot could not count $file:"; tail -5 <<< "$out"; exit 1; }
  [ "$got" = "$triples" ] || { log "FAIL: release rejected: $file has $got triples, the manifest says $triples"; exit 1; }
done <<< "$listed"
python3 scripts/release.py combine "$R/incoming" "$R/incoming/combined.ttl"
riot --output=ntriples "$R/incoming/combined.ttl" > "$R/incoming/combined.nt"
if grep -qE '(^| )_:' "$R/incoming/combined.nt"; then log "FAIL: release rejected: blank nodes (the pipeline emits none; the count check needs that)"; exit 1; fi
expected=$(sort -u "$R/incoming/combined.nt" | grep -c .)
log "release $sha checked: $(wc -l <<< "$listed") publication(s), $expected distinct triples with the graph description"

# 3. load, one transaction
gsp PUT "$R/incoming/combined.ttl"
got=$(graph_count)
[ "$got" = "$expected" ] || { log "FAIL: <$GRAPH> has $got triples after the load, expected $expected"; put_back; exit 1; }

# 4. index and smoke test
if ! reindex || ! smoke "$expected"; then log "FAIL: reindex or smoke test failed after the load"; put_back; exit 1; fi

# 5. promote
echo "$sha" > "$R/incoming/manifest.sha256"
rm -f "$R/incoming/combined.nt"
rm -rf "$R/previous"; before="this is the first release"
[ -d "$R/live" ] && mv "$R/live" "$R/previous" && before="the one before is in releases/previous/"
mv "$R/incoming" "$R/live"
log "release $sha is live in <$GRAPH> ($expected triples); $before"
