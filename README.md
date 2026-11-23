# LOD-AM Triplestore

Docker deployment of the LOD-AM triplestore based on [secoresearch/fuseki](https://hub.docker.com/r/secoresearch/fuseki) (maintained by [SemanticComputing](https://github.com/SemanticComputing/fuseki-docker)) with [nickfedor/watchtower](https://github.com/nickfedor/watchtower) for automatic container updates.

> **Note**: This configuration is aligned with the SemanticComputing/fuseki-docker image approach.

## Quick Start

1. **Set up the two folders Fuseki uses (required, before the first start):**
   ```bash
   mkdir -p fuseki-data
   sudo chown -R 9008:9008 fuseki-data
   sudo chown -R "$USER":9008 fuseki-config && sudo chmod 2775 fuseki-config
   ls -ldn fuseki-data fuseki-config
   ```
   `fuseki-data` must show `drwx… 9008 9008`, and `fuseki-config` must show
   `drwxrwsr-x <your uid> 9008`.
   Fuseki runs as UID 9008 and needs write access to both: to the database, and to
   the config folder, because it refuses to start otherwise (it writes nothing there).
   - `fuseki-data/` belongs to Fuseki.
   - `fuseki-config/` stays **yours**, so `git pull` can update `assembler.ttl`.
     Fuseki gets write access through group 9008 (`group_add` in `docker-compose.yml`).
     The `s` bit (`2775`) gives files that git creates there the same group.

   This applies to every fresh clone: `fuseki-data/` isn't in git. If the folder is
   missing, `docker compose up` stops with `bind source path does not exist`; with
   the wrong owner, Fuseki restarts in a loop (see Troubleshooting).

2. **Create `.env` from the template and fill in real values:**
   ```bash
   cp .env.example .env && chmod 600 .env
   nano .env
   ```
   `docker compose` reads `.env` automatically, so there is no need for exports in `~/.bashrc` or `sudo -E`.

3. **Start the services:**
   ```bash
   sudo docker compose up -d
   ```

4. **Check it:**
   ```bash
   scripts/smoke_test.sh      # health, public query, write protection
   ```
   - Web UI: http://localhost:3030
   - SPARQL endpoint (public, read-only): http://localhost:3030/LOD-AM/sparql
   - Graph Store (read-write, **admin login required**): http://localhost:3030/LOD-AM/data

5. **Load the knowledge graph** (on the server: `sudo scripts/update_kg.sh` fetches it from GitHub,
   see [Knowledge graph](#knowledge-graph-lod-amplanning35); by hand, from a checkout of
   [LOD-AM/knowledge-graph](https://github.com/LOD-AM/knowledge-graph)):
   ```bash
   scripts/load.sh --replace ../knowledge-graph/data
   ```
   The data goes into the named graph `https://lod-am.net/graph/knowledge-graph` (see
   [Named graphs](#named-graphs)); `--replace` empties it first, so it then holds exactly these files.
   Then rebuild the text index, which `--replace` doesn't clean (see [Text search](#text-search)):
   ```bash
   sudo scripts/reindex.sh
   ```

## Access control

`shiro.ini` (versioned, no secrets) defines who may do what:

| Path | Access |
|---|---|
| `/LOD-AM/sparql`, `/LOD-AM/query` | public (SPARQL query only) |
| `/LOD-AM/data`, `/LOD-AM` (dataset URL) | admin login (these accept writes) |
| `/$/…` (admin UI/API) | admin login, except `/$/ping` and `/$/status` |
| web UI static files | public |

The admin password comes from `FUSEKI_ADMIN_PASSWORD`. The image's entrypoint
writes it into the `admin=` line when the container is created. After changing
`shiro.ini` or the password, recreate the container:
`sudo docker compose up -d --force-recreate fuseki`.

## Configuration

- **Persistent storage**: Fuseki data is stored in `./fuseki-data/` (bind mount to `/fuseki-base/databases`)
- **Custom configs**: `assembler.ttl` lives in `./fuseki-config/` (bind mount to `/fuseki-base/configuration`); `./shiro.ini` is mounted read-only as the image's shiro template
- **Versions**: images are pinned in `docker-compose.yml`; Dependabot opens PRs for new versions. Watchtower only picks up rebuilds of the pinned tags and sends email notifications. Watchtower watches *all* containers on the host on purpose (see [Server setup](#server-setup)).
- **Healthcheck**: Docker marks `lod-am-fuseki` healthy when `/$/ping` answers
- **Reasoning**: Currently **disabled** - AFO and CIDOC CRM will be implemented directly without inference mappings

## Fuseki Configuration File

The repository includes a minimal `fuseki-config/assembler.ttl` that:
- Uses TDB1 dataset type (`tdb:DatasetTDB`) compatible with secoresearch/fuseki image
- Stores data at `/fuseki-base/databases/tdb`
- Enables **Graph Store Protocol (GSP)** for data upload/edit in the UI
- Sets the **query timeout** and the **text index** (both below)
- **Excludes reasoning** (no RDFS/OWL inference)

> **Important**: When using bind mounts for configuration, manually edit `assembler.ttl` to enable endpoints rather than using environment variables (due to permission restrictions).

To apply configuration changes:
```bash
sudo docker compose down && sudo docker compose up -d
```

## Query timeout

Every query gets **10 s to its first result and 120 s overall**
(LOD-AM/planning#30), so one heavy query can't occupy Fuseki for long. After
the first limit the client gets `503 Query timed out`; after the second, the
results already sent end with `Query cancelled due to timeout`.

The value is `ja:context` on the `:text` dataset in `assembler.ttl`. The image's
`QUERY_TIMEOUT` variable does **not** work here: it edits the image's
`/fuseki-base/config.ttl`, which Fuseki 6.2.0, as the image starts it, never
reads (checked with the 6.2.0 jar, 2026-11-21). `ja:context` on the
`fuseki:Service` has no effect either. CI checks that a slow query is cut off.

## Text search

A Lucene index over `rdfs:label`, `skos:prefLabel` and `skos:altLabel`
(LOD-AM/planning#31) gives fast label search in SPARQL:

```sparql
PREFIX text: <http://jena.apache.org/text#>
SELECT ?s ?label ?score WHERE {
  (?s ?score ?label) text:query ("spear*" "lang:en")
}
```

- All three properties share one field, so the search covers all labels; a
  property as first argument (`text:query (rdfs:label "…")`) doesn't narrow it.
- One field for all languages, no stemming (`spearhead` doesn't find
  `spearheads`; use `spear*`). `"lang:en"` limits hits to English labels.
- The index lives in `fuseki-data/lucene/`, next to TDB. It holds nothing that
  isn't in TDB, so it can be deleted and rebuilt at any time.
- Loading with `scripts/load.sh` (adding) updates it. **Clearing a graph doesn't**:
  after `scripts/load.sh --replace` the removed labels are still found. Rebuild it:
  ```bash
  sudo scripts/reindex.sh
  ```
  This stops Fuseki for a few seconds (TDB1 allows only one process), deletes
  the index and rebuilds it with the image's `textindexer` in a one-off
  container, then starts Fuseki again. `scripts/smoke_test.sh` fails if the
  index is empty.

- The index doesn't know graphs: a label stored in two named graphs is found twice. Use
  `SELECT DISTINCT` when that matters.

## Named graphs

All data sits in named graphs (owner, 2026-11-22, LOD-AM/planning#7):

| Graph | Contents | Loaded by |
|---|---|---|
| `https://lod-am.net/graph/knowledge-graph` | LOD-AM/knowledge-graph `data/` (not `examples/`: owner, 2026-11-22), plus a description of which commit is live | `scripts/update_kg.sh`, daily ([Knowledge graph](#knowledge-graph-lod-amplanning35)) |
| `https://lod-am.net/graph/published` | the publications the owner released, from LOD-AM/pipeline, plus a description of which release is live | `scripts/update_published.sh` ([Releases](#releases)) |

The dataset has `tdb:unionDefaultGraph true` (`fuseki-config/assembler.ttl`): **a query without
`GRAPH` or `FROM` sees all named graphs together**, and a triple stored in two graphs counts once.
One graph only: `SELECT … FROM <https://lod-am.net/graph/published> WHERE { … }` or `GRAPH <…> { … }`.
Which release is live:
```sparql
SELECT ?p ?o WHERE { <https://lod-am.net/graph/published> ?p ?o }
```
(`dcterms:identifier` = the manifest's sha256, `dcterms:modified` = when it was loaded,
`dcterms:source` = the pipeline and knowledge-graph commits.)

TDB1 hides the stored default graph when the union is on, so nothing is loaded there:
`scripts/load.sh` writes only to named graphs.

**Migrating a store from before named graphs** (once, right after deploying the new assembler;
until then queries see no data, because the old copy sits in the now hidden default graph):
```bash
sudo scripts/migrate_named_graphs.sh ../knowledge-graph/data ../knowledge-graph/examples
```
It loads the knowledge graph into its named graph, and only if that worked deletes the stored
default graph, then rebuilds the text index and runs the smoke test. Tested with the Fuseki 6.2.0
jar on a store loaded the old way (664 triples moved, default graph empty afterwards).

## Releases

The released publications come from LOD-AM/pipeline, which runs on the data LXC (LOD-AM/planning#6)
and copies each checked release to `/srv/lodam/release` there. `scripts/update_published.sh` pulls
it (LOD-AM/planning#7; owner's choices of 2026-11-21/22):

1. **Fetch:** `rsync` over SSH into `releases/incoming/`, with a key the data LXC restricts to reading
   that one directory (`rrsync -ro`). The data LXC has no access to this machine.
2. **Check** (`scripts/release.py`, `scripts/riot.sh`): the manifest says every check passed, the
   pipeline and knowledge-graph commits were clean, the source is a database snapshot; every listed
   file is there with its sha256 and nothing else; Jena's riot counts each file's triples as in the
   manifest; no blank nodes. A release that fails any of this is rejected and changes nothing.
3. **Load** the publications and the graph's description in **one** Graph Store `PUT`: one
   transaction, so a query sees the old release or the new one, never a mix. Then the graph must
   hold exactly the expected number of triples.
4. **Reindex** (Fuseki stops for a few seconds) and **smoke test**. If anything fails after the load,
   the live release is put back.
5. The release becomes `releases/live/`, the one before `releases/previous/`.
6. **Website:** the live release goes to LOD-AM/website as a pull request ([Website](#website-lod-amwebsite21)).

It runs when the pipeline's webhook arrives (`deploy/webhook.py`, port 9300, reachable only from the
data LXC), and daily at 05:47 as a fallback; an unchanged release ends with "already live".

### Setup (owner, once)
On the **data LXC**:
```bash
sudo adduser --system --group --home /var/lib/lodam-release --shell /bin/sh lodam-release
sudo install -d -m 755 /srv/lodam/release      # the pipeline copies each release here
sudo install -d -m 700 -o lodam-release -g lodam-release /var/lib/lodam-release/.ssh
```
Then, in the pipeline's `.env`: `LODAM_PUBLISH_DIR=/srv/lodam/release`. The account has no
password, so it can only be used with the key below, and only for that one command (`/bin/sh` runs
the forced command; `nologin` would refuse it).

On the **triplestore LXC**:
```bash
sudo ssh-keygen -t ed25519 -N '' -C lodam-release -f /root/.ssh/lodam-release
sudo cat /root/.ssh/lodam-release.pub
```
On the **data LXC**, put that public key into `/var/lib/lodam-release/.ssh/authorized_keys` (owner
`lodam-release`, mode 600), as one line:
```
restrict,command="rrsync -ro /srv/lodam/release" ssh-ed25519 AAAA… lodam-release
```
**Proxmox firewall:** on the data LXC, `IN ACCEPT -source <triplestore LXC> -p tcp -dport 22`; on
the triplestore LXC, `IN ACCEPT -source <data LXC> -p tcp -dport 9300`, then
`IN DROP -p tcp -dport 9300` (ACCEPT above DROP, as for 3030).

On the **triplestore LXC**, in this checkout's `.env`: `LODAM_RELEASE_SOURCE=lodam-release@<data LXC>:`.
Then:
```bash
sudo deploy/install.sh                                  # prints the webhook token once
sudo systemctl start --no-block lodam-update-published  # first fetch; the first SSH connection
sudo journalctl -u lodam-update-published -f             # records the data LXC's host key
```
Finally, in the pipeline's `.env` on the data LXC:
`LODAM_RELEASE_WEBHOOK=http://<triplestore LXC>:9300/lodam-release` and
`LODAM_RELEASE_WEBHOOK_TOKEN=<the printed token>`.

### Operate
| | |
|---|---|
| Update now | `sudo systemctl start --no-block lodam-update-published` |
| Load even if already live | `sudo scripts/update_published.sh --force` |
| Back to the previous release | `sudo scripts/update_published.sh --rollback` |
| Log | `sudo journalctl -u lodam-update-published -e` (and `-u lodam-webhook`); a failed run is mailed ([Alerts](#alerts-lod-amplanning34)) |
| Which release is live | `cat releases/live/manifest.sha256`, or the SPARQL query above |
| Hand the live release to the website again | `sudo scripts/publish_website.sh` ([Website](#website-lod-amwebsite21)) |
| Undo the installation | `sudo deploy/install.sh --remove` (data, releases and token stay) |
| After a `git pull` that changes `deploy/` | `sudo deploy/install.sh` again: it installs the receiver's script to `/usr/local/lib/lodam/` (the receiver's user can't read a home directory) and restarts it |

### Website (LOD-AM/website#21)
After a release went live (and after "already live" and `--rollback`, so a failed hand-over is
retried by the next run), `scripts/publish_website.sh` pushes its publications to the branch
`data-release` of LOD-AM/website: `data/published/*.ttl` exactly as in `releases/live/` (a
publication no longer released is removed) and `data/release-manifest.json`. A workflow there
checks the files against the manifest, adds AAT labels and a changelog entry and opens a pull
request; **the owner merges it**, and the website's normal build deploys the entity pages. Nothing
is pushed while `main` or the branch already has these publications. Only the live release leaves
this machine, never anything else; a failure here leaves the triplestore as it is.

Setup (owner, once), on the **triplestore LXC**:
```bash
sudo ssh-keygen -t ed25519 -N '' -C lodam-website -f /root/.ssh/lodam-website
sudo cat /root/.ssh/lodam-website.pub
```
In LOD-AM/website → Settings → Deploy keys → Add: that public key, title `triplestore LXC`,
**Allow write access**. In the same repository: Settings → Actions → General → Workflow permissions
→ tick **Allow GitHub Actions to create and approve pull requests** (the workflow opens the PR), and
Settings → Rules → a ruleset for `main` with **Require a pull request before merging** (a deploy key
with write access could otherwise push to `main` too; you still merge pull requests as usual, and can
add yourself to the ruleset's bypass list if you push to `main` directly). Then in this
checkout's `.env`: `LODAM_WEBSITE_REPO=git@github.com:LOD-AM/website.git`, and test it:
```bash
sudo scripts/publish_website.sh
```
GitHub's host key is pinned in `deploy/github_known_hosts`. Revoke the hand-over: delete the deploy key.

## Knowledge graph (LOD-AM/planning#35)
`scripts/update_kg.sh` keeps `https://lod-am.net/graph/knowledge-graph` at knowledge-graph `main`,
daily at 05:17 (`lodam-update-kg.timer`), so a merge there is live by the next morning:

1. **Fetch** `main` (public, shallow `git fetch` into `releases/knowledge-graph/repo`).
2. **Changed?** Only `data/` goes in (owner, 2026-11-22: `examples/` stays out of the public graph).
   If `data/` is the same as the live one (git tree hash), nothing happens: a commit that changes
   only docs, tools or examples loads nothing.
3. **Gate:** every GitHub check of that commit must have passed (read from the GitHub API without
   a token). While checks are still running, the run ends quietly and the next one loads it; a
   failed check is a failure (mailed, [Alerts](#alerts-lod-amplanning34)) and loads nothing.
4. **Parse** every `data/**/*.ttl` with Jena's riot (as for releases), plus the graph's description:
   `dcterms:identifier` and `dcterms:source` name the commit, `dcterms:modified` when it was loaded.
5. **Load** in **one** Graph Store `PUT`, then the triple count must match, then reindex and smoke
   test. Any failure puts back the graph as it was just before (a copy taken right before the `PUT`).
6. `releases/knowledge-graph/live/` = the loaded graph, `previous/` = the one before.

It shares the lock with `scripts/update_published.sh` (both reindex, which stops Fuseki) and waits
for a running release update instead of skipping. The first run replaces the graph loaded by hand
(664 triples with `examples/`) with `data/` only (339 triples at knowledge-graph `2f7bcdb`).

| | |
|---|---|
| Update now | `sudo systemctl start --no-block lodam-update-kg` |
| Load even if already live | `sudo scripts/update_kg.sh --force` |
| Back to the previous one | `sudo scripts/update_kg.sh --rollback` |
| Log | `sudo journalctl -u lodam-update-kg -e` |
| Which commit is live | `cat releases/knowledge-graph/live/commit`, or `SELECT ?p ?o WHERE { <https://lod-am.net/graph/knowledge-graph> ?p ?o }` |

The pipeline's `KG_COMMIT` (shapes and vocabularies of a release) stays a deliberate bump by hand in
LOD-AM/pipeline. So for a while the graph can be newer than the knowledge-graph commit a release was
checked against.

## Alerts (LOD-AM/planning#34)
A failed run mails the owner: `lodam-update-published.service` (a rejected release, a failed load,
reindex, smoke test or hand-over to the website), `lodam-update-kg.service` (failed checks of a new
knowledge-graph commit, a parse error, a failed load) and `lodam-webhook.service` (only when it keeps
crashing: 5 failures within 10 minutes) have `OnFailure=lodam-alert@%n.service`, which runs
`deploy/alert.sh`. The mail holds the unit's status and its last 60 journal lines; Fuseki keeps
serving a fully checked release in every case. Normal runs, "already live" and "another update is in
progress" send nothing. The same script runs on the data LXC for the pipeline (LOD-AM/pipeline
`deploy/README.md`).

It sends over SMTP with `curl` (TLS required; port 465 = implicit TLS, otherwise STARTTLS), so no
mail server is needed. Without new settings it uses **Watchtower's SMTP account** from `.env`
(`WATCHTOWER_NOTIFICATION_EMAIL_*`); `LODAM_ALERT_*` lines (`.env.example`) override it, e.g. another
recipient. Setup and test (owner, once):
```bash
git pull && sudo deploy/install.sh            # installs lodam-alert@.service and the OnFailure= lines
sudo deploy/alert.sh --test                   # a test mail: checks the SMTP settings
# a deliberately failing run, through the same OnFailure= path (mail "lodam-alert-check.service failed"):
sudo systemd-run --unit=lodam-alert-check -p OnFailure=lodam-alert@lodam-alert-check.service /bin/false
sudo journalctl -u 'lodam-alert@*' -e          # what the alert unit did
```
The website's workflows are covered by GitHub's own failure mails (github.com → Settings →
Notifications → Actions: "Only notify for failed workflows"): `data release` runs as the owner (the
deploy-key push counts as theirs), and so does `build` on `main` after a merge. The one exception is the
`build` that `data release` starts on the branch: it runs as `github-actions[bot]`, so no mail. Its
failure shows as a red check on the "Data release" pull request, and nothing goes live until that PR is merged.

## Environment Variables

Set in `.env` (template: `.env.example`).

### Fuseki

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `FUSEKI_ADMIN_PASSWORD` | Yes | - | Admin password for Fuseki |
| `FUSEKI_JAVA_OPTS` | No | `-Xmx4G` | JVM options for memory tuning |

### Watchtower

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `WATCHTOWER_NOTIFICATIONS` | No | `email` | Notification method |
| `WATCHTOWER_NOTIFICATION_EMAIL_FROM` | Yes | - | Sender email address |
| `WATCHTOWER_NOTIFICATION_EMAIL_TO` | Yes | - | Recipient email address |
| `WATCHTOWER_NOTIFICATION_EMAIL_SERVER` | Yes | - | SMTP server hostname |
| `WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PORT` | Yes | - | SMTP server port |
| `WATCHTOWER_NOTIFICATION_EMAIL_SERVER_USER` | No | - | SMTP username |
| `WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PASSWORD` | Yes | - | SMTP password |
| `WATCHTOWER_NOTIFICATION_EMAIL_DELAY` | No | `2` | Delay between notifications in seconds |

## Server setup

Decisions for the production server (triple.lod-am.net), with the issues they come from:

- **Dedicated host.** Fuseki runs in Docker inside its own LXC on Proxmox, which runs only this stack. That is why Watchtower is
  host-wide on purpose (#6): it has the Docker socket and updates every
  container on the host, which here means only `lod-am-fuseki` and itself. If
  other containers are ever added to this LXC, revisit this
  (`WATCHTOWER_LABEL_ENABLE=true` plus the label
  `com.centurylinklabs.watchtower.enable=true` restricts it to labelled containers).
- **Reverse proxy on another VM** (Nginx Proxy Manager, #5). It reaches Fuseki
  over the network, so port 3030 can't be bound to `127.0.0.1`; that would cut
  the proxy off. Anything that reaches `<server>:3030` directly bypasses the
  proxy's authentication, so Fuseki's own access control (`shiro.ini`) is what
  protects writes and the admin API.
- **Port 3030 only from the proxy** (Proxmox firewall, LOD-AM/planning#29). The
  datacenter firewall is enabled with input policy `ACCEPT`, so it changes
  nothing for the Proxmox hosts. The LXC's firewall is enabled (options and
  `net0`), also with input policy `ACCEPT`, and has two rules for port 3030, in
  this order: `IN ACCEPT -source <proxy VM> -p tcp -dport 3030`, then
  `IN DROP -p tcp -dport 3030`. **The order matters**: Proxmox can insert new
  rules at the top, and with DROP first the proxy is blocked too. Scripts on the
  LXC itself (`load.sh`, `smoke_test.sh` via `localhost`) aren't affected.
  The rules live on the Proxmox host in `/etc/pve/firewall/<CTID>.fw`, not in this repo.
  Check from a LAN machine other than the proxy:
  `curl -m 5 'http://<lxc-ip>:3030/$/ping'` must time out.
  Rollback: disable the DROP rule.
- **No backups of the triplestore itself** (#4). The store holds no data of its
  own: everything comes from the owner's relational database (backed up
  separately) via the converter, and from LOD-AM/knowledge-graph. The
  whole-machine backup covers the rest. To restore, reload with `sudo scripts/update_kg.sh --force` and
  `sudo scripts/update_published.sh --force`
  instead of relying on a copy of `fuseki-data/`: TDB files copied while Fuseki
  is running are not guaranteed to be consistent.
  Consequence: **don't edit data only in the triplestore** (web UI upload or
  Graph Store writes that exist nowhere else). Change the sources and reload.
- **Container logs are capped** (LOD-AM/website#57): Fuseki logs the text of every query
  (with time, without the client's IP, which only the proxy sees), and the website's privacy
  policy names how long that is kept. `docker-compose.yml` limits each container's log to
  5 files of 10 MB (`json-file` driver); the oldest lines are dropped first, and recreating the
  container drops the log entirely. Check: `sudo docker inspect -f '{{.HostConfig.LogConfig}}' lod-am-fuseki`.

## Architecture

- **Fuseki**: Triplestore server on port 3030
- **Watchtower**: Monitors and updates containers automatically
- **Network**: Isolated `lod-am-network` for internal communication

## Troubleshooting

### Environment variables not set
If you see `set FUSEKI_ADMIN_PASSWORD in .env` (or a similar message), `.env` is missing or incomplete.
Copy `.env.example` to `.env` in this directory and fill it in.

### `bind source path does not exist`
`fuseki-data/` (or `fuseki-config/`) is missing, typically in a fresh clone. Do step 1 of the Quick Start, then `sudo docker compose up -d`.

### Fuseki restarts in a loop / `Not writable`
`docker ps` shows `Restarting (1)` or the health status `unhealthy`, and
`sudo docker logs --tail 30 lod-am-fuseki` shows
`FusekiConfigException: Not writable: /fuseki-base/databases`.
The container runs as UID 9008 and can't write to the folder. Fix the ownership and recreate:
```bash
sudo chown -R 9008:9008 fuseki-data
sudo docker compose up -d --force-recreate fuseki
```
The same error with `/fuseki-base/configuration` means `fuseki-config/` lacks
group write for 9008. Use the `fuseki-config` line of Quick Start step 1, then recreate.

### `git pull`: `insufficient permission for adding an object to repository database .git/objects`
A git command was once run with `sudo` in the checkout and left root-owned files in `.git`. Give
them back (`fuseki-config/` keeps its group): `sudo chown -R "$USER": .git`, then `git pull`. Don't
run git with `sudo` here; the scripts use their own repositories in `releases/`.

### `git pull`: `unable to unlink old 'fuseki-config/assembler.ttl': Permission denied`
`fuseki-config/` still belongs to UID 9008 (the setup before 2026-11-21). Give it
back to your user with group access for Fuseki (Quick Start step 1), then pull again:
```bash
sudo chown -R "$USER":9008 fuseki-config && sudo chmod 2775 fuseki-config
git status    # if the failed pull left changes: git checkout -- .
git pull
```

## Tests

CI (`.github/workflows/test.yml`) starts the real container with this
configuration, loads the knowledge-graph data and runs `scripts/smoke_test.sh`.
It also checks that `scripts/reindex.sh` removes stale index entries, the migration to named
graphs, the release update (`LODAM_TEST=1 scripts/test_update_published.sh`: new release, already
live, replaced, four kinds of rejected release, put back after a failure, rollback), the webhook
receiver (`deploy/test_webhook.sh`), the alert mail (`deploy/test_alert.sh`, curl stubbed), the knowledge-graph update
(`LODAM_TEST=1 scripts/test_update_kg.sh`: first load, unchanged, checks running/failed, parse error, put back, rollback), the hand-over to the website (`scripts/test_publish_website.sh`,
against a local stand-in repository), shellcheck, and that a slow query is stopped by the timeout
(on the CI container only). `scripts/test_update_published.sh` writes to Fuseki: never run it on
production; nor `scripts/test_update_kg.sh`.
The smoke test never writes: its write probe sends invalid Turtle, so it is
safe to run against production.
