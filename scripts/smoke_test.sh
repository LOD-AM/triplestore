#!/usr/bin/env bash
# Check a running LOD-AM Fuseki: health, public query, write protection.
# Safe on production: it never writes. The write probe sends invalid Turtle,
# so even an unprotected server rejects it (400) without storing anything.
#
#   scripts/smoke_test.sh [--min-triples N]
# Uses FUSEKI_URL (default http://localhost:3030) and, if set,
# FUSEKI_ADMIN_PASSWORD (from .env) to check that the admin login works.
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a
URL="${FUSEKI_URL:-http://localhost:3030}"
min=0; [ "${1:-}" = "--min-triples" ] && min="$2"
fail=0

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check() { # name expected actual
  if [ "$3" = "$2" ]; then echo "ok   $1 ($3)"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}

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

n=$(curl -s -G -H 'Accept: text/csv' --data-urlencode 'query=SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }' "$URL/LOD-AM/sparql" | tail -n 1 | tr -d '\r')
if [ "${n:-0}" -ge "$min" ] 2>/dev/null; then echo "ok   default graph has $n triples (min $min)"; else echo "FAIL default graph has '$n' triples, expected at least $min"; fail=1; fi

[ $fail = 0 ] && echo "smoke test passed" || echo "smoke test FAILED"
exit $fail
