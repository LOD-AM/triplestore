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
- `.env` (gitignored, server-only; template `.env.example`): secrets and settings. `fuseki-data/` (gitignored): the database (not backed up; reload from the sources)
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

## Where to resume (state 2026-11-21)
- **#3 redeployed (2026-11-21):** fresh clone in `~/triplestore` on the LXC, `.env` in use,
  Fuseki 6.2.0 with the secured `shiro.ini`; knowledge-graph `data/` + `examples/` loaded
  (664 triples), `scripts/smoke_test.sh --min-triples 664` passed on the server. The old checkout
  (with the old database) is kept as `~/triplestore-old` for rollback until the owner removes it.
  Owner's remaining checks are in #3 (web UI asks for the login, `.bashrc` exports removed, Dependabot).
- Pitfall seen on the redeploy: if `fuseki-data/` doesn't exist or isn't owned by 9008, Fuseki
  exits with `Not writable: /fuseki-base/databases` and restarts in a loop.
  Fix: `sudo chown -R 9008:9008 fuseki-data fuseki-config`, then recreate.
- Server decisions (owner, 2026-11-21; README "Server setup"): a dedicated LXC on Proxmox that runs only this
  stack, so Watchtower stays host-wide (#6); the proxy runs on another VM, so port 3030 can't be
  localhost-only and `shiro.ini` is what protects writes (#5); Proxmox firewall rules allow 3030 only from the proxy
  (LOD-AM/planning#29, ACCEPT above DROP); no triplestore backups, the
  sources are the relational DB and knowledge-graph plus the whole-machine backup, restore = reload (#4).
- Before querying goes public: the proxy authenticates only writes/admin, and the
  website privacy policy covers `triple.lod-am.net` (LOD-AM/website#20).
- Dependabot PRs: check the Jena release notes (TDB1) and let CI pass.

## LOD-AM project (shared block: keep identical in every repo)
Source of truth: knowledge-graph `CLAUDE.md`. Edit it there first, then copy it unchanged; CI (`scripts/check_shared_block.sh`) fails on drift.
LOD-AM = Linked Open Data for Ancient Metallurgy, a one-person research project (https://lod-am.net).
- `LOD-AM/knowledge-graph`: data model, vocabularies, converters, data. **Authority for all modelling rules** (`CONVENTIONS.md`).
- `LOD-AM/triplestore`: Apache Jena Fuseki (Docker) that serves the knowledge graph.
- `LOD-AM/ingest` (**private**): the owner's research database (dump), converter (R2RML) and its output; the database as a whole stays private until the owner says otherwise.
- `LOD-AM/website`: Eleventy site and blog, self-hosted.
- `LOD-AM/planning` (**private**): project management for all repos: one issue per task, state in labels (see its README).
- `LOD-AM/ontologies`, `vocabularies`, `converter`: **superseded** by knowledge-graph; don't edit.

Rules for every repo:
- Base IRI `https://lod-am.net/id/`; CIDOC CRM **7.1.3**. Don't restate modelling rules elsewhere; link to knowledge-graph `CONVENTIONS.md`.
- Work on a branch and open a PR to `main`; never push to `main`. Create issues, PRs or comments only when asked.
- Domain/modelling decisions belong to the owner: raise them as `LOD-AM/planning` issues (label `modelling`) instead of deciding silently.
- Never commit secrets (passwords, SMTP credentials, `.env`, `shiro.ini`).
- English for code, docs and commits. Keep commits small and explain *why*.
- Verify before you claim: run the repo's checks and report what you ran.
- Open work lives in `LOD-AM/planning` (issues with `status:`/`area:` labels; keep them true);
  PRs reference it (`Closes LOD-AM/planning#<n>`). Each CLAUDE.md's "Where to resume" keeps only
  repo-specific notes. The owner merges PRs; after a merge, start new work from the updated `main`.
