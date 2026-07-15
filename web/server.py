#!/usr/bin/env python3
"""Small status web UI server for the Bluesound Vault -> TrueNAS mover job.

Stdlib-only HTTP server. Serves a static Polish-language status page and two
JSON API endpoints that expose the mover's state.json and mover.log.
"""

import html
import json
import os
import re
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
PHASE_FILE = STATE_DIR / "phase"

VAULT_STATUS_URL = (
    f"http://{VAULT_HOST}:{VAULT_STATUS_PORT}/ripencstat?noheader=1"
)
VAULT_STATUS_TIMEOUT_SECS = 5

RC_ADDR = os.environ.get("RCLONE_RC_ADDR", "127.0.0.1:5572")
RC_STATS_TIMEOUT_SECS = 2
RC_PHASES = {"copy", "verify", "delete", "idle"}

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


_EMPTY_TRACK = {"active": False, "track": None, "title": None, "artist_album": None}


def _strip_tags(s):
    return re.sub(r"<[^>]+>", "", s)


def _clean_body(body):
    # Remove HTML comments so commented-out template <li> examples are not parsed.
    return re.sub(r"<!--.*?-->", "", body, flags=re.S)


def _section_li(clean_body, heading):
    # Return the inner HTML of the first <li>...</li> that appears AFTER the
    # given section heading text, or None. clean_body must already have
    # comments stripped.
    idx = clean_body.find(heading)
    if idx < 0:
        return None
    m = re.search(r"<li[^>]*>(.*?)</li>", clean_body[idx:], flags=re.S)
    return m.group(1) if m else None


def _parse_track_li(inner):
    """Parse the inner HTML of a rip/encode status <li> into a track dict."""
    if inner is None:
        return dict(_EMPTY_TRACK)
    text = inner.strip()
    m = re.search(r"Track\s+(\d+)\s*:\s*(.*)", text, flags=re.S)
    if not m:
        # idle strings ("No CD inserted." / "No tracks to encode.") or anything non-track
        return dict(_EMPTY_TRACK)
    track = int(m.group(1))
    rest = m.group(2)
    parts = re.split(r"<br\s*/?>", rest, maxsplit=1)
    title = html.unescape(_strip_tags(parts[0])).strip() or None
    artist_album = (
        html.unescape(_strip_tags(parts[1])).strip() if len(parts) > 1 else None
    )
    if artist_album == "":
        artist_album = None
    return {"active": True, "track": track, "title": title, "artist_album": artist_album}


def fetch_rip_status():
    """Fetch the Vault ripencstat endpoint and parse rip/encode status.

    Returns a dict with "reachable" (bool), "idle" (True/False/None - None
    when unreachable, matching the previous live_vault_idle contract),
    "ripping" and "encoding" track dicts. Never raises.
    """
    try:
        with urllib.request.urlopen(
            VAULT_STATUS_URL, timeout=VAULT_STATUS_TIMEOUT_SECS
        ) as resp:
            body = resp.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, OSError, ValueError):
        return {
            "reachable": False,
            "idle": None,
            "ripping": dict(_EMPTY_TRACK),
            "encoding": dict(_EMPTY_TRACK),
        }

    clean = _clean_body(body)
    idle = "No CD inserted." in clean and "No tracks to encode." in clean
    ripping = _parse_track_li(_section_li(clean, "CD Ripping Status"))
    encoding = _parse_track_li(_section_li(clean, "Encoding Status (FLAC)"))
    return {"reachable": True, "idle": idle, "ripping": ripping, "encoding": encoding}


def read_phase():
    """Read the mover's current phase marker (copy/verify/delete/idle).

    Never raises; falls back to "idle" on any error or unknown content.
    """
    try:
        with open(PHASE_FILE, "r", encoding="utf-8") as f:
            phase = f.read().strip().lower()
        return phase if phase in RC_PHASES else "idle"
    except OSError:
        return "idle"


def _entry_name(entry):
    """Extract a display name from an rclone rc transferring/checking entry."""
    return entry.get("name") if isinstance(entry, dict) else str(entry)


def fetch_transfer_progress(pending_files=0):
    """Poll rclone's rc core/stats endpoint for live transfer progress.

    Returns {"active": False, "phase": <phase>} when no rclone op is running
    (rc port closed) or on any error. Returns a richer dict when an rclone
    operation is actively reporting stats.
    """
    phase = read_phase()
    try:
        req = urllib.request.Request(
            "http://%s/core/stats" % RC_ADDR,
            data=b"{}",
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=RC_STATS_TIMEOUT_SECS) as resp:
            stats = json.loads(resp.read())
    except (urllib.error.URLError, OSError, ValueError):
        return {"active": False, "phase": phase}

    bytes_done = int(stats.get("bytes", 0) or 0)
    total_bytes = int(stats.get("totalBytes", 0) or 0)
    speed = float(stats.get("speed", 0) or 0)
    eta = stats.get("eta", None)
    transfers = int(stats.get("transfers", 0) or 0)
    total_transfers = int(stats.get("totalTransfers", 0) or 0)
    checks = int(stats.get("checks", 0) or 0)
    total_checks = int(stats.get("totalChecks", 0) or 0)
    transferring = stats.get("transferring") or []
    checking = stats.get("checking") or []

    if phase == "verify":
        files_done = checks
        stable_total = int(pending_files or 0)
        files_total = stable_total if stable_total > 0 else total_checks
        files_total = max(files_total, files_done)
        current_file = _entry_name(checking[0]) if checking else None
    else:
        files_done = transfers
        files_total = total_transfers
        current_file = _entry_name(transferring[0]) if transferring else None

    percent = int(bytes_done * 100 / total_bytes) if total_bytes > 0 else 0
    percent = max(0, min(100, percent))
    eta_seconds = int(eta) if isinstance(eta, (int, float)) else None

    return {
        "active": True,
        "phase": phase,
        "percent": percent,
        "bytes": bytes_done,
        "total_bytes": total_bytes,
        "speed": speed,
        "eta_seconds": eta_seconds,
        "files_done": files_done,
        "files_total": files_total,
        "current_file": current_file,
    }


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
        rip_status = fetch_rip_status()
        response["live_vault_idle"] = rip_status["idle"]
        response["rip"] = {
            "reachable": rip_status["reachable"],
            "ripping": rip_status["ripping"],
            "encoding": rip_status["encoding"],
        }
        response["transfer"] = fetch_transfer_progress(state.get("pending_music_files", 0))
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
