#!/usr/bin/env python3
"""Check a release from LOD-AM/pipeline and build the file that goes into Fuseki (LOD-AM/planning#7).

  scripts/release.py verify <dir>            check <dir> (manifest.json + published/*.ttl); print one
                                             "<file> <triples>" line per publication
  scripts/release.py combine <dir> <out.ttl> concatenate the publications and add the description of
                                             the graph (which manifest is live, from which commits)

A release is accepted only if:
  - its manifest says every check passed (terms, SHACL violations 0, source rows vs. output),
  - pipeline and knowledge-graph commits are named and were unmodified, and the source is a
    database snapshot or a committed dump (the pipeline's RELEASE_STRICT),
  - every file the manifest lists exists with the listed sha256, and nothing else is in <dir>.
The triple counts are checked separately with Jena's riot (scripts/update_published.sh), the
same parser Fuseki uses. Standard library only: the triplestore LXC needs no Python packages.
"""
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

GRAPH = "https://lod-am.net/graph/published"
FILE = re.compile(r"published/[A-Za-z0-9_.-]+\.ttl")
COMMIT = re.compile(r"[0-9a-f]{40}")


def fail(msg):
    sys.exit(f"FAIL: release rejected: {msg}")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def load(d):
    m_path = d / "manifest.json"
    if not m_path.is_file():
        fail("no manifest.json")
    try:
        m = json.loads(m_path.read_text(encoding="utf-8"))
    except ValueError as e:
        fail(f"manifest.json is not JSON ({e})")
    if m.get("manifest_version") != 2:
        fail(f"manifest_version {m.get('manifest_version')!r}, expected 2")
    c = m.get("checks", {})
    if c.get("terms") != "passed" or c.get("shacl_violations") != 0 or c.get("test_materialize") != "passed":
        fail(f"checks did not all pass: {c}")
    for k in ("pipeline", "knowledge_graph"):
        part = m.get(k, {})
        if not COMMIT.fullmatch(str(part.get("commit"))) or part.get("modified") is not False:
            fail(f"{k} is not a clean commit: {part}")
    src = m.get("source", {})
    if src.get("kind") != "snapshot" and not (COMMIT.fullmatch(str(src.get("commit"))) and src.get("modified") is False):
        fail(f"untraceable source: {src}")
    files = m.get("publications", {}).get("files", [])
    if not files:
        fail("no publications")
    listed = set()
    for p in files:
        name = str(p.get("file"))
        if not FILE.fullmatch(name) or name in listed:
            fail(f"bad or repeated file name {name!r}")
        listed.add(name)
        f = d / name
        if not f.is_file():
            fail(f"{name} missing")
        if sha256(f) != p.get("sha256"):
            fail(f"{name}: sha256 differs from the manifest")
        if p.get("shacl", {}).get("violations") != 0 or not isinstance(p.get("triples"), int) or p["triples"] < 1:
            fail(f"{name}: SHACL violations or no triple count in the manifest")
    present = {str(f.relative_to(d)) for f in d.rglob("*") if f.is_file()} - {"manifest.json"}
    if present - listed:
        fail(f"files the manifest does not list: {sorted(present - listed)}")
    return m, files


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("verify", "combine") or (sys.argv[1] == "combine" and len(sys.argv) != 4):
        sys.exit(__doc__)
    d = Path(sys.argv[2])
    m, files = load(d)
    if sys.argv[1] == "verify":
        for p in files:
            print(p["file"], p["triples"])
        return
    out = Path(sys.argv[3])
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(out, "w", encoding="utf-8") as o:
        for p in files:
            o.write((d / p["file"]).read_text(encoding="utf-8").rstrip("\n") + "\n\n")
        # Which release is live (planning#7 "the live manifest can be queried"); Turtle allows
        # @prefix anywhere. Only prefixes from knowledge-graph tools/prefixes.ttl.
        o.write("@prefix dcterms: <http://purl.org/dc/terms/> .\n@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .\n")
        o.write(f"<{GRAPH}> dcterms:identifier \"manifest sha256:{sha256(d / 'manifest.json')}\" ;\n"
                f"    dcterms:modified \"{now}\"^^xsd:dateTime ;\n"
                f"    dcterms:source <https://github.com/LOD-AM/pipeline/commit/{m['pipeline']['commit']}> ,\n"
                f"        <https://github.com/LOD-AM/knowledge-graph/commit/{m['knowledge_graph']['commit']}> .\n")
    print(f"combined: {len(files)} publication(s) + graph description → {out}")


if __name__ == "__main__":
    main()
