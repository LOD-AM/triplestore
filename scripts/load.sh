#!/usr/bin/env bash
# Load Turtle files into a named graph of the LOD-AM dataset via the Graph Store Protocol.
# Needs the admin password (from .env).
#
#   scripts/load.sh [--replace] [--graph IRI] FILE_OR_DIR...
#   scripts/load.sh --replace ../knowledge-graph/data ../knowledge-graph/examples
#
# The graph defaults to <https://lod-am.net/graph/knowledge-graph>. The released publications
# (<https://lod-am.net/graph/published>) are loaded by scripts/update_published.sh, not by hand.
# Queries see all named graphs (tdb:unionDefaultGraph, LOD-AM/planning#7), so the default
# graph is never loaded: TDB1 would hide it.
# --replace first empties the graph, so it holds exactly the given files afterwards; without it,
# files are added to what is there. Re-loading a file without --replace duplicates its blank
# nodes, so use --replace for re-loads. After --replace run `sudo scripts/reindex.sh` (clearing a
# graph leaves its labels in the text index). Directories are searched for *.ttl.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] && set -a && . ./.env && set +a
FUSEKI_URL="${FUSEKI_URL:-http://localhost:3030}"
: "${FUSEKI_ADMIN_PASSWORD:?set FUSEKI_ADMIN_PASSWORD (in .env or the environment)}"

replace=false
graph=https://lod-am.net/graph/knowledge-graph
while [ $# -gt 0 ]; do
  case $1 in
    --replace) replace=true; shift ;;
    --graph) graph=${2:?--graph needs an IRI}; shift 2 ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || { sed -n '2,15p' "$0"; exit 2; }
[[ $graph =~ ^https?://[^[:space:]\<\>\"]+$ ]] || { echo "not an http(s) IRI: $graph" >&2; exit 2; }
GSP="$FUSEKI_URL/LOD-AM/data?graph=$graph"

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
  echo "$method $f → <$graph>"
  gsp "$method" "$f"
  method=POST
done

count() { curl -sS -G -H "Accept: text/csv" --data-urlencode "query=$1" "$FUSEKI_URL/LOD-AM/sparql" | tail -n 1 | tr -d '\r'; }
echo "done: ${#files[@]} file(s) loaded; <$graph> has $(count "SELECT (COUNT(*) AS ?n) WHERE { GRAPH <$graph> { ?s ?p ?o } }") triples," \
  "all graphs together $(count 'SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }')"
