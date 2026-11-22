#!/usr/bin/env bash
# Tests of deploy/alert.sh (LOD-AM/planning#34) with curl, systemctl, journalctl and hostname
# stubbed; no mail is sent. The same file is in LOD-AM/pipeline and LOD-AM/triplestore.
#   1. nothing configured: no mail, exit 0
#   2. LODAM_ALERT_*: mail with subject, unit status and journal lines; STARTTLS on 587;
#      the password reaches curl on stdin only, never in its arguments
#   3. fallback to WATCHTOWER_NOTIFICATION_EMAIL_*; port 465 = smtps; two recipients; quotes in .env
#   4. --test sends a test mail; a failing curl fails the alert
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
{ echo "ARGS: $*"; echo "STDIN: $(cat)"; } > "$T/curl.log"
while [ $# -gt 0 ]; do [ "$1" = -T ] && cp "$2" "$T/mail.txt"; shift; done
[ "${FAIL_CURL:-}" = 1 ] && exit 7; exit 0
STUB
printf '#!/bin/sh\necho "STATUS of $*"\n' > "$T/bin/systemctl"
printf '#!/bin/sh\necho "JOURNAL of $*"\n' > "$T/bin/journalctl"
printf '#!/bin/sh\necho test-lxc\n' > "$T/bin/hostname"
chmod +x "$T/bin/"*
export T PATH="$T/bin:$PATH" LODAM_ENV="$T/env"
fail() { echo "FAIL: $*"; exit 1; }
alert() { rm -f "$T/curl.log" "$T/mail.txt"; bash deploy/alert.sh "$@" > "$T/out.log" 2>&1; }

# 1
: > "$T/env"
alert lodam-pipeline.service || fail "1: exit $?"
[ ! -e "$T/curl.log" ] || fail "1: curl was called"; grep -q "no mail sent" "$T/out.log" || fail "1: no log line"
echo "ok 1 nothing configured: no mail"

# 2
printf '%s\n' LODAM_ALERT_EMAIL_TO=owner@example.invalid LODAM_ALERT_EMAIL_FROM=lxc@example.invalid \
  LODAM_ALERT_SMTP_SERVER=smtp.example.invalid LODAM_ALERT_SMTP_USER=u 'LODAM_ALERT_SMTP_PASSWORD=pa"ss\word' > "$T/env"
alert lodam-pipeline.service || { cat "$T/out.log"; fail "2: exit"; }
grep -q '^Subject: \[LOD-AM\] lodam-pipeline.service failed on test-lxc$' "$T/mail.txt" || fail "2: subject"
grep -q 'STATUS of status --no-pager --lines=0 lodam-pipeline.service' "$T/mail.txt" || fail "2: status"
grep -q 'JOURNAL of -u lodam-pipeline.service -n 60' "$T/mail.txt" || fail "2: journal"
grep -q 'The live release is unchanged' "$T/mail.txt" || fail "2: hint"
grep -q 'ARGS: .*--ssl-reqd .*--mail-rcpt owner@example.invalid .*smtp://smtp.example.invalid:587$' "$T/curl.log" || fail "2: curl args"
grep -q 'pa' <(grep ARGS "$T/curl.log") && fail "2: password in curl's arguments"
grep -qF 'STDIN: user = "u:pa\"ss\\word"' "$T/curl.log" || fail "2: login on stdin"
echo "ok 2 LODAM_ALERT_*: mail with status and journal, login only on stdin"

# 3
printf '%s\n' 'WATCHTOWER_NOTIFICATION_EMAIL_TO="a@example.invalid, b@example.invalid"' \
  WATCHTOWER_NOTIFICATION_EMAIL_FROM=wt@example.invalid WATCHTOWER_NOTIFICATION_EMAIL_SERVER=smtp.example.invalid \
  WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PORT=465 > "$T/env"
alert lodam-update-published.service || fail "3: exit"
grep -q -- '--mail-rcpt a@example.invalid --mail-rcpt b@example.invalid' "$T/curl.log" || fail "3: recipients"
grep -q 'smtps://smtp.example.invalid:465$' "$T/curl.log" || fail "3: smtps"
grep -q '^From: wt@example.invalid$' "$T/mail.txt" || fail "3: from"
grep -q 'STDIN: $' "$T/curl.log" || fail "3: no login expected"
echo "ok 3 Watchtower fallback, smtps, two recipients"

# 4
alert --test || fail "4: --test exit"
grep -q '^Subject: \[LOD-AM\] test mail from test-lxc$' "$T/mail.txt" || fail "4: test subject"
FAIL_CURL=1 alert lodam-webhook.service && fail "4: a failing curl must fail the alert"
alert 'bad unit;rm' && fail "4: bad unit name accepted"
echo "ok 4 --test, failing curl, bad unit name"
echo "all alert tests passed"
