#!/usr/bin/env bash
# Jena's riot (RDF parser) from the Fuseki image, used to check releases (LOD-AM/planning#7):
#   scripts/riot.sh --count FILE.ttl          prints "... Triples = N"
#   scripts/riot.sh --output=ntriples FILE    N-Triples to stdout
# Runs in a throwaway container of the pinned image, without network and without the database;
# only the directories of the given files are mounted, read-only. With LODAM_RIOT_JAR (tests
# outside Docker) it runs that Fuseki jar instead.
set -euo pipefail
if [ -n "${LODAM_RIOT_JAR:-}" ]; then exec java -cp "$LODAM_RIOT_JAR" riotcmd.riot "$@"; fi
mounts=(); args=()
for a in "$@"; do
  if [[ $a != -* ]]; then
    f=$(realpath "$a"); d=$(dirname "$f")
    [[ " ${mounts[*]} " == *" -v $d:$d:ro "* ]] || mounts+=(-v "$d:$d:ro")
    args+=("$f")
  else args+=("$a"); fi
done
cd "$(dirname "$0")/.."            # after resolving the paths: compose needs the checkout
image=$(docker compose config --images fuseki 2>/dev/null ||   # older Compose: read it from the file
        sed -n 's|^ *image: *\(secoresearch/fuseki:[^ ]*\).*|\1|p' docker-compose.yml)
[ -n "$image" ] || { echo "riot.sh: no Fuseki image in docker-compose.yml" >&2; exit 1; }
# The container runs as the image's user (9008): the files must be world-readable (umask 022).
exec docker run --rm --network none --user 9008 "${mounts[@]}" --entrypoint /jena/bin/riot "$image" "${args[@]}"
