#!/usr/bin/env bash
# Rebuild the full-text index (LOD-AM/planning#31) from the data in TDB.
#
#   sudo scripts/reindex.sh
#
# Needed once after the index is first enabled (data loaded before has no index
# entries) and after every `scripts/load.sh --replace`: clearing a graph through
# the Graph Store leaves its labels in the index, so search would still find
# resources that are gone. Writes that only add data keep the index up to date.
#
# Fuseki is stopped for a few seconds: TDB1 can only be opened by one process.
# The index is deleted and rebuilt inside a one-off container of the same image
# (as UID 9008, with the same assembler.ttl); TDB itself is only read.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose stop fuseki
# Start Fuseki again whatever happens below.
trap 'docker compose start fuseki' EXIT
docker compose run --rm --no-deps --entrypoint sh fuseki -c \
  'rm -rf /fuseki-base/databases/lucene && $TEXTINDEXER'
trap - EXIT
docker compose start fuseki

for _ in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' lod-am-fuseki)" = healthy ] && break
  sleep 3
done
echo "fuseki: $(docker inspect -f '{{.State.Health.Status}}' lod-am-fuseki)"
