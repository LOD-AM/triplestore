#!/usr/bin/env bash
# Jena's riot (RDF parser) from the Fuseki image, used to check releases (LOD-AM/planning#7):
#   scripts/riot.sh --count FILE.ttl          prints "... Triples = N"
#   scripts/riot.sh --output=ntriples FILE    N-Triples to stdout
# Runs the riot inside the pinned image's Fuseki jar, in a throwaway container without network and database;
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
# The image's own Fuseki jar (the one it starts, /jena-fuseki/fuseki-server.jar) contains riot
# --hostname localhost: without a network, Java's log4j can't resolve the container's random name
# and prints an UnknownHostException (harmless, but noise in every update log)
exec docker run --rm --network none --hostname localhost --user 9008 "${mounts[@]}" --entrypoint java "$image" \
  -cp /jena-fuseki/fuseki-server.jar riotcmd.riot "${args[@]}"
