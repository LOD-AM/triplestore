#!/usr/bin/env bash
# Check a running LOD-AM Fuseki: health, public query, write protection, triples, text search.
# Safe on production: it never writes. The write probe sends invalid Turtle,
# so even an unprotected server rejects it (400) without storing anything.
#
#   scripts/smoke_test.sh [--min-triples N]
#   scripts/smoke_test.sh --public [URL]      the public side, from anywhere (default https://triple.lod-am.net)
# Uses FUSEKI_URL (default http://localhost:3030) and, if set,
# FUSEKI_ADMIN_PASSWORD (from .env) to check that the admin login works.
# --public checks what the proxy lets through (planning review 2026-11-25, 5.1): only the query
# endpoints answer; the Graph Store, the dataset, the admin API and the UI get 403 and never reach
# Fuseki. The server's scripts use localhost and don't depend on this.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
[ -f .env ] && set -a && . ./.env && set +a
URL="${FUSEKI_URL:-http://localhost:3030}"
min=0; public=""
case "${1:-}" in
  --min-triples) min="$2" ;;
  --public) public="${2:-https://triple.lod-am.net}" ;;
esac
fail=0

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check() { # name expected actual
  if [ "$3" = "$2" ]; then echo "ok   $1 ($3)"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}

if [ -n "$public" ]; then
  check "public query GET /LOD-AM/sparql" 200 "$(code -G --data-urlencode 'query=ASK {}' "$public/LOD-AM/sparql")"
  check "public query POST /LOD-AM/sparql" 200 "$(code --data-urlencode 'query=ASK {}' "$public/LOD-AM/sparql")"
  check "public query GET /LOD-AM/query" 200 "$(code -G --data-urlencode 'query=ASK {}' "$public/LOD-AM/query")"
  check "CORS preflight from https://lod-am.net" 200 \
    "$(code -X OPTIONS -H 'Origin: https://lod-am.net' -H 'Access-Control-Request-Method: POST' "$public/LOD-AM/sparql")"
  for p in /LOD-AM/data /LOD-AM '/$/datasets' '/$/ping' / '/LOD-AM/sparql/../data'; do
    check "public $p is blocked by the proxy" 403 "$(code --path-as-is "$public$p")"
  done
  check "public write to /LOD-AM/data is blocked by the proxy" 403 \
    "$(code -X POST -H 'Content-Type: text/turtle' --data-binary 'invalid turtle !!!' "$public/LOD-AM/data?graph=urn:lod-am:smoke-test")"
  [ $fail = 0 ] && echo "public side passed" || echo "public side FAILED"
  exit $fail
fi

check "health /\$/ping" 200 "$(code "$URL/\$/ping")"
check "public query /LOD-AM/sparql" 200 "$(code -G --data-urlencode 'query=ASK {}' "$URL/LOD-AM/sparql")"
check "anonymous write /LOD-AM/data is refused" 401 \
  "$(code -X POST -H 'Content-Type: text/turtle' --data-binary 'invalid turtle !!!' "$URL/LOD-AM/data?graph=urn:lod-am:smoke-test")"
check "anonymous write /LOD-AM is refused" 401 \
  "$(code -X POST -H 'Content-Type: text/turtle' --data-binary 'invalid turtle !!!' "$URL/LOD-AM?graph=urn:lod-am:smoke-test")"
check "anonymous admin API is refused" 401 "$(code "$URL/\$/datasets")"
if [ -n "${FUSEKI_ADMIN_PASSWORD:-}" ]; then
  check "admin login works" 200 "$(printf 'user = "admin:%s"\n' "$FUSEKI_ADMIN_PASSWORD" | code -K - "$URL/\$/datasets")"
fi

# All named graphs together (tdb:unionDefaultGraph, LOD-AM/planning#7), then each one for the log
n=$(curl -s -G -H 'Accept: text/csv' --data-urlencode 'query=SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }' "$URL/LOD-AM/sparql" | tail -n 1 | tr -d '\r')
if [ "${n:-0}" -ge "$min" ] 2>/dev/null; then echo "ok   all graphs together have $n triples (min $min)"; else echo "FAIL all graphs together have '$n' triples, expected at least $min"; fail=1; fi
curl -s -G -H 'Accept: text/csv' --data-urlencode 'query=SELECT ?g (COUNT(*) AS ?n) WHERE { GRAPH ?g { ?s ?p ?o } } GROUP BY ?g ORDER BY ?g' \
  "$URL/LOD-AM/sparql" | tail -n +2 | tr -d '\r' | sed 's/^/     graph /; s/,/: /'

# Text index: one simple label from the data must be found by text:query.
# Fails if the index is missing or empty: run scripts/reindex.sh.
sparql() { curl -s -G -H 'Accept: text/csv' --data-urlencode "query=$1" "$URL/LOD-AM/sparql" | tail -n +2 | tr -d '\r'; }
label=$(sparql 'PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
  SELECT ?l WHERE { ?s rdfs:label ?l FILTER(REGEX(STR(?l), "^[A-Za-z]{4,}$")) } LIMIT 1')
if [ -z "$label" ]; then
  echo "skip text search (no simple rdfs:label in the data)"
else
  hits=$(sparql "PREFIX text: <http://jena.apache.org/text#>
    SELECT (COUNT(*) AS ?n) WHERE { (?s ?score ?l) text:query (\"$label\") }")
  if [ "${hits:-0}" -ge 1 ] 2>/dev/null; then echo "ok   text search finds \"$label\" ($hits hits)"
  else echo "FAIL text search for \"$label\": '$hits' hits (index empty? run scripts/reindex.sh)"; fail=1; fi
fi

[ $fail = 0 ] && echo "smoke test passed" || echo "smoke test FAILED"
exit $fail
