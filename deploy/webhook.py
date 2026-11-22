#!/usr/bin/env python3
"""Webhook receiver for new pipeline releases (LOD-AM/planning#7). Standard library only.

The pipeline run on the data LXC (LOD-AM/pipeline deploy/run.sh) sends, after a new release:
  POST /lodam-release   Authorization: Bearer <token>   {"manifest_sha256": "<64 hex>"}
A valid request only writes the trigger file; lodam-update-published.path then starts
scripts/update_published.sh, which fetches and checks the release itself. So the receiver needs
no rights on Fuseki, Docker or the data: it runs as an unprivileged dynamic user (systemd), and
a forged request could at most start an update that finds nothing new.

Answers: 202 accepted, 400 bad body, 401 bad token, 404 other path, 405 other method, 413 body
too large. The token is read once at start (systemd LoadCredential, never in the environment);
the log names the client address and the sha, never the token.
Env: LODAM_WEBHOOK_LISTEN (default 0.0.0.0:9300), LODAM_WEBHOOK_TOKEN_FILE (default
$CREDENTIALS_DIRECTORY/token), LODAM_WEBHOOK_TRIGGER (default $RUNTIME_DIRECTORY/trigger).
"""
import hmac
import json
import os
import re
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

PATH = "/lodam-release"
SHA = re.compile(r"[0-9a-f]{64}")
MAX_BODY = 1024


def config():
    host, _, port = os.environ.get("LODAM_WEBHOOK_LISTEN", "0.0.0.0:9300").rpartition(":")
    token_file = os.environ.get("LODAM_WEBHOOK_TOKEN_FILE") or os.path.join(os.environ.get("CREDENTIALS_DIRECTORY", ""), "token")
    trigger = os.environ.get("LODAM_WEBHOOK_TRIGGER") or os.path.join(os.environ.get("RUNTIME_DIRECTORY", "/run/lodam-release"), "trigger")
    try:
        token = Path(token_file).read_text(encoding="utf-8").strip()
    except OSError as e:
        sys.exit(f"webhook: cannot read the token ({e})")
    if len(token) < 32:
        sys.exit("webhook: the token must have at least 32 characters (deploy/install.sh generates one)")
    return (host or "0.0.0.0", int(port)), token.encode(), Path(trigger)


ADDR, TOKEN, TRIGGER = config()


class Handler(BaseHTTPRequestHandler):
    server_version = "lodam-webhook"
    sys_version = ""

    def answer(self, code, text):
        body = (text + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != PATH:
            return self.answer(404, "not found")
        auth = self.headers.get("Authorization", "")
        if not (auth.startswith("Bearer ") and hmac.compare_digest(auth[7:].strip().encode(), TOKEN)):
            return self.answer(401, "unauthorized")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self.answer(400, "bad Content-Length")
        if length > MAX_BODY:
            return self.answer(413, "body too large")
        try:
            sha = json.loads(self.rfile.read(length) or b"{}").get("manifest_sha256", "")
        except (ValueError, AttributeError):
            return self.answer(400, "body must be JSON")
        if not isinstance(sha, str) or not SHA.fullmatch(sha):
            return self.answer(400, "manifest_sha256 must be 64 hex characters")
        tmp = TRIGGER.with_suffix(".tmp")
        tmp.write_text(f"{sha} {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n", encoding="utf-8")
        tmp.replace(TRIGGER)                               # one change event for the path unit
        self.log_message("release %s signalled; update triggered", sha)
        return self.answer(202, "accepted: the triplestore will fetch and check the release")

    def do_GET(self):
        self.answer(405, "POST only")

    do_PUT = do_DELETE = do_PATCH = do_HEAD = do_GET


if __name__ == "__main__":
    TRIGGER.parent.mkdir(parents=True, exist_ok=True)
    print(f"webhook: listening on {ADDR[0]}:{ADDR[1]}{PATH}, trigger {TRIGGER}", flush=True)
    HTTPServer(ADDR, Handler).serve_forever()
