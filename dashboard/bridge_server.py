#!/usr/bin/env python3
"""
bridge_server.py
Live link: Web Dashboard  <->  MATLAB  (and optional CST launch helper).

What it does
------------
* Serves the dashboard (index.html / app.js / style.css).
* The dashboard POSTs every input change (antenna, ML model, slider values and
  the numbers it is displaying) to   POST /api/matlab/input
* MATLAB (matlab/live_verify.m) polls   GET /api/matlab/input?since=<seq>
  so the input shows up in MATLAB immediately, re-computes it independently and
  posts its verification back to   POST /api/matlab/result
* The dashboard polls   GET /api/status   to show the *real* MATLAB link state
  (MATLAB counts as connected only while it is actually polling).
* POST /api/matlab/launch starts MATLAB with the live link (live_verify).

The latest input is also written (atomically) to data/user_input.json so MATLAB
can fall back to watching that file when the bridge is not reachable.

Public website
--------------
The dashboard is also published on GitHub Pages (PUBLIC_SITE_ORIGIN). That page
cannot start programs on your PC; it talks to this bridge on your own machine
(http://127.0.0.1:8000) instead. The API therefore answers CORS requests from
that origin and from dashboards served on another local port - and from nobody
else unless you add origins with --allow-origin / BRIDGE_ALLOW_ORIGINS.
POST requests must be application/json, so other websites cannot fire
"simple" cross-site requests (e.g. a hidden form) at the launch endpoint.

Usage
-----
    python dashboard/bridge_server.py            # http://localhost:8000
    python dashboard/bridge_server.py --port 8080 --host 127.0.0.1
    python dashboard/bridge_server.py --allow-origin https://example.org

Only the Python standard library is used.
"""

import argparse
import glob
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from urllib.parse import parse_qs, urlparse

DASHBOARD_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(DASHBOARD_DIR, ".."))
MATLAB_DIR = os.path.join(PROJECT_ROOT, "matlab")
DEFAULT_DATA_FILE = os.path.join(PROJECT_ROOT, "data", "user_input.json")
CST_EXE = r"C:\CST\AMD64\CST DESIGN ENVIRONMENT_AMD64.exe"

# MATLAB is reported as connected while its last poll is younger than this.
MATLAB_TIMEOUT_S = 3.0
# Upper bound for request bodies (inputs/results are a few KB).
MAX_BODY_BYTES = 1_000_000

# Browser origins allowed to call the API cross-origin, in addition to the
# dashboard served by this bridge itself (same origin needs no CORS):
#  * the public website (GitHub Pages) of this repository,
#  * dashboards opened from another local port (http://localhost:5500, ...).
PUBLIC_SITE_ORIGIN = "https://jackreacher007316.github.io"
PUBLIC_SITE_URL = PUBLIC_SITE_ORIGIN + "/anteena/"
DEFAULT_ALLOWED_ORIGINS = (PUBLIC_SITE_ORIGIN,)
LOOPBACK_ORIGIN_RE = re.compile(r"^http://(localhost|127\.0\.0\.1|\[::1\])(:\d{1,5})?$")
# POST endpoints; they only accept Content-Type: application/json.
API_POST_PATHS = ("/api/matlab/input", "/api/matlab/simulate",
                  "/api/matlab/result", "/api/matlab/launch")

# MATLAB commands the launch endpoint may run (target -> MATLAB command).
LAUNCH_TARGETS = {
    "live": "live_verify",
    "gui": "antenna_gui",
    "verify": "verify",
}


def _release_key(path):
    """Sort key so that R2026b > R2026a > R2025b ... (newest MATLAB last)."""
    m = re.search(r"R(\d{4})([ab])", path)
    return (int(m.group(1)), m.group(2)) if m else (0, "")


def normalize_origin(origin):
    """'https://Example.org/' -> 'https://example.org' ('*' stays '*')."""
    origin = str(origin).strip().rstrip("/")
    return origin if origin == "*" else origin.lower()


def parse_origin_list(text):
    """Origins from an env var: separated by commas and/or whitespace."""
    return [normalize_origin(o) for o in re.split(r"[,\s]+", text or "") if o.strip()]


_MATLAB_CACHE = {"at": 0.0, "exe": None}


def find_matlab(max_age=30.0):
    """Cached wrapper around _find_matlab() (status is polled every ~1.5 s)."""
    now = time.time()
    if now - _MATLAB_CACHE["at"] > max_age:
        _MATLAB_CACHE["exe"] = _find_matlab()
        _MATLAB_CACHE["at"] = now
    return _MATLAB_CACHE["exe"]


