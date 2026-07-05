# LOD-AM Triplestore

Docker deployment of the LOD-AM triplestore based on [secoresearch/fuseki](https://hub.docker.com/r/secoresearch/fuseki) with [nickfedor/watchtower](https://github.com/nickfedor/watchtower) for automatic container updates.

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

2. **Source your .bashrc:**
   ```bash
   source ~/.bashrc
   ```

3. **Start the services:**
   ```bash
   sudo -E docker compose up -d
   ```

4. **Access Fuseki:**
   - Web UI: http://localhost:3030
   - SPARQL endpoint: http://localhost:3030/LOD-AM/sparql

## Configuration

- **Persistent storage**: Fuseki data is stored in a Docker volume (`fuseki_data`)
- **Custom configs**: Mount your `config.ttl` or `shiro.ini` in `./fuseki-config/`
- **Watchtower**: Monitors and updates containers automatically, sends email notifications on updates

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