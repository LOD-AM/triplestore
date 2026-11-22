#!/usr/bin/env bash
# Load knowledge-graph `main` into <https://lod-am.net/graph/knowledge-graph> (LOD-AM/planning#35).
#
#   sudo scripts/update_kg.sh             load data/ of the latest main if it changed and its CI passed
#   sudo scripts/update_kg.sh --force     load it even if that data/ is already live
#   sudo scripts/update_kg.sh --rollback  put the previous one back
#
# Started daily by lodam-update-kg.timer (deploy/), or by hand. Steps:
#   1. fetch: knowledge-graph `main` (public; a shallow git fetch into releases/knowledge-graph/repo)
#   2. skip if data/ is the same as the live one (git tree hash): a change in docs/, tools/ or
#      examples/ alone loads nothing
#   3. gate: every GitHub check of that commit has passed (the API without a token, public repo).
#      Checks still running: nothing to do, the next run picks it up. A failed check: FAIL (mailed),
#      the graph stays as it is.
#   4. parse: every data/**/*.ttl with Jena's riot (the parser Fuseki uses) into one N-Triples
#      file, plus the graph's description (which commit is live); a parse error rejects the commit
#   5. load in ONE Graph Store PUT (one transaction), then the graph must hold exactly the parsed
#      distinct triples; then reindex and smoke test. Any failure puts the graph back as it was
#      before (a copy taken just before the PUT, so this also covers the first run)
#   6. releases/knowledge-graph/live/ = the loaded graph, previous/ = the one before
# Only data/ goes in (owner, 2026-11-22: examples/ stays out of the public graph).
# Shares the lock with scripts/update_published.sh (both reindex, which stops Fuseki): this
# script waits for a running release update instead of skipping.
# Config (.env, all optional): LODAM_KG_REPO (default https://github.com/LOD-AM/knowledge-graph.git),
# LODAM_KG_API (default https://api.github.com; the checks are read from there).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
[ -f .env ] && set -a && . ./.env && set +a
FUSEKI_URL="${FUSEKI_URL:-http://localhost:3030}"
: "${FUSEKI_ADMIN_PASSWORD:?set FUSEKI_ADMIN_PASSWORD (in .env or the environment)}"
GRAPH=https://lod-am.net/graph/knowledge-graph
REPO=${LODAM_KG_REPO:-https://github.com/LOD-AM/knowledge-graph.git}
API=${LODAM_KG_API:-https://api.github.com}
K=${LODAM_KG_RELEASES:-$ROOT/releases/knowledge-graph}
MODE=${1:-update}
log() { echo "update-kg: $*"; }

exec 9> "${LODAM_LOCK:-/run/lodam-update-published.lock}"
flock -w 1800 9 || { log "FAIL: a release update has held the lock for 30 minutes"; exit 1; }

sparql_count() { curl -sS -G -H "Accept: text/csv" --data-urlencode "query=$1" "$FUSEKI_URL/LOD-AM/sparql" | tail -n 1 | tr -d '\r'; }
graph_count() { sparql_count "SELECT (COUNT(*) AS ?n) WHERE { GRAPH <$GRAPH> { ?s ?p ?o } }"; }
gsp() { # method [file]: the knowledge-graph graph with the admin login (password via stdin, not argv)
  local args=(-X "$1"); [ -n "${2:-}" ] && args+=(-H "Content-Type: application/n-triples" --data-binary "@$2")
  printf 'user = "admin:%s"\n' "$FUSEKI_ADMIN_PASSWORD" |
    curl -sS -K - --fail-with-body "${args[@]}" "$FUSEKI_URL/LOD-AM/data?graph=$GRAPH" > /dev/null
}
reindex() { "${LODAM_REINDEX:-scripts/reindex.sh}" 9>&-; }   # the lock stays with this script
smoke() { scripts/smoke_test.sh --min-triples "$1"; }
put_back() { # $1: the graph as it was before the PUT
  log "putting the graph back as it was"
  if [ -s "$1" ]; then gsp PUT "$1"; else gsp DELETE || true; fi
  reindex || true
}
load() { # file.nt expected: one PUT, count, reindex, smoke test; put back on failure
  local code   # the graph as it is now, for put_back; 404 = it does not exist yet (empty)
  code=$(printf 'user = "admin:%s"\n' "$FUSEKI_ADMIN_PASSWORD" | curl -sS -K - -H "Accept: application/n-triples" \
    -o "$K/before.nt" -w '%{http_code}' "$FUSEKI_URL/LOD-AM/data?graph=$GRAPH") || code=000
  case $code in
    200) ;;
    404) : > "$K/before.nt" ;;
    *) log "FAIL: could not save the current graph before the load (HTTP $code); nothing changed"; exit 1 ;;
  esac
  gsp PUT "$1"
  local got; got=$(graph_count)
  [ "$got" = "$2" ] || { log "FAIL: <$GRAPH> has $got triples after the load, expected $2"; put_back "$K/before.nt"; exit 1; }
  if ! reindex || ! smoke "$2"; then log "FAIL: reindex or smoke test failed after the load"; put_back "$K/before.nt"; exit 1; fi
  rm -f "$K/before.nt"
}
distinct() { sort -u "$1" | grep -c .; }

