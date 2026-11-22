#!/usr/bin/env bash
# One-time migration to named graphs (owner, 2026-11-22, LOD-AM/planning#7), after deploying
# the assembler with tdb:unionDefaultGraph:
#   1. load the knowledge-graph data into <https://lod-am.net/graph/knowledge-graph>
#   2. only if that graph is not empty: delete the stored default graph, which the union hides
#      from queries but which still holds the old copy of the data
#   3. rebuild the text index (stops Fuseki for a few seconds), smoke test
#
#   sudo scripts/migrate_named_graphs.sh ../knowledge-graph/data ../knowledge-graph/examples
# Safe to run again. Tested with Fuseki 6.2.0 (jar from Maven Central, this assembler).
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { sed -n '2,10p' "$0"; exit 2; }
[ -f .env ] && set -a && . ./.env && set +a
FUSEKI_URL="${FUSEKI_URL:-http://localhost:3030}"
: "${FUSEKI_ADMIN_PASSWORD:?set FUSEKI_ADMIN_PASSWORD (in .env or the environment)}"
KG=https://lod-am.net/graph/knowledge-graph
grep -q 'tdb:unionDefaultGraph true' fuseki-config/assembler.ttl \
  || { echo "FAIL: fuseki-config/assembler.ttl has no tdb:unionDefaultGraph (git pull first)" >&2; exit 1; }

scripts/load.sh --replace --graph "$KG" "$@"
n=$(curl -sS -G -H "Accept: text/csv" --data-urlencode "query=SELECT (COUNT(*) AS ?n) WHERE { GRAPH <$KG> { ?s ?p ?o } }" \
  "$FUSEKI_URL/LOD-AM/sparql" | tail -n 1 | tr -d '\r')
[ "${n:-0}" -gt 0 ] 2>/dev/null || { echo "FAIL: <$KG> is empty after loading; the default graph is left as it is" >&2; exit 1; }
if [ "${FUSEKI_RUNNING_UNION:-}" != checked ]; then
  # A query without GRAPH must now see the knowledge graph: proof that the union is active
  u=$(curl -sS -G -H "Accept: text/csv" --data-urlencode "query=SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }" \
    "$FUSEKI_URL/LOD-AM/sparql" | tail -n 1 | tr -d '\r')
  [ "${u:-0}" -ge "$n" ] 2>/dev/null || { echo "FAIL: queries don't see <$KG> ($u < $n): is Fuseki running with the new assembler? (docker compose up -d --force-recreate fuseki)" >&2; exit 1; }
fi
printf 'user = "admin:%s"\n' "$FUSEKI_ADMIN_PASSWORD" |
  curl -sS -K - --fail-with-body -X DELETE "$FUSEKI_URL/LOD-AM/data?default" > /dev/null
echo "deleted the stored default graph (its data is now in <$KG>: $n triples)"
"${LODAM_REINDEX:-scripts/reindex.sh}"
scripts/smoke_test.sh --min-triples "$n"
