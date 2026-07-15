#!/usr/bin/env python3
"""Small status web UI server for the Bluesound Vault -> TrueNAS mover job.

Stdlib-only HTTP server. Serves a static Polish-language status page and two
JSON API endpoints that expose the mover's state.json and mover.log.
"""

import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

WEB_DIR = Path(__file__).resolve().parent
INDEX_HTML = WEB_DIR / "index.html"
STATIC_DIR = WEB_DIR / "static"

WEB_PORT = int(os.environ.get("WEB_PORT", "8080"))
STATE_DIR = Path(os.environ.get("STATE_DIR", "/state"))
LOG_DIR = Path(os.environ.get("LOG_DIR", "/log"))
VAULT_HOST = os.environ.get("VAULT_HOST", "192.168.0.20")
VAULT_STATUS_PORT = int(os.environ.get("VAULT_STATUS_PORT", "2000"))
LOG_TAIL_LINES = int(os.environ.get("LOG_TAIL_LINES", "200"))

STATE_FILE = STATE_DIR / "state.json"
LOG_FILE = LOG_DIR / "mover.log"

VAULT_STATUS_URL = (
    f"http://{VAULT_HOST}:{VAULT_STATUS_PORT}/ripencstat?noheader=1"
)
VAULT_STATUS_TIMEOUT_SECS = 5

DEFAULT_STATE = {
    "updated_at": None,
    "vault_idle": False,
    "idle_streak": 0,
    "pending_music_files": 0,
    "pending_music_albums": 0,
    "last_run": {
        "at": None,
        "action": None,
        "copied": 0,
        "verified": 0,
        "deleted": 0,
        "differ": 0,
        "missing": 0,
        "errors": 0,
    },
    "pending_reindex": False,
    "last_reindex_at": None,
    "safe_to_power_off": False,
    "safe_reason": "",
}


def read_state():
    """Read and parse state.json. Return (state_dict, state_available)."""
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("state.json does not contain a JSON object")
        return data, True
    except (OSError, ValueError, json.JSONDecodeError):
        return dict(DEFAULT_STATE), False


def fetch_live_vault_idle():
    """Fetch the Vault ripencstat endpoint and determine idle status.

    Returns True/False on success, None if the fetch failed.
    """
    try:
        with urllib.request.urlopen(
            VAULT_STATUS_URL, timeout=VAULT_STATUS_TIMEOUT_SECS
        ) as resp:
            body = resp.read().decode("utf-8", errors="replace")
        return "No CD inserted." in body and "No tracks to encode." in body
    except (urllib.error.URLError, OSError, ValueError):
        return None


def read_log_tail():
    """Return the last LOG_TAIL_LINES lines of mover.log, newest first."""
    try:
        with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return []

    lines = [line.rstrip("\n") for line in lines]
    tail = lines[-LOG_TAIL_LINES:] if LOG_TAIL_LINES > 0 else lines
    tail.reverse()
    return tail


class StatusRequestHandler(BaseHTTPRequestHandler):
    server_version = "BluesoundMoverStatus/1.0"

    def log_message(self, fmt, *args):
        # Keep default access logging but route through print for consistency.
        print("%s - %s" % (self.address_string(), fmt % args))

    def _send_bytes(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, status, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self._send_bytes(status, "application/json; charset=utf-8", body)

    def _send_file(self, path, content_type):
        try:
            with open(path, "rb") as f:
                body = f.read()
        except OSError:
            self._send_json(404, {"error": "not found"})
            return
        self._send_bytes(200, content_type, body)

    def do_GET(self):
        if self.path == "/":
            self._send_file(INDEX_HTML, "text/html; charset=utf-8")
        elif self.path == "/static/app.js":
            self._send_file(
                STATIC_DIR / "app.js", "application/javascript; charset=utf-8"
            )
        elif self.path == "/static/style.css":
            self._send_file(STATIC_DIR / "style.css", "text/css; charset=utf-8")
        elif self.path == "/api/status":
            self._handle_api_status()
        elif self.path == "/api/log":
            self._handle_api_log()
        else:
            self._send_json(404, {"error": "not found"})

    def _handle_api_status(self):
        state, state_available = read_state()
        response = dict(state)
        response["state_available"] = state_available
        response["live_vault_idle"] = fetch_live_vault_idle()
        self._send_json(200, response)

    def _handle_api_log(self):
        self._send_json(200, {"lines": read_log_tail()})


def main():
    server = ThreadingHTTPServer(("0.0.0.0", WEB_PORT), StatusRequestHandler)
    print(
        f"Bluesound mover status UI listening on 0.0.0.0:{WEB_PORT} "
        f"(state_dir={STATE_DIR}, log_dir={LOG_DIR}, vault={VAULT_HOST}:{VAULT_STATUS_PORT})"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Shutting down.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
