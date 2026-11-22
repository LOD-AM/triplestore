#!/usr/bin/env bash
# Integration test of scripts/update_published.sh against a running Fuseki (LOD-AM/planning#7).
# WRITES to <https://lod-am.net/graph/published>: never run it on the production server.
#
#   LODAM_TEST=1 scripts/test_update_published.sh <public .ttl>      (CI: knowledge-graph/examples/*.ttl)
#
# Builds fake releases from a public Turtle file (manifest as LOD-AM/pipeline writes it) and checks:
#   1. a new release is loaded: graph count, union, the graph's description, releases/live/
#   2. the same release again: nothing to do
#   3. a changed release replaces the old one; releases/previous/ keeps it
#   4. rejected, graph unchanged: wrong sha256, SHACL violations, an unlisted file, a wrong triple count
#   5. a failure after the load (reindex fails) puts the live release back
#   6. --rollback brings the previous release back
set -euo pipefail
cd "$(dirname "$0")/.."
[ "${LODAM_TEST:-}" = 1 ] || { echo "refusing: this test writes to Fuseki; set LODAM_TEST=1 (never on production)" >&2; exit 2; }
SRC_TTL=${1:?usage: LODAM_TEST=1 scripts/test_update_published.sh <public .ttl>}
[ -f .env ] && set -a && . ./.env && set +a
FUSEKI_URL="${FUSEKI_URL:-http://localhost:3030}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
chmod 755 "$T"   # riot runs in the Fuseki image as UID 9008 (scripts/riot.sh)
export LODAM_RELEASE_SOURCE=$T/source LODAM_LOCK=$T/lock
GRAPH=https://lod-am.net/graph/published
q() { curl -sS -G -H "Accept: text/csv" --data-urlencode "query=$1" "$FUSEKI_URL/LOD-AM/sparql" | tail -n +2 | tr -d '\r'; }
gcount() { q "SELECT (COUNT(*) AS ?n) WHERE { GRAPH <$GRAPH> { ?s ?p ?o } }"; }
fail() { echo "FAIL $1"; cat "$T/out" 2>/dev/null | tail -20; exit 1; }
upd() { scripts/update_published.sh > "$T/out" 2>&1; }

release() { # name ttl-files...: write a release as the pipeline would into $T/source
  local name=$1; shift; rm -rf "$T/source"; mkdir -p "$T/source/published"
  local i=0; for f in "$@"; do i=$((i+1)); cp "$f" "$T/source/published/pub$i.ttl"; done
  python3 - "$T/source" "$name" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
d, name = Path(sys.argv[1]), sys.argv[2]
files = []
for f in sorted((d / "published").glob("*.ttl")):
    files.append({"key": f.stem, "file": f"published/{f.name}", "sha256": hashlib.sha256(f.read_bytes()).hexdigest(),
                  "triples": None, "canonical_sha256": "0" * 64, "shacl": {"violations": 0, "warnings": 0}})
m = {"manifest_version": 2, "created": "2026-01-01T00:00:00Z", "test": name,
     "source": {"kind": "snapshot", "file": "x.sql", "sha256": "0" * 64},
     "pipeline": {"commit": "a" * 40, "modified": False, "image": None, "ontop": "5.5.0"},
     "knowledge_graph": {"commit": "b" * 40, "modified": False},
     "zotero": {"group": 6765723, "library_version": 59},
     "publications": {"selected_from": "config", "files": files},
     "checks": {"terms": "passed", "shacl_violations": 0, "test_materialize": "passed"}}
(d / "manifest.json").write_text(json.dumps(m, indent=2))
PY
  # triple counts as the pipeline reports them (rdflib len = distinct triples): count with riot here
  python3 - "$T/source" "$(for f in "$T/source/published/"*.ttl; do
      n=$(scripts/riot.sh --count "$f" 2>&1 | sed -n 's/.*Triples = \([0-9,]*\).*/\1/p' | tr -d ,); echo "$(basename "$f")=$n"; done | tr '\n' ' ')" <<'PY'
import json, sys
from pathlib import Path
d = Path(sys.argv[1]); counts = dict(kv.split("=") for kv in sys.argv[2].split())
m = json.loads((d / "manifest.json").read_text())
for p in m["publications"]["files"]:
    p["triples"] = int(counts[p["file"].split("/")[1]])
(d / "manifest.json").write_text(json.dumps(m, indent=2))
PY
}
edit_manifest() { python3 -c "import json,sys; p=sys.argv[1]; m=json.load(open(p)); exec(sys.argv[2]); json.dump(m, open(p,'w'))" "$T/source/manifest.json" "$1"; }

printf '<urn:lodam-test:extra> <http://www.w3.org/2000/01/rdf-schema#label> "Zzupdatetest"@en .\n' > "$T/extra.ttl"

release one "$SRC_TTL"; upd || fail "1: first update"
n1=$(gcount); [ "$n1" -gt 0 ] && [ -f releases/live/manifest.sha256 ] || fail "1: graph empty or no releases/live"
[ "$(q "SELECT (COUNT(*) AS ?n) WHERE { <$GRAPH> <http://purl.org/dc/terms/identifier> ?id }")" = 1 ] || fail "1: no graph description"
[ "$(q 'SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }')" -ge "$n1" ] || fail "1: union does not see the graph"
echo "ok   1 new release loaded ($n1 triples incl. description), visible without FROM"

upd || fail "2: second run"; grep -q "already live" "$T/out" || fail "2: expected 'already live'"
echo "ok   2 same release: nothing to do"

release two "$SRC_TTL" "$T/extra.ttl"; upd || fail "3: changed release"
n2=$(gcount); [ "$n2" = $((n1 + 1)) ] && [ -f releases/previous/manifest.sha256 ] || fail "3: expected $((n1 + 1)) triples and releases/previous ($n2)"
echo "ok   3 changed release replaces the old one ($n2 triples); previous kept"

release bad-sha "$SRC_TTL"; echo "# tampered" >> "$T/source/published/pub1.ttl"
! upd && grep -q "sha256 differs" "$T/out" && [ "$(gcount)" = "$n2" ] || fail "4a: tampered file not rejected"
release bad-shacl "$SRC_TTL"; edit_manifest 'm["checks"]["shacl_violations"] = 1'
! upd && grep -q "checks did not all pass" "$T/out" && [ "$(gcount)" = "$n2" ] || fail "4b: SHACL violations not rejected"
release unlisted "$SRC_TTL"; echo '<urn:a> <urn:b> <urn:c> .' > "$T/source/published/sneaked.ttl"
! upd && grep -q "does not list" "$T/out" && [ "$(gcount)" = "$n2" ] || fail "4c: unlisted file not rejected"
release bad-count "$SRC_TTL"; edit_manifest 'm["publications"]["files"][0]["triples"] += 1'
! upd && grep -q "triples, the manifest says" "$T/out" && [ "$(gcount)" = "$n2" ] || fail "4d: wrong count not rejected"
echo "ok   4 rejected, graph unchanged: tampered file, SHACL violations, unlisted file, wrong triple count"

release three "$T/extra.ttl"
! LODAM_REINDEX=false upd && grep -q "putting the live release back" "$T/out" && [ "$(gcount)" = "$n2" ] \
  || fail "5: a failure after the load did not restore the live release"
echo "ok   5 failure after the load: live release put back"

scripts/update_published.sh --rollback > "$T/out" 2>&1 || fail "6: rollback"
[ "$(gcount)" = "$n1" ] || fail "6: rollback did not restore the previous release ($(gcount) != $n1)"
echo "ok   6 --rollback restores the previous release"
