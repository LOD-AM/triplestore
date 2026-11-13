#!/usr/bin/env bash
# Load Turtle files (e.g. from LOD-AM/knowledge-graph) into the LOD-AM dataset
# via the Graph Store Protocol. Needs the admin password (from .env).
#
#   scripts/load.sh [--replace] FILE_OR_DIR...
#   scripts/load.sh --replace ../knowledge-graph/data ../knowledge-graph/examples
#
# Data goes into the default graph. --replace first empties the default graph,
# so the store holds exactly the given files afterwards; without it, files are
# added to what is there. Re-loading a file without --replace duplicates its
# blank nodes, so use --replace for re-loads. Directories are searched for *.ttl.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] && set -a && . ./.env && set +a
FUSEKI_URL="${FUSEKI_URL:-http://localhost:3030}"
GSP="$FUSEKI_URL/LOD-AM/data?default"
: "${FUSEKI_ADMIN_PASSWORD:?set FUSEKI_ADMIN_PASSWORD (in .env or the environment)}"

replace=false
[ "${1:-}" = "--replace" ] && { replace=true; shift; }
[ $# -ge 1 ] || { sed -n '2,10p' "$0"; exit 2; }

files=()
for arg in "$@"; do
  if [ -d "$arg" ]; then while IFS= read -r f; do files+=("$f"); done < <(find "$arg" -name '*.ttl' | sort)
  elif [ -f "$arg" ]; then files+=("$arg")
  else echo "not found: $arg" >&2; exit 1; fi
done
[ ${#files[@]} -ge 1 ] || { echo "no .ttl files found" >&2; exit 1; }

# Password via curl config on stdin, so it never shows up in the process list.
gsp() { # method file
  printf 'user = "admin:%s"\n' "$FUSEKI_ADMIN_PASSWORD" |
    curl -sS -K - --fail-with-body -X "$1" -H "Content-Type: text/turtle" --data-binary "@$2" "$GSP" > /dev/null
}

method=POST; $replace && method=PUT
for f in "${files[@]}"; do
  echo "$method $f"
  gsp "$method" "$f"
  method=POST
done

count=$(curl -sS -G -H "Accept: text/csv" --data-urlencode \
  "query=SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }" "$FUSEKI_URL/LOD-AM/sparql" | tail -n 1 | tr -d '\r')
echo "done: ${#files[@]} file(s) loaded, default graph now has $count triples"
