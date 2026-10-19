"""
Tests for dashboard/live_link_bootstrap.py (the one-command setup behind install.ps1).

The GitHub download is replaced by a local HTTP server serving a zip of this
repository, MATLAB by a tiny fake executable. Run from the repository root:
    python -m unittest discover -s tests -v
"""

import contextlib
import http.server
import os
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zipfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import bridge_server  # noqa: E402
import live_link_bootstrap as boot  # noqa: E402

ROOT = "anteena-arena-000da5f3-anteena"


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def serve_dir(directory, port=0):
    handler = type("H", (QuietHandler,), {"__init__": lambda self, *a, **k:
                   QuietHandler.__init__(self, *a, directory=directory, **k)})
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for(cond, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.1)
    return False


class NetstatParsingTests(unittest.TestCase):
    SAMPLE = """
Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1004
  TCP    0.0.0.0:8000           0.0.0.0:0              LISTENING       4242
  TCP    127.0.0.1:8000         127.0.0.1:50311        ESTABLISHED     4242
  TCP    127.0.0.1:50311        127.0.0.1:8000         ESTABLISHED     9999
  TCP    192.168.1.5:18000      0.0.0.0:0              LISTENING       777
"""

    def test_listening_pid_is_found(self):
        self.assertEqual(boot.pids_from_netstat(self.SAMPLE, 8000), {4242})

    def test_localized_windows(self):
        german = "  TCP    127.0.0.1:8000         0.0.0.0:0              ABHÖREN         31337\n"
        self.assertEqual(boot.pids_from_netstat(german, 8000), {31337})
        self.assertEqual(boot.pids_from_netstat(german, 800), set())


class BootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        d = cls.tmp.name
        # A zip laid out like GitHub's branch archive.
        cls.zip_path = os.path.join(d, "www", "connector.zip")
        os.makedirs(os.path.dirname(cls.zip_path))
        with zipfile.ZipFile(cls.zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for sub in ("dashboard", "matlab"):
                for base, dirs, files in os.walk(os.path.join(REPO, sub)):
                    dirs[:] = [x for x in dirs if x != "__pycache__"]
                    for f in files:
                        full = os.path.join(base, f)
                        zf.write(full, ROOT + "/" + os.path.relpath(full, REPO).replace(os.sep, "/"))
        cls.www = serve_dir(os.path.dirname(cls.zip_path))
        cls.zip_url = f"http://127.0.0.1:{cls.www.server_address[1]}/connector.zip"
        # Fake matlab: answers the installer's -batch live_link_check(...) call.
        cls.userpath = os.path.join(d, "Documents", "MATLAB")
        cls.matlab = os.path.join(d, "matlab")
        with open(cls.matlab, "w", encoding="utf-8") as fh:
            fh.write(f"""#!{sys.executable}
import json, re, sys
args = sys.argv[1:]
stmt = args[args.index("-batch") + 1]
out, url = re.fullmatch(r"live_link_check\\('(.*)', '(.*)'\\)", stmt).groups()
json.dump({{"ok": True, "matlab_version": "26.2.0 (R2026b)", "userpath": {cls.userpath!r},
           "engine_ok": True, "engine_message": "MATLAB reproduces all 30 dashboard engines",
           "bridge_ok": True, "bridge_message": "MATLAB reached the bridge at " + url,
           "verify_status": "", "verify_summary": ""}}, open(out, "w"))
""")
        os.chmod(cls.matlab, os.stat(cls.matlab).st_mode | stat.S_IEXEC)

    @classmethod
    def tearDownClass(cls):
        cls.www.shutdown()
        cls.www.server_close()
        cls.tmp.cleanup()

    def setUp(self):
        self.port = free_port()
        self.dest = os.path.join(self.tmp.name, f"anteena-live-{self.port}")
        self.addCleanup(self.stop_bridge)

    def stop_bridge(self):
        st = bridge_server.running_bridge(self.port)
        if st and st.get("pid"):
            with contextlib.suppress(OSError):
                os.kill(st["pid"], 15)
            wait_for(lambda: bridge_server.running_bridge(self.port) is None)

    def run_bootstrap(self, *extra):
        env = dict(os.environ, BRIDGE_DATA_FILE=os.path.join(self.tmp.name, f"in-{self.port}.json"))
        env.pop("ANTEENA_DATA_DIR", None)
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "dashboard", "live_link_bootstrap.py"),
             "--dest", self.dest, "--port", str(self.port), "--zip-url", self.zip_url,
             "--no-browser", "--matlab-exe", self.matlab, *extra],
            capture_output=True, text=True, timeout=120, env=env)
        return proc.returncode, proc.stdout + proc.stderr

    def test_first_install_then_update(self):
        code, out = self.run_bootstrap()
        self.assertEqual(code, 0, out)
        self.assertIn("files installed", out)
        self.assertTrue(os.path.isfile(os.path.join(self.dest, "dashboard", "live_link_setup.py")))
        st = bridge_server.running_bridge(self.port)
        self.assertIsNotNone(st, out)
        self.assertEqual(os.path.realpath(st["matlab_dir"]),
                         os.path.realpath(os.path.join(self.dest, "matlab")))   # runs from the new copy
        startup = os.path.join(self.userpath, "startup.m")
        with open(startup, encoding="utf-8") as fh:
            self.assertIn(os.path.join(self.dest, "matlab"), fh.read())

        # Same command again = update: the running bridge is replaced, not doubled.
        code, out = self.run_bootstrap()
        self.assertEqual(code, 0, out)
        self.assertIn(f"stopped the bridge (pid {st['pid']})", out)
        self.assertIn("files updated", out)
        st2 = bridge_server.running_bridge(self.port)
        self.assertIsNotNone(st2, out)
        self.assertNotEqual(st2["pid"], st["pid"])
        with open(startup, encoding="utf-8") as fh:
            self.assertEqual(fh.read().count("% >>> anteena live link >>>"), 1)

    def test_old_bridge_is_replaced(self):
        old_code = (
            "import http.server, json\n"
            "class H(http.server.BaseHTTPRequestHandler):\n"
            "    def do_GET(self):\n"
            "        b = json.dumps({'status': 'connected', 'matlab_connected': True,\n"
            "                        'live_mode': 'All-Time Persistent Link'}).encode()\n"
            "        self.send_response(200); self.send_header('Content-Length', str(len(b)))\n"
            "        self.end_headers(); self.wfile.write(b)\n"
            "    def log_message(self, *a): pass\n"
            f"http.server.HTTPServer(('', {self.port}), H).serve_forever()\n")
        old = subprocess.Popen([sys.executable, "-c", old_code])
        self.addCleanup(old.kill)
        self.assertTrue(wait_for(lambda: boot.kind_of(boot.bridge_status(self.port)) == "old-bridge"))
        code, out = self.run_bootstrap()
        self.assertEqual(code, 0, out)
        self.assertIn("stopped the old bridge", out)
        self.assertIsNotNone(old.wait(timeout=10))                 # old one is gone
        self.assertIsNotNone(bridge_server.running_bridge(self.port))

    def test_foreign_program_on_the_port_is_left_alone(self):
        other = serve_dir(self.tmp.name, self.port)
        self.addCleanup(other.server_close)
        self.addCleanup(other.shutdown)
        code, out = self.run_bootstrap()
        self.assertEqual(code, 1)
        self.assertIn(f"port {self.port} is used by another program", out)
        self.assertFalse(os.path.exists(self.dest))                 # nothing installed
        with socket.create_connection(("127.0.0.1", self.port), timeout=2):
            pass                                                    # still running

    def test_download_failure_is_explained(self):
        env = dict(os.environ)
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "dashboard", "live_link_bootstrap.py"),
             "--dest", self.dest, "--port", str(self.port),
             "--zip-url", f"http://127.0.0.1:{free_port()}/missing.zip"],
            capture_output=True, text=True, timeout=60, env=env)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("ERROR:", proc.stdout)


if __name__ == "__main__":
    unittest.main()
