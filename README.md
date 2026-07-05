# LOD-AM Triplestore

Docker deployment of the LOD-AM triplestore based on [secoresearch/fuseki](https://hub.docker.com/r/secoresearch/fuseki) (maintained by [SemanticComputing](https://github.com/SemanticComputing/fuseki-docker)) with [nickfedor/watchtower](https://github.com/nickfedor/watchtower) for automatic container updates.

> **Note**: This configuration is aligned with the SemanticComputing/fuseki-docker image approach.

## Quick Start

1. **Set environment variables in your `~/.bashrc`:**
   ```bash
   # Fuseki
   export FUSEKI_ADMIN_PASSWORD="your_secure_password"
   export FUSEKI_JAVA_OPTS="-Xmx4G"  # Optional: JVM memory settings

   # Watchtower Email Notifications
   export WATCHTOWER_NOTIFICATIONS=email
   export WATCHTOWER_NOTIFICATION_EMAIL_FROM="watchtower@yourdomain.com"
   export WATCHTOWER_NOTIFICATION_EMAIL_TO="admin@yourdomain.com"
   export WATCHTOWER_NOTIFICATION_EMAIL_SERVER="smtp.yourdomain.com"
   export WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PORT=587
   export WATCHTOWER_NOTIFICATION_EMAIL_SERVER_USER="smtp_user"
   export WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PASSWORD="smtp_password"
   export WATCHTOWER_NOTIFICATION_EMAIL_DELAY=2  # Optional: default is 2
   ```

2. **Source your .bashrc and set permissions:**
   ```bash
   source ~/.bashrc
   # Fuseki runs as UID 9008 - grant write access to config directory
   sudo chown -R 9008:9008 fuseki-config/
   ```

3. **Start the services:**
   ```bash
   sudo -E docker compose up -d
   ```

4. **Access Fuseki:**
   - Web UI: http://localhost:3030
   - SPARQL endpoint: http://localhost:3030/LOD-AM/sparql

## Configuration

- **Persistent storage**: Fuseki data is stored in a Docker volume (`fuseki_data`) at `/fuseki-base/databases`
- **Custom configs**: Mount your `assembler.ttl` or `shiro.ini` in `./fuseki-config/` (mounted to `/fuseki-base/configuration`)
- **Watchtower**: Monitors and updates containers automatically, sends email notifications on updates
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
sudo -E docker compose down && sudo -E docker compose up -d
```

## Environment Variables

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

## Architecture

- **Fuseki**: Triplestore server on port 3030
- **Watchtower**: Monitors and updates containers automatically
- **Network**: Isolated `lod-am-network` for internal communication
- **Volumes**: Persistent storage for Fuseki databases

## Troubleshooting

### Environment variables not set
If you see `The "VARIABLE" variable is not set`, use `sudo -E` to preserve your environment:
```bash
sudo -E docker compose up -d
```
Or configure sudo to keep specific variables:
```bash
echo 'Defaults env_keep += "FUSEKI_ADMIN_PASSWORD FUSEKI_JAVA_OPTS WATCHTOWER_*"' | sudo tee /etc/sudoers.d/env_keep
```

### Permission denied on configuration directory
The secoresearch/fuseki container runs as UID 9008. If you see `Not writable: /fuseki-base/configuration`, run:
```bash
sudo chown -R 9008:9008 fuseki-config/
```
This is required when using bind mounts for the configuration directory.