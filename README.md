# LOD-AM Triplestore

Docker deployment of the LOD-AM triplestore based on [secoresearch/fuseki](https://hub.docker.com/r/secoresearch/fuseki) (maintained by [SemanticComputing](https://github.com/SemanticComputing/fuseki-docker)) with [nickfedor/watchtower](https://github.com/nickfedor/watchtower) for automatic container updates.

> **Note**: This configuration is aligned with the SemanticComputing/fuseki-docker image approach.

## Quick Start

1. **Create the data folder and hand both folders to Fuseki (required, before the first start):**
   ```bash
   mkdir -p fuseki-data
   sudo chown -R 9008:9008 fuseki-data fuseki-config
   ls -ldn fuseki-data fuseki-config    # both lines must show 9008 9008
   ```
   Fuseki runs as UID 9008 and must be able to write to both. This applies to every
   fresh clone: `fuseki-data/` isn't in git. If the folder is missing, `docker compose up`
   stops with `bind source path does not exist`; if it belongs to someone else, Fuseki
   restarts in a loop (see Troubleshooting).

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

5. **Load the knowledge graph** (from a checkout of [LOD-AM/knowledge-graph](https://github.com/LOD-AM/knowledge-graph)):
   ```bash
   scripts/load.sh --replace ../knowledge-graph/data ../knowledge-graph/examples
   ```
   `--replace` empties the default graph first, so the store then holds exactly these files.
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
  whole-machine backup covers the rest. To restore, reload with `scripts/load.sh`
  instead of relying on a copy of `fuseki-data/`: TDB files copied while Fuseki
  is running are not guaranteed to be consistent.
  Consequence: **don't edit data only in the triplestore** (web UI upload or
  Graph Store writes that exist nowhere else). Change the sources and reload.

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
sudo chown -R 9008:9008 fuseki-data fuseki-config
sudo docker compose up -d --force-recreate fuseki
```

## Tests

CI (`.github/workflows/test.yml`) starts the real container with this
configuration, loads the knowledge-graph data and runs `scripts/smoke_test.sh`.
It also checks that `scripts/reindex.sh` removes stale index entries and that
a slow query is stopped by the timeout (on the CI container only).
The smoke test never writes: its write probe sends invalid Turtle, so it is
safe to run against production.
