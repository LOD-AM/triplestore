#!/usr/bin/env bash
# Tests of deploy/webhook.py (LOD-AM/planning#7): a temporary receiver on 127.0.0.1, no systemd.
# Only a POST with the right token and a valid sha writes the trigger; the token is never logged;
# a short token is refused at start.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'kill "${pid:-0}" 2>/dev/null || true; rm -rf "$T"' EXIT
python3 -c "import secrets; print(secrets.token_hex(32))" > "$T/token"
PORT=${LODAM_TEST_PORT:-9399}
LODAM_WEBHOOK_LISTEN=127.0.0.1:$PORT LODAM_WEBHOOK_TOKEN_FILE=$T/token LODAM_WEBHOOK_TRIGGER=$T/run/trigger \
  python3 deploy/webhook.py > "$T/log" 2>&1 & pid=$!
for _ in $(seq 1 50); do grep -q listening "$T/log" 2>/dev/null && break; sleep 0.1; done
TOK=$(cat "$T/token"); U=http://127.0.0.1:$PORT; SHA=$(printf 'a%.0s' $(seq 1 64))
c() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
expect() { [ "$2" = "$3" ] || { echo "FAIL $1: expected $2, got $3"; cat "$T/log"; exit 1; }; echo "ok   $1 ($3)"; }

expect "no token" 401 "$(c -X POST --data "{\"manifest_sha256\": \"$SHA\"}" "$U/lodam-release")"
expect "wrong token" 401 "$(c -X POST -H "Authorization: Bearer x$TOK" --data "{\"manifest_sha256\": \"$SHA\"}" "$U/lodam-release")"
[ ! -e "$T/run/trigger" ] || { echo "FAIL trigger written without a valid token"; exit 1; }
expect "bad sha" 400 "$(c -X POST -H "Authorization: Bearer $TOK" --data '{"manifest_sha256": "../../etc"}' "$U/lodam-release")"
expect "not JSON" 400 "$(c -X POST -H "Authorization: Bearer $TOK" --data 'hello' "$U/lodam-release")"
expect "body too large" 413 "$(c -X POST -H "Authorization: Bearer $TOK" --data "$(head -c 2000 /dev/zero | tr '\0' a)" "$U/lodam-release")"
expect "other path" 404 "$(c -X POST -H "Authorization: Bearer $TOK" "$U/other")"
expect "GET" 405 "$(c "$U/lodam-release")"
[ ! -e "$T/run/trigger" ] || { echo "FAIL trigger written by an invalid request"; exit 1; }
# exactly what LOD-AM/pipeline deploy/run.sh sends
expect "valid signal" 202 "$(c -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOK" \
  --data "{\"manifest_sha256\": \"$SHA\"}" "$U/lodam-release")"
grep -q "^$SHA " "$T/run/trigger" || { echo "FAIL trigger does not hold the sha"; exit 1; }
echo "ok   trigger written with the sha"
! grep -q "$TOK" "$T/log" || { echo "FAIL the token appears in the log"; exit 1; }
echo "ok   token never logged"
echo short > "$T/short"
if LODAM_WEBHOOK_TOKEN_FILE=$T/short LODAM_WEBHOOK_TRIGGER=$T/x python3 deploy/webhook.py > "$T/log2" 2>&1; then
  echo "FAIL started with a short token"; exit 1; fi
grep -q "at least 32" "$T/log2" && echo "ok   short token refused at start"
