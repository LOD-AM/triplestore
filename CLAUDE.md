# CLAUDE.md: LOD-AM triplestore

Docker Compose deployment of the LOD-AM triplestore on the owner's homelab
server: Apache Jena Fuseki (`secoresearch/fuseki` image) plus Watchtower for
automatic image updates. It serves the data from `LOD-AM/knowledge-graph`.
Public name `triple.lod-am.net`, behind the owner's Nginx Proxy Manager. Querying is public
(owner, 2026-11-23, planning#24; checked from outside: `/LOD-AM/sparql` answers without login,
CORS allows `https://lod-am.net`, `/LOD-AM/data` and `/$/` answer 401). The website's query editor
(`lod-am.net/query/`, LOD-AM/website#57) sends queries here.

## Files
- `docker-compose.yml`: services `fuseki` (port 3030, network `lod-am-network`) and `watchtower`; logs capped at
  5 × 10 MB per container (Fuseki logs query texts; website privacy policy, LOD-AM/website#57)
- `fuseki-config/assembler.ttl`: dataset **LOD-AM**, TDB1 at `/fuseki-base/databases/tdb`,
  endpoints `/LOD-AM/sparql` + `/LOD-AM/query` (read) and `/LOD-AM/data` (Graph Store, **read-write**). No reasoning.
  **Named graphs only** with `tdb:unionDefaultGraph true` (owner, 2026-11-22, planning#7): `…/graph/knowledge-graph`
  (`update_kg.sh`: knowledge-graph `data/` only, no `examples/`, owner 2026-11-22) and `…/graph/published` (`update_published.sh`); queries without FROM see both; never load `?default`.
  Wrapped in a `text:TextDataset` (Lucene label index at `/fuseki-base/databases/lucene`, planning#31) that also
  carries the query timeout `10000,120000` (planning#30). The timeout must stay on that dataset: the image's
  `QUERY_TIMEOUT`/`config.ttl` and `ja:context` on the service have no effect (tested with the 6.2.0 jar).
- `shiro.ini`: access control (versioned, no secrets). Mounted at `/jena-fuseki/shiro.ini` (the image's template);
  the entrypoint copies it to `/fuseki-base/shiro.ini` and rewrites the `admin=` line. Keep that line as `admin=...` with no spaces.
  Query endpoints are public; `/LOD-AM/data`, `/LOD-AM` and `/$/**` need the admin login.
- `.env` (gitignored, server-only; template `.env.example`): secrets and settings. `fuseki-data/` (gitignored): the database (not backed up; reload from the sources)
- `scripts/update_published.sh` (+ `release.py`, `riot.sh`): pull a release of the released publications from the
  data LXC (rsync over SSH, `rrsync -ro`), check it against its manifest, load it in one PUT, reindex, smoke test,
  put the old one back on failure; `--rollback`. `deploy/`: webhook receiver (`webhook.py`, port 9300), systemd units,
  `install.sh`. `scripts/migrate_named_graphs.sh`: one-time move from the default graph (planning#7)
- `scripts/update_kg.sh` (planning#35): daily, knowledge-graph `main` `data/` into its graph if `data/` changed and the
  commit's GitHub checks passed; one PUT, reindex, smoke test, put back on failure; `--rollback`. Shares the lock with
  `update_published.sh` (waits). `deploy/alert.sh` + `lodam-alert@.service` (planning#34): `OnFailure=` of every unit
  mails the owner (curl SMTP; LODAM_ALERT_* or Watchtower's settings); identical copy in LOD-AM/pipeline
- `scripts/load.sh`: load Turtle into a named graph via the Graph Store (by hand); `scripts/smoke_test.sh`: health, public query, write protection,
  text search (never writes); `scripts/reindex.sh`: rebuild the text index (stops Fuseki briefly). Needed after
  `load.sh --replace`, because clearing a graph leaves its labels in the index

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
  bind-mount permissions). Container runs as UID 9008 (group 0, plus group 9008 via `group_add`).
  `fuseki-data/` belongs to 9008; `fuseki-config/` belongs to the checkout user, group 9008, mode 2775:
  Fuseki 6.2.0 refuses to start unless it can write there, and git must be able to replace files in it.
- Don't enable reasoning: the knowledge graph is modelled for no inference.
- The `data` endpoint allows writes. Any change that could expose it publicly
  needs explicit owner approval.

- Images are pinned. Version bumps come as Dependabot PRs: check the Jena
  release notes (TDB1 is still used) and let CI pass before merging.

## Where to resume (state 2026-11-22, evening)
- **Live on the server (verified by the owner):** Fuseki 6.2.0 with the secured `shiro.ini` (#3), query
  timeout `10000,120000` (planning#30), Lucene label index (planning#31; #12), `fuseki-config/` owned by the
  owner's user with group 9008 + `group_add` (#13). **Named graphs + union default graph** (planning#7, #16):
  `…/graph/knowledge-graph` 339 triples (knowledge-graph `2f7bcdb`, `data/` only, by `update_kg.sh`), `…/graph/published`
  6234 (release `7b55606a…`), union 6573; smoke test passes incl. text search (owner, 2026-11-22 18:57).
- **Release chain live (2026-11-22):** the pipeline's webhook (port 9300, Proxmox: only from the data LXC,
  ACCEPT above DROP) starts `lodam-update-published`; daily fallback 05:47. After a live release,
  `scripts/publish_website.sh` (#18) pushes it to the website's branch `data-release` (deploy key
  `/root/.ssh/lodam-website`, `LODAM_WEBSITE_REPO` in `.env`); the website workflow opens the PR.
  Logs: `sudo journalctl -u lodam-update-published -e`, `-u lodam-webhook`, `-u lodam-update-kg`.
- **Live since 2026-11-22 (planning#34, #35, #20):** failure mails (test mail and the deliberately failing run arrived,
  via Watchtower's SMTP account) and the daily knowledge-graph update (`lodam-update-kg.timer` 05:17).
- Pitfall: a root-owned file in `.git/objects` (an earlier `sudo git …`) blocked `git pull`; fix:
  `sudo chown -R <owner>: .git`. Never run git with sudo in the checkout (the scripts use their own repos in `releases/`).
- Server checkout: `~/triplestore` on the LXC, `.env` in use. `~/triplestore-old` (old database) is kept for
  rollback until the owner removes it. Owner to-dos: LOD-AM/planning#33 (e.g. rotate the webhook token).
- Deploy pitfalls seen so far (all in README Troubleshooting): a missing `fuseki-data/` (now refused by
  `create_host_path: false`); `fuseki-config/` owned by 9008 blocked `git pull` (fixed by #13); the webhook
  receiver could not read its script in a home directory (#17: copy in `/usr/local/lib/lodam`, re-run
  `sudo deploy/install.sh` after changes in `deploy/`). A config change only takes effect after
  `sudo docker compose up -d --force-recreate fuseki`; ask the owner to confirm that step.
- After every `scripts/load.sh --replace`: `sudo scripts/reindex.sh` (clearing a graph leaves stale index entries).
- `scripts/test_update_published.sh` and `scripts/test_update_kg.sh` write to Fuseki: CI/local only, never production.
- Server decisions (owner, 2026-11-21; README "Server setup"): a dedicated LXC on Proxmox that runs only this
  stack, so Watchtower stays host-wide (#6); the proxy runs on another VM, so port 3030 can't be
  localhost-only and `shiro.ini` is what protects writes (#5); Proxmox firewall rules allow 3030 only from the proxy
  (LOD-AM/planning#29, ACCEPT above DROP); no triplestore backups, the
  sources are the relational DB and knowledge-graph plus the whole-machine backup, restore = reload (#4).
- Querying is public since 2026-11-23. The website privacy policy must cover `triple.lod-am.net`
  (owner; draft in LOD-AM/website#57), including how long the capped Fuseki log keeps query texts.
- Dependabot PRs: check the Jena release notes (TDB1) and let CI pass.

## LOD-AM project (shared block: keep identical in every repo)
Source of truth: knowledge-graph `CLAUDE.md`. Edit it there first, then copy it unchanged; CI (`scripts/check_shared_block.sh`) fails on drift.
LOD-AM = Linked Open Data for Ancient Metallurgy, a one-person research project (https://lod-am.net).
- `LOD-AM/knowledge-graph`: data model, vocabularies, converters, data. **Authority for all modelling rules** (`CONVENTIONS.md`).
- `LOD-AM/triplestore`: Apache Jena Fuseki (Docker) that serves the knowledge graph.
- `LOD-AM/ingest` (**private**): the owner's research database (dump), its checks and correction rounds; the database as a whole stays private until the owner says otherwise.
- `LOD-AM/pipeline`: the data pipeline, code only (database snapshot → R2RML/Ontop → enrichment → checks → released publications); runs on the data LXC, never with data on GitHub.
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
