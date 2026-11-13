# CLAUDE.md: LOD-AM triplestore

Docker Compose deployment of the LOD-AM triplestore on the owner's homelab
server: Apache Jena Fuseki (`secoresearch/fuseki` image) plus Watchtower for
automatic image updates. It serves the data from `LOD-AM/knowledge-graph`.
Public name `triple.lod-am.net`, behind the owner's Nginx Proxy Manager, which
currently requires authentication for everything (querying is meant to become
public later).

## Files
- `docker-compose.yml`: services `fuseki` (port 3030, network `lod-am-network`) and `watchtower`
- `fuseki-config/assembler.ttl`: dataset **LOD-AM**, TDB1 at `/fuseki-base/databases/tdb`,
  endpoints `/LOD-AM/sparql` + `/LOD-AM/query` (read) and `/LOD-AM/data` (Graph Store, **read-write**). No reasoning.
- `shiro.ini`: access control (versioned, no secrets). Mounted at `/jena-fuseki/shiro.ini` (the image's template);
  the entrypoint copies it to `/fuseki-base/shiro.ini` and rewrites the `admin=` line. Keep that line as `admin=...` with no spaces.
  Query endpoints are public; `/LOD-AM/data`, `/LOD-AM` and `/$/**` need the admin login.
- `.env` (gitignored, server-only; template `.env.example`): secrets and settings. `fuseki-data/` (gitignored): the database
- `scripts/load.sh`: load Turtle via the Graph Store; `scripts/smoke_test.sh`: health, public query, write protection (never writes)

## Checks (no Docker daemon in cloud sessions)
CI (`test.yml`) runs the real container, loads knowledge-graph and runs the smoke test.
Locally:
```bash
# compose file is valid (dummy values, never real secrets)
FUSEKI_ADMIN_PASSWORD=x WATCHTOWER_NOTIFICATION_EMAIL_FROM=x WATCHTOWER_NOTIFICATION_EMAIL_TO=x \
WATCHTOWER_NOTIFICATION_EMAIL_SERVER=x WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PORT=1 \
WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PASSWORD=x docker compose config -q
# assembler parses
python3 -c "import rdflib; rdflib.Graph().parse('fuseki-config/assembler.ttl')"
```
You can't start the containers here. For behaviour checks, run Fuseki from the
`org.apache.jena:jena-fuseki-server:<version>` jar (Maven Central) with the same
`FUSEKI_BASE` layout (`configuration/assembler.ttl`, `shiro.ini`). Changes to the
running server are only verified once the owner has deployed them
(`sudo docker compose up -d --force-recreate`) and `scripts/smoke_test.sh` passes there.

## Rules
- This is **production** for lod-am.net. Treat changes as deployment changes:
  describe in the PR what the owner has to do on the server and how to roll back.
- Secrets come from `.env` (see `.env.example`). Never put real values in files;
  use obviously fake ones (`change-me`, `example.invalid`) in examples.
- Config is bind-mounted and edited by hand (env-var config doesn't work with the
  bind-mount permissions). Container runs as UID 9008.
- Don't enable reasoning: the knowledge graph is modelled for no inference.
- The `data` endpoint allows writes. Any change that could expose it publicly
  needs explicit owner approval.

- Images are pinned. Version bumps come as Dependabot PRs: check the Jena
  release notes (TDB1 is still used) and let CI pass before merging.

## Where to resume (state 2026-11-13)
- **#3, owner-side: redeploy with the secured config from #1.** Until then the
  server runs the old setup, where Fuseki itself accepts anonymous writes
  (only the proxy authentication protects it). Steps and rollback are in #3.
- #4 backups of `fuseki-data/` · #5 publish port 3030 only on localhost behind
  the proxy · #6 Watchtower watches every container on the host.
- Before querying goes public: #3 and #5 done, the proxy authenticates only
  writes/admin, and the website privacy policy covers `triple.lod-am.net`
  (LOD-AM/website#20).
- Dependabot PRs: check the Jena release notes (TDB1) and let CI pass.

## LOD-AM project (shared block: keep identical in every repo)
Source of truth: knowledge-graph `CLAUDE.md`. Edit it there first, then copy it unchanged; CI (`scripts/check_shared_block.sh`) fails on drift.
LOD-AM = Linked Open Data for Ancient Metallurgy, a one-person research project (https://lod-am.net).
- `LOD-AM/knowledge-graph`: data model, vocabularies, converters, data. **Authority for all modelling rules** (`CONVENTIONS.md`).
- `LOD-AM/triplestore`: Apache Jena Fuseki (Docker) that serves the knowledge graph.
- `LOD-AM/website`: Eleventy site and blog, self-hosted.
- `LOD-AM/ontologies`, `vocabularies`, `converter`: **superseded** by knowledge-graph; don't edit.

Rules for every repo:
- Base IRI `https://lod-am.net/id/`; CIDOC CRM **7.1.3**. Don't restate modelling rules elsewhere; link to knowledge-graph `CONVENTIONS.md`.
- Work on a branch and open a PR to `main`; never push to `main`. Create issues, PRs or comments only when asked.
- Domain/modelling decisions belong to the owner: raise them as knowledge-graph issues (label `modelling`) instead of deciding silently.
- Never commit secrets (passwords, SMTP credentials, `.env`, `shiro.ini`).
- English for code, docs and commits. Keep commits small and explain *why*.
- Verify before you claim: run the repo's checks and report what you ran.
- Open work lives in each repo's GitHub issues; each CLAUDE.md has a "Where to resume"
  section. The owner merges PRs; after a merge, start new work from the updated `main`.
