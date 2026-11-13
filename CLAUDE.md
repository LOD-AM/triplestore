# CLAUDE.md: LOD-AM triplestore

Docker Compose deployment of the LOD-AM triplestore on the owner's homelab
server: Apache Jena Fuseki (`secoresearch/fuseki` image) plus Watchtower for
automatic image updates. It serves the data from `LOD-AM/knowledge-graph`.

## Files
- `docker-compose.yml`: services `fuseki` (port 3030, network `lod-am-network`) and `watchtower`
- `fuseki-config/assembler.ttl`: dataset **LOD-AM**, TDB1 at `/fuseki-base/databases/tdb`,
  endpoints `/LOD-AM/sparql` + `/LOD-AM/query` (read) and `/LOD-AM/data` (Graph Store, **read-write**). No reasoning.
- `fuseki-config/shiro.ini` (gitignored, server-only): access control; `fuseki-data/` (gitignored): the database

## Checks (no Docker daemon in cloud sessions)
```bash
# compose file is valid (dummy values, never real secrets)
FUSEKI_ADMIN_PASSWORD=x WATCHTOWER_NOTIFICATION_EMAIL_FROM=x WATCHTOWER_NOTIFICATION_EMAIL_TO=x \
WATCHTOWER_NOTIFICATION_EMAIL_SERVER=x WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PORT=1 \
WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PASSWORD=x docker compose config -q
# assembler parses
python3 -c "import rdflib; rdflib.Graph().parse('fuseki-config/assembler.ttl')"
```
You can't start the containers here, so say so: changes to the running server
are only verified once the owner has deployed them (`sudo -E docker compose down && sudo -E docker compose up -d`).

## Rules
- This is **production** for lod-am.net. Treat changes as deployment changes:
  describe in the PR what the owner has to do on the server and how to roll back.
- Secrets come from environment variables (see README table). Never put real
  values in files; use obviously fake ones in examples.
- Config is bind-mounted and edited by hand (env-var config doesn't work with the
  bind-mount permissions). Container runs as UID 9008.
- Don't enable reasoning: the knowledge graph is modelled for no inference.
- The `data` endpoint allows writes. Any change that could expose it publicly
  needs explicit owner approval.

## Known issues (planned work)
- `secoresearch/fuseki` and `nickfedor/watchtower` are unpinned and Watchtower
  auto-updates them: not reproducible. Plan: pin versions and let Dependabot propose updates.
- Secrets live in `~/.bashrc` + `sudo -E`. Plan: `.env` (gitignored) + `.env.example`.
- No healthcheck, no load script for knowledge-graph data, no CI.

## LOD-AM project (shared block: keep identical in every repo)
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
