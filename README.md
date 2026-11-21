# LOD-AM Triplestore

Docker deployment of the LOD-AM triplestore based on [secoresearch/fuseki](https://hub.docker.com/r/secoresearch/fuseki) (maintained by [SemanticComputing](https://github.com/SemanticComputing/fuseki-docker)) with [nickfedor/watchtower](https://github.com/nickfedor/watchtower) for automatic container updates.

> **Note**: This configuration is aligned with the SemanticComputing/fuseki-docker image approach.

## Quick Start

1. **Create local directories and set permissions:**
   ```bash
   mkdir -p fuseki-data fuseki-config
   # Fuseki runs as UID 9008 - grant write access
   sudo chown -R 9008:9008 fuseki-data/ fuseki-config/
   ```

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
- **Excludes reasoning** (no RDFS/OWL inference)

> **Important**: When using bind mounts for configuration, manually edit `assembler.ttl` to enable endpoints rather than using environment variables (due to permission restrictions).

To apply configuration changes:
```bash
sudo docker compose down && sudo docker compose up -d
```

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
  protects writes and the admin API. Restricting port 3030 to the proxy (bind
  address or firewall) is still open (LOD-AM/planning#29).
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

### Permission denied errors
The secoresearch/fuseki container runs as UID 9008. If you see `Not writable` errors, ensure both directories have correct ownership:
```bash
sudo chown -R 9008:9008 fuseki-data/ fuseki-config/
```

## Tests

CI (`.github/workflows/test.yml`) starts the real container with this
configuration, loads the knowledge-graph data and runs `scripts/smoke_test.sh`.
The smoke test never writes: its write probe sends invalid Turtle, so it is
safe to run against production.