mkdir -p "$K"
if [ "$MODE" = --rollback ]; then
  [ -f "$K/previous/graph.nt" ] || { log "FAIL: no previous graph in $K/previous/"; exit 1; }
  load "$K/previous/graph.nt" "$(distinct "$K/previous/graph.nt")"
  rm -rf "$K/rollback-tmp"; mv "$K/live" "$K/rollback-tmp"; mv "$K/previous" "$K/live"; mv "$K/rollback-tmp" "$K/previous"
  log "rolled back: live is knowledge-graph $(cat "$K/live/commit"), the undone one is in previous/"; exit 0
fi
[ "$MODE" = update ] || [ "$MODE" = --force ] || { sed -n '2,6p' "$0"; exit 2; }

# 1. fetch
G=$K/repo
if [ ! -d "$G/.git" ]; then rm -rf "$G"; git init --quiet -b main "$G"; fi
git -C "$G" remote remove origin 2> /dev/null || true
git -C "$G" remote add origin "$REPO"
git -C "$G" fetch --quiet --depth 1 origin "+refs/heads/main:refs/remotes/origin/main"
commit=$(git -C "$G" rev-parse origin/main)
tree=$(git -C "$G" rev-parse "origin/main:data")
short=${commit:0:7}

# 2. changed?
if [ "$MODE" != --force ] && [ "$(cat "$K/live/tree" 2> /dev/null)" = "$tree" ]; then
  log "data/ of knowledge-graph $short is already live; nothing to do"; exit 0
fi

# 3. gate: the commit's checks on GitHub
checks=$(curl -sS --fail --max-time 30 -H "Accept: application/vnd.github+json" \
  "$API/repos/LOD-AM/knowledge-graph/commits/$commit/check-runs?per_page=100") \
  || { log "FAIL: could not read the checks of knowledge-graph $short from $API"; exit 1; }
verdict=$(python3 -c '
import json, sys
runs = json.load(sys.stdin).get("check_runs", [])
if not runs: print("none")
elif any(r.get("status") != "completed" for r in runs): print("running")
else:
    bad = sorted(r.get("name", "?") for r in runs if r.get("conclusion") not in ("success", "neutral", "skipped"))
    print("failed " + ", ".join(bad) if bad else "passed %d" % len(runs))' <<< "$checks")
case $verdict in
  passed*) log "knowledge-graph $short: data/ changed, checks passed (${verdict#passed } run(s))" ;;
  running|none) log "knowledge-graph $short: checks not finished yet ($verdict); the next run loads it"; exit 0 ;;
  *) log "FAIL: knowledge-graph $short is not loaded, its checks failed: ${verdict#failed }; the graph stays as it is"; exit 1 ;;
esac

# 4. parse data/ (world-readable: riot runs in the Fuseki image as UID 9008, scripts/riot.sh)
rm -rf "$K/incoming"; mkdir -p "$K/incoming/data"
git -C "$G" archive origin/main data | tar -x -C "$K/incoming" --no-same-permissions
chmod -R a+rX "$K/incoming"
mapfile -t files < <(find "$K/incoming/data" -name '*.ttl' | sort)
[ ${#files[@]} -ge 1 ] || { log "FAIL: knowledge-graph $short has no data/**/*.ttl"; exit 1; }
if ! scripts/riot.sh --quiet --output=ntriples "${files[@]}" > "$K/incoming/riot.out" 2> "$K/incoming/riot.err"; then
  log "FAIL: knowledge-graph $short rejected, riot could not parse data/:"; cat "$K/incoming/riot.out" "$K/incoming/riot.err" | tail -5; exit 1
fi
# riot logs its warnings to stdout too: keep the N-Triples lines, show the rest
grep -E '^(<|_:)' "$K/incoming/riot.out" > "$K/incoming/data.nt" || true
grep -vE '^(<|_:)' "$K/incoming/riot.out" | head -5 | sed 's/^/update-kg: riot: /' || true
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{ cat "$K/incoming/data.nt"
  echo "<$GRAPH> <http://purl.org/dc/terms/identifier> \"knowledge-graph commit $commit, data/\" ."
  echo "<$GRAPH> <http://purl.org/dc/terms/modified> \"$now\"^^<http://www.w3.org/2001/XMLSchema#dateTime> ."
  echo "<$GRAPH> <http://purl.org/dc/terms/source> <https://github.com/LOD-AM/knowledge-graph/tree/$commit/data> ."
} > "$K/incoming/graph.nt"
expected=$(distinct "$K/incoming/graph.nt")
log "parsed ${#files[@]} file(s) of data/: $expected distinct triples with the graph description"

# 5. load (puts the old graph back on failure)
load "$K/incoming/graph.nt" "$expected"

# 6. promote
echo "$commit" > "$K/incoming/commit"; echo "$tree" > "$K/incoming/tree"
rm -rf "$K/incoming/data" "$K/incoming/data.nt" "$K/incoming/riot.out" "$K/incoming/riot.err" "$K/previous"
[ -d "$K/live" ] && mv "$K/live" "$K/previous"
mv "$K/incoming" "$K/live"
log "knowledge-graph $short is live in <$GRAPH> ($expected triples)"
