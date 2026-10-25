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
* POST /api/matlab/launch starts MATLAB with the live link (live_verify) -
  once: while MATLAB is starting it is not launched again, and when MATLAB is
  already linked its live window is brought back instead.

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
    python dashboard/bridge_server.py --port 8080
    python dashboard/bridge_server.py --allow-origin https://example.org

A second copy started on the same port notices the running bridge and exits.
Run it in the background with pythonw (no console): output then goes to
data/bridge.log (or --log-file). dashboard/live_link_setup.py install sets it
up to start with Windows.

Only the Python standard library is used.
"""

import argparse
import glob
import http.server
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from urllib.error import URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import urlopen

DASHBOARD_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(DASHBOARD_DIR, ".."))
MATLAB_DIR = os.path.join(PROJECT_ROOT, "matlab")
DEFAULT_DATA_FILE = os.path.join(PROJECT_ROOT, "data", "user_input.json")
DEFAULT_LOG_FILE = os.path.join(PROJECT_ROOT, "data", "bridge.log")
CST_EXE = r"C:\CST\AMD64\CST DESIGN ENVIRONMENT_AMD64.exe"

# Bumped when the API changes; the dashboard flags older bridges.
BRIDGE_API = 4
# MATLAB is reported as connected while its last poll is younger than this.
MATLAB_TIMEOUT_S = 3.0
# After a launch MATLAB needs a while before its first poll; don't launch again.
LAUNCH_GRACE_S = 120.0
# Upper bounds for request bodies. ML image uploads are handled only by the local bridge.
MAX_BODY_BYTES = 1_000_000
MAX_AI_IMAGE_BYTES = 12 * 1024 * 1024
AI_TRAINING_DIR = os.path.join(PROJECT_ROOT, "data", "antenna_images")
_AI_TRAIN_LOCK = threading.Lock()
_AI_TRAIN_STATE = {"status": "idle", "message": "No training job started.", "output": ""}

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
        try:
            print(f"[bridge] warning: could not write {path}: {exc}")
        except (OSError, ValueError):
            pass
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
        self.launch_at = None   # last time MATLAB was launched by the bridge
        self.show_seq = 0       # bumped to ask a running live_verify to show its window
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
        for key in ("param_meta", "freq_range", "dashboard", "client_time", "review"):
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
                return {"seq": 0, "session": self.session, "status": "empty",
                        "show_seq": self.show_seq}
            same_session = session is None or session == self.session
            if since is not None and since == self.seq and same_session:
                return {"seq": self.seq, "session": self.session, "unchanged": True,
                        "show_seq": self.show_seq}
            reply = dict(self.latest)
            reply["show_seq"] = self.show_seq
            return reply

    def store_result(self, result):
        with self.lock:
            self.matlab_last_poll = time.time()
            if isinstance(result.get("matlab_version"), str):
                self.matlab_version = result["matlab_version"]
            result["received_at"] = time.time()
            self.matlab_result = result
            self.matlab_result_at = result["received_at"]

    # -- launching / showing MATLAB -------------------------------------------
    def note_launch(self):
        with self.lock:
            self.launch_at = time.time()

    def request_show(self):
        """Ask the running live_verify to bring its window back (next poll)."""
        with self.lock:
            self.show_seq += 1
            return self.show_seq

    def _matlab_starting_locked(self):
        """Launched recently and MATLAB has not polled since."""
        if self.launch_at is None or time.time() - self.launch_at > LAUNCH_GRACE_S:
            return False
        return self.matlab_last_poll is None or self.matlab_last_poll < self.launch_at

    def matlab_starting(self):
        with self.lock:
            return self._matlab_starting_locked()

    def launch_age(self):
        with self.lock:
            return None if self.launch_at is None else time.time() - self.launch_at

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
                "api": BRIDGE_API,
                "pid": os.getpid(),
                "session": self.session,
                "matlab_connected": self._matlab_connected_locked(),
                "matlab_starting": self._matlab_starting_locked(),
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
        try:
            super().log_message(fmt, *args)
        except (OSError, ValueError, AttributeError):
            pass   # console gone (closed pipe / window): never fail a request over a log line

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
        elif parsed.path == "/api/ai/status":
            self.handle_ai_status()
        else:
            super().do_GET()  # static dashboard files

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/api/ai/classify":
            self.handle_ai_classify()
            return
        if path == "/api/ai/training-image":
            self.handle_ai_training_image(parse_qs(parsed.query))
            return
        if path == "/api/ai/train":
            if not self.is_json_request():
                self.send_json({"status": "error", "message": "Content-Type must be application/json"}, 415)
                return
            self.handle_ai_train()
            return
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

    # -- local trained image AI ------------------------------------------------
    def image_classifier(self):
        module_dir = os.path.join(PROJECT_ROOT, "python")
        if module_dir not in sys.path:
            sys.path.insert(0, module_dir)
        import antenna_image_classifier
        return antenna_image_classifier

    def read_image_body(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc
        if length <= 0:
            raise ValueError("empty image upload")
        if length > MAX_AI_IMAGE_BYTES:
            raise ValueError("image exceeds the 12 MB limit")
        body = self.rfile.read(length)
        if len(body) != length:
            raise ValueError("incomplete image upload")
        return body

    def handle_ai_status(self):
        try:
            status = self.image_classifier().model_status()
            with _AI_TRAIN_LOCK:
                status["training"] = dict(_AI_TRAIN_STATE)
            self.send_json(status)
        except Exception as exc:
            self.send_json({"ready": False, "message": f"Image AI service unavailable: {exc}"}, 503)

    def handle_ai_train(self):
        global _AI_TRAIN_STATE
        with _AI_TRAIN_LOCK:
            if _AI_TRAIN_STATE.get("status") == "running":
                self.send_json({"status": "running", "message": "Training is already in progress."}, 202)
                return
            _AI_TRAIN_STATE = {"status": "running", "message": "Training the antenna image model on labeled local examples.", "output": ""}
        threading.Thread(target=self._run_ai_training, daemon=True, name="AntennaImageTraining").start()
        self.send_json({"status": "running", "message": "Training started on this PC. Keep the bridge running."}, 202)

    @staticmethod
    def _run_ai_training():
        global _AI_TRAIN_STATE
        script = os.path.join(PROJECT_ROOT, "python", "train_antenna_image_classifier.py")
        command = [sys.executable, script, "--dataset", AI_TRAINING_DIR]
        try:
            result = subprocess.run(command, cwd=PROJECT_ROOT, capture_output=True,
                                   text=True, timeout=900, check=False)
            output = (result.stdout + "\n" + result.stderr)[-12000:]
            state = "ready" if result.returncode == 0 else "error"
            message = "Training complete. The trained model is ready on this PC." if result.returncode == 0 else "Training failed. See the training output for details."
        except subprocess.TimeoutExpired as exc:
            output = ((exc.stdout or "") + "\nTraining exceeded the 15-minute limit.")[-12000:]
            state, message = "error", "Training timed out. Reduce dataset size or train from the command line."
        except OSError as exc:
            output = str(exc)
            state, message = "error", "Could not start the local training process."
        with _AI_TRAIN_LOCK:
            _AI_TRAIN_STATE = {"status": state, "message": message, "output": output}

    def handle_ai_classify(self):
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if not (content_type.startswith("image/") or content_type == "application/octet-stream"):
            self.send_json({"status": "error", "message": "Upload an image using its image MIME type."}, 415)
            return
        try:
            result = self.image_classifier().classify_image(self.read_image_body())
            self.send_json(result)
        except ValueError as exc:
            self.send_json({"status": "error", "message": str(exc)}, 400)
        except RuntimeError as exc:
            self.send_json({"status": "not_trained", "ready": False, "message": str(exc)}, 503)
        except Exception as exc:
            self.send_json({"status": "error", "message": f"Image classifier failed: {exc}"}, 500)

    def handle_ai_training_image(self, query):
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if not (content_type.startswith("image/") or content_type == "application/octet-stream"):
            self.send_json({"status": "error", "message": "Training example must be an image."}, 415)
            return
        labels = query.get("label", [])
        label = labels[0] if labels else ""
        try:
            result = self.image_classifier().save_labeled_image(self.read_image_body(), label)
            self.send_json(result)
        except ValueError as exc:
            self.send_json({"status": "error", "message": str(exc)}, 400)
        except RuntimeError as exc:
            self.send_json({"status": "unavailable", "message": str(exc)}, 503)
        except Exception as exc:
            self.send_json({"status": "error", "message": f"Could not save training image: {exc}"}, 500)

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
            self.state.request_show()   # live_verify re-opens / raises its window
            self.send_json({"status": "already_connected", "target": target,
                            "message": "MATLAB is already live-linked - its window was "
                                       "brought to the front. Just move a slider."})
            return
        if target == "live" and self.state.matlab_starting():
            age = self.state.launch_age() or 0.0
            self.send_json({"status": "starting", "target": target,
                            "message": f"MATLAB is already starting (launched {age:.0f} s ago) - "
                                       "its live window opens in a moment."})
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
        if target == "live":
            self.state.note_launch()
        self.send_json({"status": "launched", "target": target, "matlab_exe": exe,
                        "manual_command": manual,
                        "message": f"Starting MATLAB with '{command}' - the window opens in "
                                   "a few seconds and then follows the dashboard live."})


class BridgeHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True   # POSIX: quick restarts (TIME_WAIT)

    def server_bind(self):
        if os.name == "nt":
            # On Windows SO_REUSEADDR lets a second bridge bind the same port
            # and silently split the traffic - claim the port exclusively.
            self.allow_reuse_address = False
            if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
                self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


def make_server(host="127.0.0.1", port=8000, data_file=DEFAULT_DATA_FILE, allow_origins=()):
    """allow_origins: extra browser origins for the API ('*' = any website)."""
    origins = frozenset(DEFAULT_ALLOWED_ORIGINS) | {normalize_origin(o) for o in allow_origins or ()}
    handler = type("Handler", (BridgeRequestHandler,),
                   {"state": LinkState(data_file), "allowed_origins": origins})
    return BridgeHTTPServer((host, port), handler)


def running_bridge(port, timeout=1.5):
    """Status of a live-link bridge already answering on this port, else None."""
    try:
        with urlopen(f"http://127.0.0.1:{port}/api/status", timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except (OSError, URLError, ValueError):
        return None
    return data if isinstance(data, dict) and "session" in data else None


def old_bridge_running(port, timeout=1.5):
    """True when the pre-live-link bridge (always claims matlab_connected) answers."""
    try:
        with urlopen(f"http://127.0.0.1:{port}/api/status", timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except (OSError, URLError, ValueError):
        return False
    return isinstance(data, dict) and "matlab_connected" in data and "session" not in data


def setup_logging(log_file=None, max_bytes=1_000_000):
    """Send output to a log file when asked to, or when there is no console
    (pythonw / started at Windows log-in) - otherwise http.server would crash
    writing its request log to a missing sys.stderr."""
    if not log_file and sys.stdout is not None and sys.stderr is not None:
        return None
    log_file = log_file or DEFAULT_LOG_FILE
    try:
        os.makedirs(os.path.dirname(log_file) or ".", exist_ok=True)
        if os.path.exists(log_file) and os.path.getsize(log_file) > max_bytes:
            os.replace(log_file, log_file + ".1")
        stream = open(log_file, "a", encoding="utf-8", buffering=1)
    except OSError:
        stream = open(os.devnull, "w", encoding="utf-8")
    sys.stdout = stream
    sys.stderr = stream
    return log_file


def run():
    ap = argparse.ArgumentParser(description="Web dashboard <-> MATLAB live bridge")
    ap.add_argument("--host", default=os.environ.get("BRIDGE_HOST", "127.0.0.1"),
                    help="interface to listen on (default 127.0.0.1 = this PC only)")
    ap.add_argument("--port", type=int, default=int(os.environ.get("BRIDGE_PORT", "8000")))
    ap.add_argument("--data-file", default=os.environ.get("BRIDGE_DATA_FILE", DEFAULT_DATA_FILE),
                    help="where the latest dashboard input is mirrored as JSON")
    ap.add_argument("--allow-origin", action="append", metavar="ORIGIN",
                    default=parse_origin_list(os.environ.get("BRIDGE_ALLOW_ORIGINS", "")),
                    help="extra website allowed to use the bridge from the browser "
                         "(repeatable; '*' = any). Always allowed: "
                         f"{PUBLIC_SITE_ORIGIN} and http://localhost:<port>")
    ap.add_argument("--log-file", default=os.environ.get("BRIDGE_LOG_FILE"),
                    help="write output to this file (automatic when there is no console)")
    ap.add_argument("--force", action="store_true",
                    help="start even if a bridge already answers on this port")
    args = ap.parse_args()
    setup_logging(args.log_file)

    existing = None if args.force else running_bridge(args.port)
    if existing:
        print(f"[bridge] A bridge is already running on port {args.port} "
              f"(pid {existing.get('pid', '?')}) - nothing to do.")
        print(f"[bridge] Dashboard: http://localhost:{args.port}/   Website: {PUBLIC_SITE_URL}")
        return 0
    try:
        server = make_server(args.host, args.port, args.data_file, args.allow_origin)
    except OSError as exc:
        print(f"[bridge] Cannot listen on {args.host}:{args.port} ({exc}).")
        if old_bridge_running(args.port):
            print("[bridge] An OLD version of this bridge is running on that port. Close its "
                  "console window (or restart the PC) and start the bridge again.")
        else:
            print(f"[bridge] Another program uses port {args.port}. Start the bridge on another "
                  f"port (--port 8001) and open the website with ?bridge=8001")
        return 1
    exe = find_matlab()
    print("=" * 70)
    print(f"  Dashboard <-> MATLAB live bridge on http://localhost:{args.port}")
    print(f"  Open the dashboard : http://localhost:{args.port}/")
    print(f"  or the website     : {PUBLIC_SITE_URL}  (click CONNECT MATLAB)")
    print(f"  In MATLAB run      : cd('{MATLAB_DIR}'); live_verify")
    print(f"  MATLAB executable  : {exe or 'not found (set MATLAB_EXE to enable 1-click launch)'}")
    print(f"  Input mirror file  : {args.data_file}")
    print("=" * 70)
    print(f"[bridge] started {time.strftime('%Y-%m-%d %H:%M:%S')} pid {os.getpid()} "
          f"on {args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[bridge] stopped")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(run())