def _find_matlab():
    """Locate a MATLAB executable: $MATLAB_EXE, newest standard install, PATH."""
    env = os.environ.get("MATLAB_EXE")
    if env and os.path.isfile(env):
        return env
    patterns = []
    if os.name == "nt":
        roots = {os.environ.get("ProgramFiles", r"C:\Program Files"), r"C:\Program Files"}
        patterns = [os.path.join(r, "MATLAB", "R*", "bin", "matlab.exe") for r in roots]
    elif sys.platform == "darwin":
        patterns = ["/Applications/MATLAB_R*.app/bin/matlab"]
    else:
        patterns = ["/usr/local/MATLAB/R*/bin/matlab", "/opt/MATLAB/R*/bin/matlab"]
    found = sorted({p for pat in patterns for p in glob.glob(pat)}, key=_release_key)
    if found:
        return found[-1]
    return shutil.which("matlab")


def atomic_write_json(path, data, retries=5):
    """Write JSON so readers (MATLAB) never see a half-written file."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".user_input.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
        for attempt in range(retries):
            try:
                os.replace(tmp, path)
                return True
            except PermissionError:
                # Windows: another process may hold the file open for a moment.
                if attempt == retries - 1:
                    raise
                time.sleep(0.02)
    except Exception as exc:  # noqa: BLE001 - never let file IO kill the link
        try:
            os.unlink(tmp)
        except OSError:
            pass
        print(f"[bridge] warning: could not write {path}: {exc}")
    return False


class LinkState:
    """Thread-safe store for the latest dashboard input and MATLAB's reply."""

    def __init__(self, data_file):
        self.lock = threading.Lock()
        self.file_lock = threading.Lock()
        self._written_seq = -1
        self.data_file = data_file
        self.session = uuid.uuid4().hex[:8]
        self.seq = 0
        self.latest = None
        self.matlab_last_poll = None
        self.matlab_version = None
        self.matlab_result = None
        self.matlab_result_at = None
        self._cst_cache = (0.0, False)
        self._load_previous_input()

    def _load_previous_input(self):
        """Start from the last saved input so MATLAB has something to show."""
        try:
            with open(self.data_file, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            return
        if isinstance(data, dict) and isinstance(data.get("params"), dict):
            prev_seq = data.get("seq")
            self.seq = int(prev_seq) if isinstance(prev_seq, (int, float)) else 0
            self.seq += 1
            data["seq"] = self.seq
            data["session"] = self.session
            self.latest = data

    # -- dashboard -> bridge ------------------------------------------------
    def publish_input(self, payload):
        record = {
            "antenna": str(payload.get("antenna", "patch")),
            "antenna_name": str(payload.get("antenna_name", "")),
            "model": str(payload.get("model", "gpr")),
            "params": payload.get("params", {}),
        }
        for key in ("param_meta", "freq_range", "dashboard", "client_time"):
            if key in payload:
                record[key] = payload[key]
        with self.lock:
            self.seq += 1
            record["seq"] = self.seq
            record["session"] = self.session
            record["updated_at"] = time.time()
            self.latest = record
            connected = self._matlab_connected_locked()
        with self.file_lock:
            # Requests are handled on parallel threads: never let an older
            # input overwrite a newer one in the mirror file.
            if record["seq"] > self._written_seq:
                atomic_write_json(self.data_file, record)
                self._written_seq = record["seq"]
        return record["seq"], connected

    # -- MATLAB -> bridge ---------------------------------------------------
    def matlab_poll(self, since, version=None, session=None, is_matlab=True):
        with self.lock:
            if is_matlab:  # only MATLAB's own polls count as its heartbeat
                self.matlab_last_poll = time.time()
                if version:
                    self.matlab_version = version
            if self.latest is None:
                return {"seq": 0, "session": self.session, "status": "empty"}
            same_session = session is None or session == self.session
            if since is not None and since == self.seq and same_session:
                return {"seq": self.seq, "session": self.session, "unchanged": True}
            return dict(self.latest)

    def store_result(self, result):
        with self.lock:
            self.matlab_last_poll = time.time()
            if isinstance(result.get("matlab_version"), str):
                self.matlab_version = result["matlab_version"]
            result["received_at"] = time.time()
            self.matlab_result = result
            self.matlab_result_at = result["received_at"]

    # -- status ---------------------------------------------------------------
    def _matlab_connected_locked(self):
        return (self.matlab_last_poll is not None
                and time.time() - self.matlab_last_poll < MATLAB_TIMEOUT_S)

    def matlab_connected(self):
        with self.lock:
            return self._matlab_connected_locked()

    def cst_running(self):
        """Windows-only process check, cached for 10 s (it spawns tasklist)."""
        if os.name != "nt":
            return False
        stamp, value = self._cst_cache
        if time.time() - stamp < 10:
            return value
        try:
            out = subprocess.check_output(
                ["tasklist", "/FI", "IMAGENAME eq CST DESIGN ENVIRONMENT_AMD64.exe"],
                text=True, timeout=5)
            value = "CST DESIGN ENVIRONMENT" in out
        except (OSError, subprocess.SubprocessError):
            value = False
        self._cst_cache = (time.time(), value)
        return value

    def status(self):
        with self.lock:
            last = self.matlab_last_poll
            data = {
                "status": "online",
                "bridge": "online",
                "session": self.session,
                "matlab_connected": self._matlab_connected_locked(),
                "matlab_last_seen_s": None if last is None else round(time.time() - last, 2),
                "matlab_version": self.matlab_version,
                "input_seq": self.seq,
                "input_antenna": self.latest.get("antenna") if self.latest else None,
                "matlab_seq": self.matlab_result.get("seq") if self.matlab_result else None,
                "matlab_result": self.matlab_result,
            }
        matlab_exe = find_matlab()
        data.update({
            "matlab_exe": matlab_exe,
            "project_root": PROJECT_ROOT,
            "matlab_dir": MATLAB_DIR,
            "data_file": self.data_file,
            "cst_running": self.cst_running(),
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        })
        return data


class BridgeRequestHandler(http.server.SimpleHTTPRequestHandler):
    state = None          # LinkState, set in make_server()
    allowed_origins = frozenset(DEFAULT_ALLOWED_ORIGINS)  # see make_server()
    quiet_paths = ("/api/status", "/api/matlab/input", "/api/matlab/result",
                   "/api/matlab/simulate", "/api/matlab/ping")

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DASHBOARD_DIR, **kwargs)

    # Keep the console readable: the link endpoints are hit several times/s.
    def log_message(self, fmt, *args):
        if urlparse(self.path).path in self.quiet_paths:
            return
        super().log_message(fmt, *args)

    # -- routing ------------------------------------------------------------
    def do_OPTIONS(self):
        """CORS preflight (the public website POSTs JSON to this bridge)."""
        origin = self.headers.get("Origin")
        if not self.origin_allowed(origin):
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(204)
        self._cors_headers()
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Max-Age", "600")
        # Chrome's Private Network Access preflight (public site -> 127.0.0.1).
        if self.headers.get("Access-Control-Request-Private-Network", "").lower() == "true":
            self.send_header("Access-Control-Allow-Private-Network", "true")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/status":
            self.send_json(self.state.status())
        elif parsed.path == "/api/matlab/ping":
            self.send_json({"pong": True, "time": time.time()})
        elif parsed.path == "/api/matlab/input":
            self.handle_matlab_poll(parse_qs(parsed.query))
        else:
            super().do_GET()  # static dashboard files

    def do_POST(self):
        path = urlparse(self.path).path
        if path in API_POST_PATHS and not self.is_json_request():
            # Browsers send JSON only after a CORS preflight, which unknown
            # websites fail; plain-text/form posts are never accepted.
            self.send_json({"status": "error",
                            "message": "Content-Type must be application/json"}, 415)
            return
        if path in ("/api/matlab/input", "/api/matlab/simulate"):
            self.handle_input()
        elif path == "/api/matlab/result":
            self.handle_result()
        elif path == "/api/matlab/launch":
            self.handle_launch()
        else:
            self.send_json({"status": "error", "message": "API endpoint not found"}, 404)

    # -- helpers --------------------------------------------------------------
    def read_json_body(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            length = 0
        if length <= 0:
            return {}
        if length > MAX_BODY_BYTES:
            raise ValueError("request body too large")
        body = json.loads(self.rfile.read(length).decode("utf-8"))
        if not isinstance(body, dict):
            raise ValueError("JSON object expected")
        return body

    def is_json_request(self):
        ctype = self.headers.get("Content-Type", "")
        return ctype.split(";", 1)[0].strip().lower() == "application/json"

    def origin_allowed(self, origin):
        if not origin:
            return False
        origin = normalize_origin(origin)
        return ("*" in self.allowed_origins or origin in self.allowed_origins
                or bool(LOOPBACK_ORIGIN_RE.match(origin)))

    def _cors_headers(self):
        """Allow the public website / local dashboards to read API replies."""
        origin = self.headers.get("Origin")
        if self.origin_allowed(origin):
            self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Vary", "Origin")

    def send_json(self, data, code=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    # -- endpoints ------------------------------------------------------------
    def handle_input(self):
        try:
            payload = self.read_json_body()
        except (ValueError, UnicodeDecodeError) as exc:
            self.send_json({"status": "error", "message": f"invalid JSON: {exc}"}, 400)
            return
        params = payload.get("params")
        if not isinstance(params, dict) or not params:
            self.send_json({"status": "error", "message": "'params' must be a non-empty object"}, 400)
            return
        seq, connected = self.state.publish_input(payload)
        self.send_json({"status": "ok", "seq": seq, "matlab_connected": connected})

    def handle_matlab_poll(self, query):
        since = None
        if query.get("since"):
            try:
                since = int(float(query["since"][0]))
            except ValueError:
                since = None
        version = query.get("ver", [None])[0]
        session = query.get("session", [None])[0]
        is_matlab = query.get("client", [""])[0] == "matlab"
        self.send_json(self.state.matlab_poll(since, version, session, is_matlab))

    def handle_result(self):
        try:
            result = self.read_json_body()
        except (ValueError, UnicodeDecodeError) as exc:
            self.send_json({"status": "error", "message": f"invalid JSON: {exc}"}, 400)
            return
        self.state.store_result(result)
        self.send_json({"status": "ok"})

    def handle_launch(self):
        try:
            req = self.read_json_body()
        except (ValueError, UnicodeDecodeError):
            req = {}
        target = str(req.get("target", "live"))

        if target == "cst":
            if os.name == "nt" and os.path.exists(CST_EXE):
                subprocess.Popen([CST_EXE], cwd=os.path.dirname(CST_EXE))
                self.send_json({"status": "launched", "target": target,
                                "message": "CST Studio Suite launched"})
            else:
                self.send_json({"status": "error", "target": target,
                                "message": f"CST Studio Suite not found at {CST_EXE}"})
            return

        command = LAUNCH_TARGETS.get(target)
        if command is None:
            self.send_json({"status": "error", "message": f"unknown target '{target}'"}, 400)
            return

        if target == "live" and self.state.matlab_connected():
            self.send_json({"status": "already_connected", "target": target,
                            "message": "MATLAB is already live-linked - just move a slider."})
            return

        manual = f"cd('{MATLAB_DIR}'); {command}"
        exe = find_matlab(max_age=0)
        if not exe:
            self.send_json({"status": "error", "target": target, "manual_command": manual,
                            "message": "MATLAB executable not found. Set the MATLAB_EXE "
                                       "environment variable, or open MATLAB and run: " + manual})
            return
        args = [exe, "-sd", MATLAB_DIR, "-r", command]
        try:
            if os.name == "nt":
                flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
                subprocess.Popen(args, cwd=MATLAB_DIR, creationflags=flags)
            else:
                subprocess.Popen(args[:1] + ["-desktop"] + args[1:], cwd=MATLAB_DIR,
                                 start_new_session=True,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as exc:
            self.send_json({"status": "error", "target": target, "manual_command": manual,
                            "message": f"Could not start MATLAB ({exc}). Run manually: {manual}"})
            return
        self.send_json({"status": "launched", "target": target, "matlab_exe": exe,
                        "manual_command": manual,
                        "message": f"Starting MATLAB with '{command}' - the window opens in "
                                   "a few seconds and then follows the dashboard live."})


def make_server(host="0.0.0.0", port=8000, data_file=DEFAULT_DATA_FILE, allow_origins=()):
    """allow_origins: extra browser origins for the API ('*' = any website)."""
    origins = frozenset(DEFAULT_ALLOWED_ORIGINS) | {normalize_origin(o) for o in allow_origins or ()}
    handler = type("Handler", (BridgeRequestHandler,),
                   {"state": LinkState(data_file), "allowed_origins": origins})
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    server = http.server.ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True
    return server


def run():
    ap = argparse.ArgumentParser(description="Web dashboard <-> MATLAB live bridge")
    ap.add_argument("--host", default=os.environ.get("BRIDGE_HOST", "0.0.0.0"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("BRIDGE_PORT", "8000")))
    ap.add_argument("--data-file", default=os.environ.get("BRIDGE_DATA_FILE", DEFAULT_DATA_FILE),
                    help="where the latest dashboard input is mirrored as JSON")
    ap.add_argument("--allow-origin", action="append", metavar="ORIGIN",
                    default=parse_origin_list(os.environ.get("BRIDGE_ALLOW_ORIGINS", "")),
                    help="extra website allowed to use the bridge from the browser "
                         "(repeatable; '*' = any). Always allowed: "
                         f"{PUBLIC_SITE_ORIGIN} and http://localhost:<port>")
    args = ap.parse_args()

    server = make_server(args.host, args.port, args.data_file, args.allow_origin)
    exe = find_matlab()
    print("=" * 70)
    print(f"  Dashboard <-> MATLAB live bridge on http://localhost:{args.port}")
    print(f"  Open the dashboard : http://localhost:{args.port}/")
    print(f"  or the website     : {PUBLIC_SITE_URL}  (click CONNECT MATLAB)")
    print(f"  In MATLAB run      : cd('{MATLAB_DIR}'); live_verify")
    print(f"  MATLAB executable  : {exe or 'not found (set MATLAB_EXE to enable 1-click launch)'}")
    print(f"  Input mirror file  : {args.data_file}")
    print("=" * 70)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[bridge] stopped")
    finally:
        server.server_close()


if __name__ == "__main__":
    run()
