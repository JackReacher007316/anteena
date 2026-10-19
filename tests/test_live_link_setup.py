"""
Tests for dashboard/live_link_setup.py (one-time setup that keeps the live link running).

Windows-only parts (registry) run against an in-memory fake winreg; MATLAB is
replaced by a tiny fake executable. Run from the repository root:
    python -m unittest discover -s tests -v
"""

import contextlib
import io
import json
import os
import socket
import stat
import sys
import tempfile
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "dashboard"))
import bridge_server  # noqa: E402
import live_link_setup as setup  # noqa: E402

MATLAB_DIR = r"C:\Users\O'Neil\anteena\matlab"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class FakeWinreg(types.ModuleType):
    """Just enough of winreg for the setup script (values live in a dict)."""
    HKEY_CURRENT_USER = "HKCU"
    KEY_SET_VALUE = 2
    REG_SZ = 1

    def __init__(self):
        super().__init__("winreg")
        self.values = {}

    class _Key:
        def __init__(self, reg, path):
            self.reg, self.path = reg, path

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def OpenKey(self, root, path, reserved=0, access=0):  # noqa: N802 (winreg API)
        if not any(k[0] == path for k in self.values) and path != setup.RUN_KEY:
            raise FileNotFoundError(path)
        return self._Key(self, path)

    def CreateKeyEx(self, root, path, reserved=0, access=0):  # noqa: N802
        return self._Key(self, path)

    def QueryValueEx(self, key, name):  # noqa: N802
        try:
            return self.values[(key.path, name)], self.REG_SZ
        except KeyError:
            raise FileNotFoundError(name) from None

    def SetValueEx(self, key, name, reserved, kind, value):  # noqa: N802
        self.values[(key.path, name)] = value

    def DeleteValue(self, key, name):  # noqa: N802
        if (key.path, name) not in self.values:
            raise FileNotFoundError(name)
        del self.values[(key.path, name)]

    @staticmethod
    def ExpandEnvironmentStrings(value):  # noqa: N802
        return value.replace("%USERPROFILE%", r"C:\Users\aaryan")


class HookTextTests(unittest.TestCase):
    def test_new_file_gets_one_guarded_block(self):
        text = setup.with_hook("", MATLAB_DIR)
        self.assertTrue(text.startswith(setup.HOOK_BEGIN))
        self.assertIn("addpath('C:\\Users\\O''Neil\\anteena\\matlab');", text)  # quote doubled
        self.assertIn("if ~batchStartupOptionUsed", text)
        self.assertIn("live_verify;", text)
        self.assertTrue(text.rstrip().endswith(setup.HOOK_END))

    def test_existing_content_is_kept_and_block_is_not_duplicated(self):
        user = "format long\naddpath('C:\\tools')"           # no trailing newline
        once = setup.with_hook(user, MATLAB_DIR)
        twice = setup.with_hook(once, MATLAB_DIR + "2")
        self.assertTrue(once.startswith(user + "\n" + setup.HOOK_BEGIN))
        self.assertEqual(twice.count(setup.HOOK_BEGIN), 1)
        self.assertIn("matlab2'", twice)                        # refreshed, not duplicated
        self.assertEqual(setup.strip_hook(twice), user + "\n")

    def test_crlf_files_stay_crlf(self):
        user = "format long\r\ndisp('hi')\r\n"
        text = setup.with_hook(user, MATLAB_DIR)
        self.assertNotIn("\n", text.replace("\r\n", ""))         # no bare LF added
        self.assertEqual(setup.strip_hook(text), user)


class HookFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.startup = os.path.join(self.tmp.name, "MATLAB", "startup.m")

    def test_created_file_is_deleted_again(self):
        self.assertTrue(setup.add_hook(self.startup, MATLAB_DIR))
        self.assertTrue(setup.has_hook(self.startup))
        self.assertTrue(setup.remove_hook(self.startup, delete_if_empty=True))
        self.assertFalse(os.path.exists(self.startup))
        self.assertFalse(setup.remove_hook(self.startup))

    def test_users_startup_m_is_restored_byte_exact(self):
        os.makedirs(os.path.dirname(self.startup))
        original = "% Gr\xfc\xdfe\r\nformat compact\r\n".encode("latin-1")   # legacy cp1252 file
        with open(self.startup, "wb") as fh:
            fh.write(original)
        self.assertFalse(setup.add_hook(self.startup, MATLAB_DIR))
        self.assertTrue(setup.has_hook(self.startup))
        setup.remove_hook(self.startup, delete_if_empty=True)
        with open(self.startup, "rb") as fh:
            self.assertEqual(fh.read(), original)


class WindowsRegistryTests(unittest.TestCase):
    def setUp(self):
        self.reg = FakeWinreg()
        saved = sys.modules.get("winreg")
        sys.modules["winreg"] = self.reg
        self.addCleanup(lambda: sys.modules.__setitem__("winreg", saved) if saved
                        else sys.modules.pop("winreg", None))
        was = setup.IS_WINDOWS
        setup.IS_WINDOWS = True
        self.addCleanup(setattr, setup, "IS_WINDOWS", was)

    def test_autostart_round_trip(self):
        self.assertIsNone(setup.autostart_get())
        cmd = [r"C:\Python312\pythonw.exe", r"C:\Users\x y\anteena\dashboard\bridge_server.py",
               "--port", "8000"]
        setup.autostart_set(cmd)
        value = setup.autostart_get()
        self.assertEqual(value, r'C:\Python312\pythonw.exe "C:\Users\x y\anteena\dashboard\bridge_server.py" '
                                r"--port 8000")
        self.assertTrue(setup.autostart_remove())
        self.assertIsNone(setup.autostart_get())
        self.assertFalse(setup.autostart_remove())

    def test_documents_folder_follows_onedrive(self):
        self.reg.values[(setup.SHELL_FOLDERS_KEY, "Personal")] = r"%USERPROFILE%\OneDrive\Documents"
        self.assertEqual(setup.default_userpath(),
                         os.path.join(r"C:\Users\aaryan\OneDrive\Documents", "MATLAB"))


class InstallFlowTests(unittest.TestCase):
    """install -> status -> uninstall with a real background bridge and a fake MATLAB."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        d = self.tmp.name
        self.port = free_port()
        self.userpath = os.path.join(d, "Documents", "MATLAB")
        for name, value in (("DATA_DIR", d), ("STATE_FILE", os.path.join(d, "state.json")),
                            ("LOG_FILE", os.path.join(d, "bridge.log")),
                            ("CHECK_FILE", os.path.join(d, "check.json")),
                            ("CHECK_LOG", os.path.join(d, "check.log")),
                            ("IS_WINDOWS", False)):
            old = getattr(setup, name)
            setattr(setup, name, value)
            self.addCleanup(setattr, setup, name, old)
        env_old = os.environ.get("BRIDGE_DATA_FILE")
        os.environ["BRIDGE_DATA_FILE"] = os.path.join(d, "user_input.json")   # child bridge
        self.addCleanup(lambda: os.environ.__setitem__("BRIDGE_DATA_FILE", env_old) if env_old
                        else os.environ.pop("BRIDGE_DATA_FILE", None))
        self.addCleanup(self.stop_quietly)
        # Fake matlab: answers the -batch live_link_check(...) call like MATLAB would.
        self.matlab = os.path.join(d, "matlab")
        self.calls = os.path.join(d, "matlab_calls.txt")
        with open(self.matlab, "w", encoding="utf-8") as fh:
            fh.write(f"""#!{sys.executable}
import json, re, sys
args = sys.argv[1:]
open({self.calls!r}, "a").write(" ".join(args) + "\\n")
stmt = args[args.index("-batch") + 1]
out, url = re.fullmatch(r"live_link_check\\('(.*)', '(.*)'\\)", stmt).groups()
json.dump({{"ok": True, "matlab_version": "26.2.0 (R2026b)", "userpath": {self.userpath!r},
           "engine_ok": True, "engine_message": "MATLAB reproduces all 30 dashboard engines",
           "bridge_ok": True, "bridge_message": "MATLAB reached the bridge at " + url,
           "verify_status": "", "verify_summary": ""}}, open(out, "w"))
