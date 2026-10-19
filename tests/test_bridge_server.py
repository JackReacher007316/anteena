"""
Tests for dashboard/bridge_server.py (the Web dashboard <-> MATLAB live link).

Run from the repository root:
    python -m unittest discover -s tests -v
"""

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

    def post(self, path, payload=None, raw=None):
        data = raw if raw is not None else json.dumps(payload or {}).encode()
        req = urllib.request.Request(self.base + path, data=data, method="POST",
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as err:
            return err.code, json.loads(err.read())

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
        self.assertEqual(again, {"seq": 1, "session": got["session"], "unchanged": True})

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

    def test_find_matlab_prefers_newest_release(self):
        paths = [r"C:\Program Files\MATLAB\R2024b\bin\matlab.exe",
                 r"C:\Program Files\MATLAB\R2026b\bin\matlab.exe",
                 r"C:\Program Files\MATLAB\R2026a\bin\matlab.exe"]
        self.assertEqual(sorted(paths, key=bridge_server._release_key)[-1], paths[1])


if __name__ == "__main__":
    unittest.main()
