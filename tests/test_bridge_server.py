"""
Tests for dashboard/bridge_server.py (the Web dashboard <-> MATLAB live link).

Run from the repository root:
    python -m unittest discover -s tests -v
"""

import contextlib
import http.server
import io
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "dashboard"))
import bridge_server  # noqa: E402

PATCH_INPUT = {
    "antenna": "patch",
    "antenna_name": "Rectangular Microstrip Patch Antenna",
    "model": "gpr",
    "params": {"length": 29.4, "width": 38.0, "height": 1.6, "permittivity": 4.4},
    "freq_range": [1.5, 4.0],
    "dashboard": {"physics": {"S11": -24.43, "Fr": 2.401},
                  "prediction": {"S11": -24.3, "Fr": 2.402}},
}


class BridgeTestCase(unittest.TestCase):
    def start_server(self, data_file):
        server = bridge_server.make_server("127.0.0.1", 0, data_file)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server, f"http://127.0.0.1:{server.server_address[1]}"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.data_file = os.path.join(self.tmp.name, "user_input.json")
        self.server, self.base = self.start_server(self.data_file)
        self.state = self.server.RequestHandlerClass.state

    # -- tiny HTTP helpers ---------------------------------------------------
    def get(self, path):
        with urllib.request.urlopen(self.base + path, timeout=5) as resp:
            return resp.status, json.loads(resp.read())

    def post(self, path, payload=None, raw=None, content_type="application/json"):
        data = raw if raw is not None else json.dumps(payload or {}).encode()
        req = urllib.request.Request(self.base + path, data=data, method="POST",
                                     headers={"Content-Type": content_type})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as err:
            return err.code, json.loads(err.read())

    def request(self, method, path, headers=None, base=None):
        """Raw request -> (status, headers); used for the CORS checks."""
        req = urllib.request.Request((base or self.base) + path, method=method,
                                     headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                resp.read()
                return resp.status, resp.headers
        except urllib.error.HTTPError as err:
            err.read()
            return err.code, err.headers

    # -- tests -----------------------------------------------------------------
    def test_status_before_matlab_connects(self):
        code, st = self.get("/api/status")
        self.assertEqual(code, 200)
        self.assertFalse(st["matlab_connected"])
        self.assertIsNone(st["matlab_last_seen_s"])
        self.assertEqual(st["input_seq"], 0)
        self.assertTrue(st["matlab_dir"].endswith("matlab"))

    def test_input_reaches_matlab_poll_and_file(self):
        code, res = self.post("/api/matlab/input", PATCH_INPUT)
        self.assertEqual(code, 200)
        self.assertEqual(res["seq"], 1)
        self.assertFalse(res["matlab_connected"])

        # MATLAB's first poll receives the full input ...
        code, got = self.get("/api/matlab/input?since=-1&client=matlab&ver=26.2")
        self.assertEqual(got["seq"], 1)
        self.assertEqual(got["antenna"], "patch")
        self.assertEqual(got["params"], PATCH_INPUT["params"])
        self.assertEqual(got["dashboard"], PATCH_INPUT["dashboard"])
        self.assertEqual(got["freq_range"], [1.5, 4.0])
        # ... and later polls are cheap "unchanged" replies.
        _, again = self.get("/api/matlab/input?since=1&client=matlab")
        self.assertEqual(again, {"seq": 1, "session": got["session"], "unchanged": True,
                                 "show_seq": 0})

        # Polling marks MATLAB as connected (this is the heartbeat).
        _, st = self.get("/api/status")
        self.assertTrue(st["matlab_connected"])
        self.assertEqual(st["matlab_version"], "26.2")
        self.assertLess(st["matlab_last_seen_s"], 2)

        # The input is mirrored to the JSON file for MATLAB's file fallback.
        with open(self.data_file, encoding="utf-8") as fh:
            mirrored = json.load(fh)
        self.assertEqual(mirrored["seq"], 1)
        self.assertEqual(mirrored["params"], PATCH_INPUT["params"])

    def test_local_image_ai_status_explains_missing_trained_model(self):
        code, status = self.get("/api/ai/status")
        self.assertEqual(code, 200)
        self.assertFalse(status["ready"])
        self.assertIn("train_antenna_image_classifier.py", status["training_command"])
        self.assertIn("class_counts", status)

    def test_local_image_classifier_requires_a_trained_model(self):
        code, result = self.post("/api/ai/classify", raw=b"not-a-real-image", content_type="image/png")
        self.assertEqual(code, 503)
        self.assertEqual(result["status"], "not_trained")

    def test_ai_training_image_rejects_non_image_content(self):
        code, result = self.post("/api/ai/training-image?label=patch", raw=b"text", content_type="text/plain")
        self.assertEqual(code, 415)
        self.assertEqual(result["status"], "error")

    def test_custom_antenna_review_metadata_reaches_matlab(self):
        payload = {
            "antenna": "custom", "antenna_name": "User-defined antenna",
            "model": "review", "params": {"review_received": 1},
            "review": {
                "description": "Custom helical array at 3.5 GHz",
                "measurements": {"frequency_GHz": 3.5, "s11_dB": -18.2},
                "trace_f_GHz": [3.4, 3.5, 3.6],
                "trace_s11_dB": [-4.0, -18.2, -5.0],
            },
        }
        code, ack = self.post("/api/matlab/input", payload)
        self.assertEqual((code, ack["status"]), (200, "ok"))
        _, received = self.get("/api/matlab/input?since=-1")
        self.assertEqual(received["antenna"], "custom")
        self.assertEqual(received["review"], payload["review"])
        with open(self.data_file, encoding="utf-8") as fh:
            mirrored = json.load(fh)
        self.assertEqual(mirrored["review"], payload["review"])

    def test_unchanged_only_within_same_session(self):
        self.post("/api/matlab/input", PATCH_INPUT)
        _, got = self.get("/api/matlab/input?since=-1&client=matlab")
        sess = got["session"]
        _, same = self.get(f"/api/matlab/input?since=1&session={sess}&client=matlab")
        self.assertTrue(same.get("unchanged"))
        # A different session (e.g. the bridge restarted) always gets the full input.
        _, other = self.get("/api/matlab/input?since=1&session=none&client=matlab")
        self.assertNotIn("unchanged", other)
        self.assertEqual(other["params"], PATCH_INPUT["params"])

    def test_only_matlab_polls_count_as_heartbeat(self):
        self.post("/api/matlab/input", PATCH_INPUT)
        _, got = self.get("/api/matlab/input")          # e.g. a browser tab
        self.assertEqual(got["seq"], 1)
        _, st = self.get("/api/status")
        self.assertFalse(st["matlab_connected"])

    def test_matlab_connection_times_out(self):
        self.get("/api/matlab/input?client=matlab")
        self.state.matlab_last_poll -= bridge_server.MATLAB_TIMEOUT_S + 1
        _, st = self.get("/api/status")
        self.assertFalse(st["matlab_connected"])

    def test_bad_requests_are_rejected(self):
        code, res = self.post("/api/matlab/input", raw=b"{not json")
        self.assertEqual(code, 400)
        self.assertEqual(res["status"], "error")
        code, _ = self.post("/api/matlab/input", {"antenna": "patch"})
        self.assertEqual(code, 400)
        code, _ = self.post("/api/matlab/nope", {})
        self.assertEqual(code, 404)

    def test_legacy_simulate_alias(self):
        code, res = self.post("/api/matlab/simulate", PATCH_INPUT)
        self.assertEqual((code, res["status"], res["seq"]), (200, "ok", 1))

    def test_matlab_result_is_reported_in_status(self):
        self.post("/api/matlab/input", PATCH_INPUT)
        result = {"seq": 1, "status": "PASS", "n_pass": 9, "n_checks": 9,
                  "matlab_version": "26.2.0 (R2026b)"}
        code, res = self.post("/api/matlab/result", result)
        self.assertEqual((code, res["status"]), (200, "ok"))
        _, st = self.get("/api/status")
        self.assertEqual(st["matlab_seq"], 1)
        self.assertEqual(st["matlab_result"]["status"], "PASS")
        self.assertEqual(st["matlab_version"], "26.2.0 (R2026b)")
        self.assertTrue(st["matlab_connected"])

    def test_restart_continues_sequence_from_file(self):
        self.post("/api/matlab/input", PATCH_INPUT)
        self.post("/api/matlab/input", PATCH_INPUT)
        _, base2 = self.start_server(self.data_file)
        with urllib.request.urlopen(base2 + "/api/matlab/input", timeout=5) as r:
            got = json.loads(r.read())
        self.assertEqual(got["seq"], 3)
        self.assertEqual(got["params"], PATCH_INPUT["params"])

    def test_parallel_inputs_keep_newest_in_file(self):
        def send(i):
            payload = dict(PATCH_INPUT, params=dict(PATCH_INPUT["params"], length=20 + i))
            return self.post("/api/matlab/input", payload)[1]["seq"]

        with ThreadPoolExecutor(max_workers=8) as pool:
            seqs = list(pool.map(send, range(24)))
        self.assertEqual(sorted(seqs), list(range(1, 25)))
        with open(self.data_file, encoding="utf-8") as fh:
            self.assertEqual(json.load(fh)["seq"], 24)

    def test_launch_without_matlab_explains_manual_step(self):
        original = bridge_server.find_matlab
        bridge_server.find_matlab = lambda max_age=30.0: None
        self.addCleanup(setattr, bridge_server, "find_matlab", original)
        code, res = self.post("/api/matlab/launch", {"target": "live"})
        self.assertEqual(code, 200)
        self.assertEqual(res["status"], "error")
        self.assertIn("live_verify", res["manual_command"])

    def test_launch_is_skipped_when_matlab_already_linked(self):
        self.get("/api/matlab/input?client=matlab")
        code, res = self.post("/api/matlab/launch", {"target": "live"})
        self.assertEqual((code, res["status"]), (200, "already_connected"))

    def test_unknown_launch_target(self):
        code, res = self.post("/api/matlab/launch", {"target": "rm -rf"})
        self.assertEqual((code, res["status"]), (400, "error"))

    def test_dashboard_is_served(self):
        with urllib.request.urlopen(self.base + "/", timeout=5) as resp:
            html = resp.read().decode("utf-8")
        self.assertIn("app.js", html)

    # -- public website (GitHub Pages) -> bridge on this PC: CORS ----------------
    def test_cors_allows_public_site_and_local_dashboards(self):
        for origin in (bridge_server.PUBLIC_SITE_ORIGIN, "http://localhost:5500",
                       "http://127.0.0.1:3000", "http://[::1]:8080"):
            code, hdrs = self.request("GET", "/api/status", {"Origin": origin})
            self.assertEqual(code, 200)
            self.assertEqual(hdrs.get("Access-Control-Allow-Origin"), origin, origin)

    def test_cors_other_websites_get_no_access(self):
        for origin in ("https://evil.example", "null", "http://localhost.evil.example",
                       bridge_server.PUBLIC_SITE_ORIGIN + ".evil.example",
                       "http://jackreacher007316.github.io"):
            _, hdrs = self.request("GET", "/api/status", {"Origin": origin})
            self.assertIsNone(hdrs.get("Access-Control-Allow-Origin"), origin)

    def test_preflight_from_public_site(self):
        code, hdrs = self.request("OPTIONS", "/api/matlab/launch", {
            "Origin": bridge_server.PUBLIC_SITE_ORIGIN,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
            "Access-Control-Request-Private-Network": "true",
        })
        self.assertEqual(code, 204)
        self.assertEqual(hdrs.get("Access-Control-Allow-Origin"), bridge_server.PUBLIC_SITE_ORIGIN)
        self.assertIn("POST", hdrs.get("Access-Control-Allow-Methods", ""))
        self.assertIn("content-type", hdrs.get("Access-Control-Allow-Headers", "").lower())
        self.assertEqual(hdrs.get("Access-Control-Allow-Private-Network"), "true")

    def test_preflight_from_unknown_site_is_refused(self):
        code, hdrs = self.request("OPTIONS", "/api/matlab/launch", {
            "Origin": "https://evil.example", "Access-Control-Request-Method": "POST"})
        self.assertEqual(code, 403)
        self.assertIsNone(hdrs.get("Access-Control-Allow-Origin"))

    def test_posts_must_be_json(self):
        calls = []
        original = bridge_server.find_matlab
        bridge_server.find_matlab = lambda max_age=30.0: calls.append(1)
        self.addCleanup(setattr, bridge_server, "find_matlab", original)
        body = json.dumps({"target": "live"}).encode()
        # What a hidden form / no-cors request from another website can send:
        for ctype in ("text/plain;charset=UTF-8", "application/x-www-form-urlencoded",
                      "multipart/form-data; boundary=x"):
            code, res = self.post("/api/matlab/launch", raw=body, content_type=ctype)
            self.assertEqual((code, res["status"]), (415, "error"), ctype)
            code, _ = self.post("/api/matlab/input", raw=json.dumps(PATCH_INPUT).encode(),
                                content_type=ctype)
            self.assertEqual(code, 415, ctype)
        self.assertEqual(calls, [])                      # MATLAB was never looked up
        self.assertEqual(self.state.seq, 0)              # no input was accepted
        # MATLAB's webwrite / the dashboard: JSON, optionally with a charset.
        code, res = self.post("/api/matlab/input", PATCH_INPUT,
                              content_type="application/json; charset=UTF-8")
        self.assertEqual((code, res["seq"]), (200, 1))

    def test_extra_allowed_origins(self):
        _, base2 = self.start_server(os.path.join(self.tmp.name, "b.json"))
        _, hdrs = self.request("GET", "/api/status", {"Origin": "https://example.org"}, base=base2)
        self.assertIsNone(hdrs.get("Access-Control-Allow-Origin"))

        server3 = bridge_server.make_server("127.0.0.1", 0, os.path.join(self.tmp.name, "c.json"),
                                            allow_origins=["https://Example.org/"])
        threading.Thread(target=server3.serve_forever, daemon=True).start()
        self.addCleanup(server3.server_close)
        self.addCleanup(server3.shutdown)
        base3 = f"http://127.0.0.1:{server3.server_address[1]}"
        _, hdrs = self.request("GET", "/api/status", {"Origin": "https://example.org"}, base=base3)
        self.assertEqual(hdrs.get("Access-Control-Allow-Origin"), "https://example.org")

        server4 = bridge_server.make_server("127.0.0.1", 0, os.path.join(self.tmp.name, "d.json"),
                                            allow_origins=["*"])
        threading.Thread(target=server4.serve_forever, daemon=True).start()
        self.addCleanup(server4.server_close)
        self.addCleanup(server4.shutdown)
        base4 = f"http://127.0.0.1:{server4.server_address[1]}"
        _, hdrs = self.request("GET", "/api/status", {"Origin": "https://any.example"}, base=base4)
        self.assertEqual(hdrs.get("Access-Control-Allow-Origin"), "https://any.example")

    def test_parse_origin_list(self):
        self.assertEqual(bridge_server.parse_origin_list(" https://A.org/, http://b.net  * "),
                         ["https://a.org", "http://b.net", "*"])
        self.assertEqual(bridge_server.parse_origin_list(""), [])

    # -- launching MATLAB: once, and "show" when it is already linked ----------
    def fake_launcher(self):
        """find_matlab -> a fake exe, Popen -> recorded instead of run."""
        calls = []
        orig_find, orig_popen = bridge_server.find_matlab, bridge_server.subprocess.Popen
        bridge_server.find_matlab = lambda max_age=30.0: "/opt/MATLAB/R2026b/bin/matlab"
        bridge_server.subprocess.Popen = lambda args, **kw: calls.append(args)
        self.addCleanup(setattr, bridge_server, "find_matlab", orig_find)
        self.addCleanup(setattr, bridge_server.subprocess, "Popen", orig_popen)
        return calls

    def test_status_reports_api_pid_and_starting(self):
        _, st = self.get("/api/status")
        self.assertEqual(st["api"], bridge_server.BRIDGE_API)
        self.assertEqual(st["pid"], os.getpid())
        self.assertFalse(st["matlab_starting"])

    def test_launch_starts_matlab_only_once(self):
        calls = self.fake_launcher()
        code, res = self.post("/api/matlab/launch", {"target": "live"})
        self.assertEqual((code, res["status"]), (200, "launched"))
        self.assertEqual(len(calls), 1)
        self.assertIn("live_verify", calls[0])
        _, st = self.get("/api/status")
        self.assertTrue(st["matlab_starting"])
        self.assertFalse(st["matlab_connected"])
        # A second click (or a second tab) while MATLAB is still starting: no 2nd MATLAB.
        code, res = self.post("/api/matlab/launch", {"target": "live"})
        self.assertEqual((code, res["status"]), (200, "starting"))
        self.assertEqual(len(calls), 1)
        # MATLAB's first poll ends "starting".
        self.get("/api/matlab/input?client=matlab")
        _, st = self.get("/api/status")
        self.assertFalse(st["matlab_starting"])
        self.assertTrue(st["matlab_connected"])

    def test_launch_grace_period_expires(self):
        calls = self.fake_launcher()
        self.post("/api/matlab/launch", {"target": "live"})
        self.state.launch_at -= bridge_server.LAUNCH_GRACE_S + 1   # MATLAB never came up
        _, st = self.get("/api/status")
        self.assertFalse(st["matlab_starting"])
        code, res = self.post("/api/matlab/launch", {"target": "live"})
        self.assertEqual((code, res["status"]), (200, "launched"))
        self.assertEqual(len(calls), 2)

    def test_connect_while_linked_asks_matlab_to_show_its_window(self):
        calls = self.fake_launcher()
        self.post("/api/matlab/input", PATCH_INPUT)
        _, first = self.get("/api/matlab/input?since=-1&client=matlab")
        self.assertEqual(first["show_seq"], 0)
        code, res = self.post("/api/matlab/launch", {"target": "live"})
        self.assertEqual((code, res["status"]), (200, "already_connected"))
        self.assertEqual(calls, [])                      # nothing launched
        _, again = self.get(f"/api/matlab/input?since=1&session={first['session']}&client=matlab")
        self.assertTrue(again["unchanged"])
        self.assertEqual(again["show_seq"], 1)           # live_verify re-opens its window

    def test_running_bridge_detection(self):
        port = self.server.server_address[1]
        st = bridge_server.running_bridge(port)
        self.assertEqual(st["session"], self.state.session)
        self.assertFalse(bridge_server.old_bridge_running(port))
        self.assertIsNone(bridge_server.running_bridge(free_port()))

    def test_old_bridge_is_recognised(self):
        class OldBridge(http.server.BaseHTTPRequestHandler):   # pre-live-link bridge
            def do_GET(self):
                body = json.dumps({"status": "connected", "matlab_connected": True}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        old = http.server.ThreadingHTTPServer(("127.0.0.1", 0), OldBridge)
        threading.Thread(target=old.serve_forever, daemon=True).start()
        self.addCleanup(old.server_close)
        self.addCleanup(old.shutdown)
        port = old.server_address[1]
        self.assertTrue(bridge_server.old_bridge_running(port))
        self.assertIsNone(bridge_server.running_bridge(port))

    def test_second_copy_exits_when_a_bridge_runs(self):
        port = self.server.server_address[1]
        argv = sys.argv
        sys.argv = ["bridge_server.py", "--port", str(port)]
        self.addCleanup(setattr, sys, "argv", argv)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = bridge_server.run()
        self.assertEqual(code, 0)
        self.assertIn("already running", out.getvalue())

    def test_logging_without_console(self):
        log = os.path.join(self.tmp.name, "bridge.log")
        saved = sys.stdout, sys.stderr, bridge_server.DEFAULT_LOG_FILE
        bridge_server.DEFAULT_LOG_FILE = log

        def restore():
            for stream in (sys.stdout, sys.stderr):
                if stream not in saved:
                    stream.close()
            sys.stdout, sys.stderr, bridge_server.DEFAULT_LOG_FILE = saved

        self.addCleanup(restore)
        self.assertIsNone(bridge_server.setup_logging())     # console present: untouched
        sys.stdout = sys.stderr = None                       # pythonw / Windows log-in
        self.assertEqual(bridge_server.setup_logging(), log)
        sys.stderr.write("request log line\n")
        with open(log, encoding="utf-8") as fh:
            self.assertIn("request log line", fh.read())

    def test_requests_survive_a_dead_console(self):
        class DeadPipe(io.StringIO):
            def write(self, s):
                raise BrokenPipeError(32, "Broken pipe")

        saved = sys.stderr
        sys.stderr = DeadPipe()            # e.g. the console window/pipe went away
        self.addCleanup(setattr, sys, "stderr", saved)
        original = bridge_server.find_matlab
        bridge_server.find_matlab = lambda max_age=30.0: None
        self.addCleanup(setattr, bridge_server, "find_matlab", original)
        code, res = self.post("/api/matlab/launch", {"target": "live"})   # a logged request
        self.assertEqual((code, res["status"]), (200, "error"))
        with urllib.request.urlopen(self.base + "/", timeout=5) as resp:  # logged static file
            self.assertEqual(resp.status, 200)

    def test_find_matlab_prefers_newest_release(self):
        paths = [r"C:\Program Files\MATLAB\R2024b\bin\matlab.exe",
                 r"C:\Program Files\MATLAB\R2026b\bin\matlab.exe",
                 r"C:\Program Files\MATLAB\R2026a\bin\matlab.exe"]
        self.assertEqual(sorted(paths, key=bridge_server._release_key)[-1], paths[1])


def free_port():
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


if __name__ == "__main__":
    unittest.main()