""")
        os.chmod(self.matlab, os.stat(self.matlab).st_mode | stat.S_IEXEC)

    def stop_quietly(self):
        with contextlib.suppress(RuntimeError):
            setup.stop_bridge(self.port)

    def run_cli(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = setup.main(["--port", str(self.port), *argv])
        return code, out.getvalue()

    def test_install_status_uninstall(self):
        code, out = self.run_cli("install", "--matlab-exe", self.matlab, "--no-browser")
        self.assertEqual(code, 0, out)
        status = bridge_server.running_bridge(self.port)
        self.assertIsNotNone(status, out)                       # bridge runs in the background
        self.assertNotEqual(status["pid"], os.getpid())
        self.assertIn("OK   engines : MATLAB reproduces all 30", out)
        self.assertIn("OK   bridge  : MATLAB reached the bridge", out)
        startup = os.path.join(self.userpath, "startup.m")      # userpath reported by MATLAB
        self.assertTrue(setup.has_hook(startup))
        with open(setup.STATE_FILE, encoding="utf-8") as fh:
            state = json.load(fh)
        self.assertEqual((state["startup_m"], state["startup_m_created"]), (startup, True))
        with open(self.calls, encoding="utf-8") as fh:
            call = fh.read()
        self.assertIn(f"-sd {setup.MATLAB_DIR}", call)
        self.assertIn("-batch live_link_check(", call)

        # Running install again is harmless: same bridge, one hook block.
        code, out2 = self.run_cli("install", "--matlab-exe", self.matlab, "--no-browser")
        self.assertEqual(code, 0)
        self.assertIn("already running", out2)
        self.assertEqual(bridge_server.running_bridge(self.port)["pid"], status["pid"])
        with open(startup, encoding="utf-8") as fh:
            self.assertEqual(fh.read().count(setup.HOOK_BEGIN), 1)

        code, out = self.run_cli("status")
        self.assertIn(f"Bridge     : running on http://127.0.0.1:{self.port}", out)
        self.assertIn("MATLAB hook: in", out)

        code, out = self.run_cli("uninstall")
        self.assertEqual(code, 0)
        self.assertIsNone(bridge_server.running_bridge(self.port))
        self.assertFalse(os.path.exists(startup))               # we created it -> removed
        self.assertFalse(os.path.exists(setup.STATE_FILE))

    def test_start_is_idempotent_and_stop_stops(self):
        status, started = setup.start_bridge(self.port)
        self.assertTrue(started)
        again, started2 = setup.start_bridge(self.port)
        self.assertFalse(started2)
        self.assertEqual(again["pid"], status["pid"])
        self.assertTrue(setup.stop_bridge(self.port))
        self.assertIsNone(bridge_server.running_bridge(self.port))
        self.assertFalse(setup.stop_bridge(self.port))

    def test_install_without_matlab_still_sets_up_the_bridge_and_hook(self):
        orig = bridge_server.find_matlab
        bridge_server.find_matlab = lambda max_age=30.0: None
        self.addCleanup(setattr, bridge_server, "find_matlab", orig)
        home = os.path.join(self.tmp.name, "home")
        old_home = os.environ.get("HOME")
        os.environ["HOME"] = home
        self.addCleanup(lambda: os.environ.__setitem__("HOME", old_home) if old_home
                        else os.environ.pop("HOME", None))
        code, out = self.run_cli("install", "--no-browser")
        self.assertEqual(code, 0, out)
        self.assertIn("MATLAB not found", out)
        self.assertIsNotNone(bridge_server.running_bridge(self.port))
        self.assertTrue(setup.has_hook(os.path.join(home, "Documents", "MATLAB", "startup.m")))


if __name__ == "__main__":
    unittest.main()
