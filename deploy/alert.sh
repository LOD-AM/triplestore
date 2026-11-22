#!/usr/bin/env bash
# Mail the owner that a LOD-AM unit failed (LOD-AM/planning#34). The same file is in
# LOD-AM/pipeline and LOD-AM/triplestore (deploy/alert.sh); keep the two identical.
#
#   deploy/alert.sh <unit>     what lodam-alert@<unit>.service runs: the units in deploy/ start it
#                              with OnFailure=, so only a failed run sends a mail
#   deploy/alert.sh --test     send a test mail (checks the SMTP settings)
#
# The mail holds the unit's status and the last journal lines of the unit; nothing else. It is sent
# with curl over SMTP (TLS required: port 465 = implicit TLS, any other port = STARTTLS), so the
# machine needs no mail server. Config, read from .env without executing it:
#   LODAM_ALERT_EMAIL_TO (comma-separated), LODAM_ALERT_EMAIL_FROM, LODAM_ALERT_SMTP_SERVER,
#   LODAM_ALERT_SMTP_PORT (default 587), LODAM_ALERT_SMTP_USER, LODAM_ALERT_SMTP_PASSWORD.
# Each falls back to Watchtower's WATCHTOWER_NOTIFICATION_EMAIL_* value, so on the triplestore LXC the
# SMTP account Watchtower uses works without new lines. Nothing configured = no mail, exit 0 (logged).
set -euo pipefail
cd "$(dirname "$0")/.."
ENV=${LODAM_ENV:-.env}
LINES=${LODAM_ALERT_LINES:-60}
log() { echo "alert: $*"; }
# A value from .env without executing it (it holds passwords); surrounding quotes removed
envval() {
  local v; v=$(grep -E "^$1=" "$ENV" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  if [[ $v == \"*\" || $v == \'*\' ]] && [ ${#v} -ge 2 ]; then v=${v:1:-1}; fi
  printf '%s' "$v"
}
cfg() { local v; v=$(envval "LODAM_ALERT_$1"); [ -n "$v" ] || v=$(envval "WATCHTOWER_NOTIFICATION_EMAIL_$2"); printf '%s' "$v"; }

UNIT=${1:?usage: deploy/alert.sh <unit> | --test}
TO=$(cfg EMAIL_TO TO); FROM=$(cfg EMAIL_FROM FROM); SERVER=$(cfg SMTP_SERVER SERVER)
PORT=$(cfg SMTP_PORT SERVER_PORT); USER_=$(cfg SMTP_USER SERVER_USER); PASS=$(cfg SMTP_PASSWORD SERVER_PASSWORD)
PORT=${PORT:-587}
HOST=$(hostname 2>/dev/null || echo unknown-host)
if [ -z "$TO" ] || [ -z "$FROM" ] || [ -z "$SERVER" ]; then
  log "no mail sent for $UNIT: LODAM_ALERT_EMAIL_TO, _EMAIL_FROM and _SMTP_SERVER are not all set in .env"; exit 0
fi
[[ $UNIT =~ ^[A-Za-z0-9@._:-]+$ ]] || { log "FAIL: bad unit name: $UNIT"; exit 2; }

msg=$(mktemp); trap 'rm -f "$msg"' EXIT
{
  if [ "$UNIT" = --test ]; then
    printf 'Subject: [LOD-AM] test mail from %s\n' "$HOST"
  else
    printf 'Subject: [LOD-AM] %s failed on %s\n' "$UNIT" "$HOST"
  fi
  printf 'From: %s\nTo: %s\nDate: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: 8bit\n\n' \
    "$FROM" "$TO" "$(LC_ALL=C date -R)"
  if [ "$UNIT" = --test ]; then
    echo "A test of deploy/alert.sh on $HOST (LOD-AM/planning#34). If you can read this, alerts on failure reach you."
  else
    echo "$UNIT failed on $HOST at $(date '+%Y-%m-%d %H:%M %Z')."
    echo
    case $UNIT in
      lodam-pipeline.*) echo "The live release is unchanged: out/release/ is only replaced by a fully checked one." ;;
      lodam-update-published.*) echo "Fuseki still serves a fully checked release: a failed load puts the live one back. If the hand-over to the website failed, the next run retries it." ;;
      lodam-webhook.*) echo "The webhook receiver keeps failing; releases are still picked up by the daily timer (05:47)." ;;
    esac
    echo "Full log: sudo journalctl -u $UNIT -e"
    echo
    echo "--- systemctl status"
    systemctl status --no-pager --lines=0 "$UNIT" 2>&1 || true
    echo
    echo "--- last $LINES journal lines"
    journalctl -u "$UNIT" -n "$LINES" --no-pager -o short-iso 2>&1 || true
  fi
} > "$msg"

if [ "$PORT" = 465 ]; then url="smtps://$SERVER:465"; else url="smtp://$SERVER:$PORT"; fi
rcpt=()
IFS=', ' read -r -a tos <<< "$TO"
for r in "${tos[@]}"; do [ -n "$r" ] && rcpt+=(--mail-rcpt "$r"); done
# The login goes to curl on stdin (a config file), never on the command line
q() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }
{ [ -n "$USER_" ] && printf 'user = %s\n' "$(q "$USER_:$PASS")"; true; } |
  curl -sS -K - --ssl-reqd --max-time 60 --crlf --mail-from "$FROM" "${rcpt[@]}" -T "$msg" "$url"
log "mail sent to $TO about $UNIT"
