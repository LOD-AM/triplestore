#!/usr/bin/env bash
# Install (or update) the release update on the triplestore LXC (LOD-AM/planning#7): the webhook
# receiver, the update service with its path unit (webhook) and daily timer (fallback).
# Usage: sudo deploy/install.sh            (from this checkout; run again after changes in deploy/)
#        sudo deploy/install.sh --remove   (removes the units; releases/, the token and the data stay)
# Creates /etc/lodam/webhook-token on the first run and prints it once: it goes into the pipeline's
# .env on the data LXC as LODAM_RELEASE_WEBHOOK_TOKEN. Nothing else on the machine is changed.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=$PWD
UNITS=${SYSTEMD_UNIT_DIR:-/etc/systemd/system}
NAMES="lodam-webhook.service lodam-update-published.service lodam-update-published.path lodam-update-published.timer"
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
if [ "${1:-}" = --remove ]; then
  systemctl disable --now lodam-webhook.service lodam-update-published.path lodam-update-published.timer 2>/dev/null || true
  for u in $NAMES; do rm -f "$UNITS/$u"; done
  systemctl daemon-reload
  echo "removed the units (releases/, /etc/lodam/webhook-token and Fuseki's data stay)"
  exit 0
fi
[[ $DIR != *[[:space:]]* ]] || { echo "FAIL: the checkout path must not contain spaces: $DIR" >&2; exit 1; }
for cmd in docker rsync ssh python3 curl flock; do
  command -v "$cmd" > /dev/null || { echo "FAIL: $cmd not installed (apt install $cmd)" >&2; exit 1; }
done
grep -q '^LODAM_RELEASE_SOURCE=.' .env 2>/dev/null \
  || echo "note: LODAM_RELEASE_SOURCE is not set in .env yet; updates fail until it is (README, Releases)"

install -d -m 700 /etc/lodam
if [ ! -s /etc/lodam/webhook-token ]; then
  (umask 077; python3 -c "import secrets; print(secrets.token_hex(32))" > /etc/lodam/webhook-token)
  echo "new webhook token (put it into the pipeline's .env on the data LXC as LODAM_RELEASE_WEBHOOK_TOKEN=):"
  cat /etc/lodam/webhook-token
fi
for u in $NAMES; do sed "s|@DIR@|$DIR|g" "deploy/$u" > "$UNITS/$u"; done
systemctl daemon-reload
systemctl enable --now lodam-webhook.service lodam-update-published.path lodam-update-published.timer
systemctl --no-pager --lines=0 status lodam-webhook.service | head -3
systemctl list-timers lodam-update-published.timer --no-pager
echo "installed. Update now: sudo systemctl start --no-block lodam-update-published; log: sudo journalctl -u lodam-update-published -f"
