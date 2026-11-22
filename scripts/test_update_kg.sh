#!/usr/bin/env bash
# Integration test of scripts/update_kg.sh against a running Fuseki (LOD-AM/planning#35).
# WRITES to <https://lod-am.net/graph/knowledge-graph>: never run it on the production server.
#
#   LODAM_TEST=1 scripts/test_update_kg.sh <knowledge-graph checkout>     (CI: knowledge-graph)
#
# A local stand-in repository with the checkout's data/ and examples/ replaces GitHub, and the
# commit's checks are files (LODAM_KG_API=file://…). Checks:
#   1. first load: only data/ (not examples/), the graph's description names the commit; a graph
#      loaded by hand before is replaced
#   2. the same data/ again, and a commit that changes only examples/: nothing to do
#   3. checks still running: nothing to do (exit 0); a failed check: FAIL, graph unchanged
#   4. a Turtle syntax error in data/: rejected, graph unchanged
#   5. a failure after the load (reindex fails): the graph is put back
#   6. new data/ replaces the graph, previous/ keeps the old one; --rollback brings it back
set -euo pipefail
cd "$(dirname "$0")/.."
[ "${LODAM_TEST:-}" = 1 ] || { echo "refusing: this test writes to Fuseki; set LODAM_TEST=1 (never on production)" >&2; exit 2; }
KG=$(realpath "${1:?usage: LODAM_TEST=1 scripts/test_update_kg.sh <knowledge-graph checkout>}")
[ -f .env ] && set -a && . ./.env && set +a
FUSEKI_URL="${FUSEKI_URL:-http://localhost:3030}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
chmod 755 "$T"   # riot runs in the Fuseki image as UID 9008 (scripts/riot.sh)
export LODAM_KG_REPO=$T/kg.git LODAM_KG_API=file://$T/api LODAM_KG_RELEASES=$T/releases LODAM_LOCK=$T/lock
GRAPH=https://lod-am.net/graph/knowledge-graph
q() { curl -sS -G -H "Accept: text/csv" --data-urlencode "query=$1" "$FUSEKI_URL/LOD-AM/sparql" | tail -n +2 | tr -d '\r'; }
gcount() { q "SELECT (COUNT(*) AS ?n) WHERE { GRAPH <$GRAPH> { ?s ?p ?o } }"; }
fail() { echo "FAIL $1"; tail -20 "$T/out" 2>/dev/null; exit 1; }
upd() { scripts/update_kg.sh "$@" > "$T/out" 2>&1; }
riot_count() { scripts/riot.sh --quiet --output=ntriples "$@" | grep -E "^(<|_:)" | sort -u | grep -c .; }

git init -q --bare -b main "$T/kg.git"; git clone -q "$T/kg.git" "$T/work" 2> /dev/null
cp -r "$KG/data" "$KG/examples" "$T/work/"
gc() { git -C "$T/work" add -A; git -C "$T/work" -c user.name=t -c user.email=t@example.invalid commit -qm "$1"
       git -C "$T/work" push -q origin main; git -C "$T/work" rev-parse HEAD; }
checks() { # commit status conclusion
  mkdir -p "$T/api/repos/LOD-AM/knowledge-graph/commits/$1"
  printf '{"total_count": 1, "check_runs": [{"name": "check", "status": "%s", "conclusion": %s}]}' "$2" "$3" \
    > "$T/api/repos/LOD-AM/knowledge-graph/commits/$1/check-runs"
}
c1=$(gc one); checks "$c1" completed '"success"'
mapfile -t dfiles < <(find "$T/work/data" -name '*.ttl' | sort)
n_data=$(riot_count "${dfiles[@]}")
n1=$((n_data + 3))   # + the graph's description (identifier, modified, source)

# 1. first load, over a graph loaded by hand (data + examples, as before planning#35)
scripts/load.sh --replace "$KG/data" "$KG/examples" > /dev/null
before=$(gcount)
upd || fail "1: first load"
[ "$(gcount)" = "$n1" ] || fail "1: graph has $(gcount) triples, expected $n1 (data/ $n_data + 3; before: $before with examples)"
[ "$(q "ASK { GRAPH <$GRAPH> { <$GRAPH> <http://purl.org/dc/terms/source> <https://github.com/LOD-AM/knowledge-graph/tree/$c1/data> } }")" = true ] \
  || fail "1: description does not name the commit"
[ "$(cat "$T/releases/live/commit")" = "$c1" ] || fail "1: live/commit"
echo "ok 1 first load: data/ only ($n1 triples; $before before with examples), description names the commit"

# 2. unchanged data/; a commit that changes only examples/
upd && grep -q "already live" "$T/out" || fail "2: same data/ not skipped"
echo "# test" >> "$T/work/examples/lod-am-example.ttl"; c2=$(gc examples-only); checks "$c2" completed '"success"'
upd && grep -q "already live" "$T/out" || fail "2: examples-only commit not skipped"
echo "ok 2 same data/ and an examples-only commit: nothing to do"

# 3. checks running / failed
printf '\n<https://lod-am.net/id/test_kg> <http://www.w3.org/2000/01/rdf-schema#label> "Kgtestlabel"@en .\n' >> "${dfiles[0]}"
c3=$(gc new-triple); checks "$c3" in_progress null
upd && grep -q "checks not finished" "$T/out" || fail "3: running checks not waited for"
checks "$c3" completed '"failure"'
upd && fail "3: failed checks accepted"
grep -q "checks failed: check" "$T/out" && [ "$(gcount)" = "$n1" ] || fail "3: failed checks: message or graph"
echo "ok 3 checks running: wait; checks failed: FAIL, graph unchanged"

# 4. syntax error
printf '\nthis is not turtle\n' > "$T/work/data/broken.ttl"; c4=$(gc broken); checks "$c4" completed '"success"'
upd && fail "4: broken Turtle accepted"
grep -q "riot could not parse" "$T/out" && [ "$(gcount)" = "$n1" ] || fail "4: broken Turtle: message or graph"
rm "$T/work/data/broken.ttl"
echo "ok 4 Turtle syntax error: rejected, graph unchanged"

# 5. failure after the load: put back
c5=$(gc fixed); checks "$c5" completed '"success"'
LODAM_REINDEX=false upd && fail "5: failed reindex accepted"
grep -q "putting the graph back" "$T/out" && [ "$(gcount)" = "$n1" ] || fail "5: graph not put back ($(gcount))"
[ "$(cat "$T/releases/live/commit")" = "$c1" ] || fail "5: live/ changed"
echo "ok 5 failure after the load: graph put back"

# 6. new data/ live, then rollback
upd || fail "6: new data/"
[ "$(gcount)" = "$((n1 + 1))" ] && [ "$(cat "$T/releases/previous/commit")" = "$c1" ] || fail "6: new data/ ($(gcount))"
upd --rollback || fail "6: rollback"
[ "$(gcount)" = "$n1" ] && [ "$(cat "$T/releases/live/commit")" = "$c1" ] || fail "6: rollback ($(gcount))"
echo "ok 6 new data/ replaces the graph; --rollback brings the previous one back"
echo "all update_kg tests passed"
