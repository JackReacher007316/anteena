#!/usr/bin/env python3
"""
live_link_setup.py - keep the web dashboard <-> MATLAB live link running.

One-time setup (on Windows just double-click install_live_link.bat):

    python dashboard/live_link_setup.py install

  1. Bridge: starts it now in the background (no window) and at every Windows
     log-in (registry key HKCU\\...\\CurrentVersion\\Run - no admin rights needed).
  2. MATLAB: runs a one-time check in MATLAB (engines, MATLAB -> bridge) and adds
     a small marked block to MATLAB's startup.m, so every MATLAB session opens
     the live link (live_verify).
  3. Opens the website. It finds the bridge on this PC and starts MATLAB.

Other commands

    python dashboard/live_link_setup.py status          what is installed / running
    python dashboard/live_link_setup.py start [--open] [--matlab] [--local]
    python dashboard/live_link_setup.py stop            stop the background bridge
    python dashboard/live_link_setup.py uninstall       undo everything install did

Only the Python standard library is used.
"""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
import webbrowser
from urllib.error import URLError
from urllib.request import Request, urlopen

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import bridge_server  # noqa: E402

PROJECT_ROOT = bridge_server.PROJECT_ROOT
MATLAB_DIR = bridge_server.MATLAB_DIR
BRIDGE_PY = os.path.join(HERE, "bridge_server.py")
DATA_DIR = os.environ.get("ANTEENA_DATA_DIR", os.path.join(PROJECT_ROOT, "data"))
STATE_FILE = os.path.join(DATA_DIR, "live_link_install.json")
LOG_FILE = os.path.join(DATA_DIR, "bridge.log")
CHECK_FILE = os.path.join(DATA_DIR, "live_link_check.json")
CHECK_LOG = os.path.join(DATA_DIR, "live_link_check.log")
SITE_URL = bridge_server.PUBLIC_SITE_URL
DEFAULT_PORT = 8000

IS_WINDOWS = os.name == "nt"   # registry / Documents lookups (tests may override)
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
RUN_VALUE = "AnteenaMatlabBridge"
SHELL_FOLDERS_KEY = r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
HOOK_BEGIN = "% >>> anteena live link >>>"
HOOK_END = "% <<< anteena live link <<<"
HOOK_RE = re.compile("^" + re.escape(HOOK_BEGIN) + ".*?^" + re.escape(HOOK_END) + r"[^\r\n]*(?:\r?\n|\Z)",
                     re.S | re.M)


def say(msg=""):
    print(msg, flush=True)


def step(title):
    say()
    say(f"--- {title} " + "-" * max(0, 66 - len(title)))


# ------------------------------------------------------------------ bridge
def bridge_url(port):
    return f"http://127.0.0.1:{port}"


def website_url(port):
    return SITE_URL if port == DEFAULT_PORT else f"{SITE_URL}?bridge={port}"


def pythonw_exe():
    """pythonw.exe next to this Python on Windows: runs without a console window."""
    exe = sys.executable
    if os.name == "nt":
        candidate = os.path.join(os.path.dirname(exe), "pythonw.exe")
        if os.path.isfile(candidate):
            return candidate
    return exe


def bridge_command(port):
    return [pythonw_exe(), BRIDGE_PY, "--host", "127.0.0.1", "--port", str(port),
            "--log-file", LOG_FILE]


_BACKGROUND = []


def start_bridge(port, wait_s=15.0):
    """Start the bridge in the background unless one answers already.
    Returns (status, started_now)."""
    status = bridge_server.running_bridge(port)
    if status:
        return status, False
    if bridge_server.old_bridge_running(port):
        raise RuntimeError(f"an OLD version of the bridge is running on port {port}. Close its "
                           "console window (or restart the PC) and run this again.")
    os.makedirs(DATA_DIR, exist_ok=True)
    kwargs = {"cwd": PROJECT_ROOT, "stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL,
              "stderr": subprocess.DEVNULL, "close_fds": True}
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    proc = subprocess.Popen(bridge_command(port), **kwargs)
    _BACKGROUND.append(proc)   # runs on after we exit - not a leaked child
    deadline = time.time() + wait_s
    while time.time() < deadline:
        status = bridge_server.running_bridge(port, timeout=1.0)
        if status:
            return status, True
        if proc.poll() is not None:
            break
        time.sleep(0.25)
    raise RuntimeError(f"the bridge did not start on port {port} - see {LOG_FILE}")


def stop_bridge(port, wait_s=6.0):
    """Stop the bridge answering on this port. Returns False if none was running."""
    status = bridge_server.running_bridge(port)
    if not status:
        return False
    pid = status.get("pid")
    if not isinstance(pid, int) or pid <= 0 or pid == os.getpid():
        raise RuntimeError("the running bridge did not report its process id - close it by hand")
    os.kill(pid, signal.SIGTERM)
    deadline = time.time() + wait_s
    while time.time() < deadline:
        if not bridge_server.running_bridge(port, timeout=0.5):
            return True
        time.sleep(0.2)
    raise RuntimeError(f"the bridge (pid {pid}) did not stop")


def post_json(url, payload, timeout=10):
    req = Request(url, data=json.dumps(payload).encode("utf-8"), method="POST",
                  headers={"Content-Type": "application/json"})
    with urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


# ------------------------------------------------------- Windows log-in start
def autostart_get():
    if not IS_WINDOWS:
        return None
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            return winreg.QueryValueEx(key, RUN_VALUE)[0]
    except OSError:
        return None


def autostart_set(cmd):
    import winreg
    with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
        winreg.SetValueEx(key, RUN_VALUE, 0, winreg.REG_SZ, subprocess.list2cmdline(cmd))


def autostart_remove():
    if not IS_WINDOWS:
        return False
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
            winreg.DeleteValue(key, RUN_VALUE)
        return True
    except OSError:
        return False


# ------------------------------------------------------------ MATLAB startup.m
def documents_dir():
    """The real Documents folder (also when Windows moved it to OneDrive)."""
    if IS_WINDOWS:
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, SHELL_FOLDERS_KEY) as key:
                value = winreg.QueryValueEx(key, "Personal")[0]
            path = winreg.ExpandEnvironmentStrings(value)
            if path:
                return path
        except OSError:
            pass
    return os.path.join(os.path.expanduser("~"), "Documents")


def default_userpath():
    """MATLAB's default userpath: Documents/MATLAB."""
    return os.path.join(documents_dir(), "MATLAB")


def hook_block(matlab_dir, newline="\n"):
    folder = matlab_dir.replace("'", "''")
    lines = [
        f"{HOOK_BEGIN}  added by install_live_link.bat, removed by uninstall_live_link.bat",
        "% Every MATLAB session opens the web dashboard live link (live_verify).",
        "try",
        "    if ~batchStartupOptionUsed",
        f"        addpath('{folder}');",
        "        live_verify;",
        "    end",
        "catch anteenaLinkErr",
        "    warning('anteena:liveLink', 'Live link not started: %s', anteenaLinkErr.message);",
        "end",
        HOOK_END,
    ]
    return newline.join(lines) + newline


def strip_hook(text):
    return HOOK_RE.sub("", text)


def with_hook(text, matlab_dir):
    newline = "\r\n" if "\r\n" in text else "\n"
    text = strip_hook(text)
    if text and not text.endswith(("\n", "\r")):
        text += newline
    return text + hook_block(matlab_dir, newline)


def _read_text(path):
    """(text, encoding) - keeps a legacy (non UTF-8) startup.m byte-exact."""
    with open(path, "rb") as fh:
        raw = fh.read()
    try:
        return raw.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        return raw.decode("latin-1"), "latin-1"


def _write_text(path, text, encoding):
    try:
        data = text.encode(encoding)
    except UnicodeEncodeError:
        data = text.encode("utf-8")
    with open(path, "wb") as fh:
        fh.write(data)


def add_hook(startup_m, matlab_dir):
    """Add (or refresh) our block in startup.m. Returns True if the file was created."""
    created = not os.path.exists(startup_m)
    text, encoding = ("", "utf-8") if created else _read_text(startup_m)
    os.makedirs(os.path.dirname(startup_m) or ".", exist_ok=True)
    _write_text(startup_m, with_hook(text, matlab_dir), encoding)
    return created


def has_hook(startup_m):
    if not startup_m or not os.path.isfile(startup_m):
        return False
    return bool(HOOK_RE.search(_read_text(startup_m)[0]))


def remove_hook(startup_m, delete_if_empty=False):
    """Remove our block. Returns True if a block was removed."""
    if not has_hook(startup_m):
        return False
    text, encoding = _read_text(startup_m)
    text = strip_hook(text)
    if delete_if_empty and not text.strip():
        os.remove(startup_m)
    else:
        _write_text(startup_m, text, encoding)
    return True


# ------------------------------------------------------------- MATLAB check
def run_matlab_check(exe, port, timeout_s=420):
    """Run live_link_check.m once in batch mode. Returns (result dict | None, problem)."""
    os.makedirs(DATA_DIR, exist_ok=True)
    for path in (CHECK_FILE, CHECK_LOG):
        if os.path.exists(path):
            os.remove(path)
    statement = "live_link_check('{}', '{}')".format(CHECK_FILE.replace("'", "''"), bridge_url(port))
    cmd = [exe] + (["-wait"] if os.name == "nt" else []) + [
        "-sd", MATLAB_DIR, "-logfile", CHECK_LOG, "-batch", statement]
    try:
        proc = subprocess.run(cmd, cwd=MATLAB_DIR, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=timeout_s, text=True,
                              errors="replace")
        output = proc.stdout or ""
    except subprocess.TimeoutExpired:
        return None, f"MATLAB did not finish within {timeout_s} s"
    except OSError as exc:
        return None, f"could not start MATLAB ({exc})"
    if os.path.isfile(CHECK_FILE):
        try:
            with open(CHECK_FILE, encoding="utf-8") as fh:
                return json.load(fh), None
        except ValueError as exc:
            return None, f"unreadable result file ({exc})"
    log = output
    if os.path.isfile(CHECK_LOG):
        with open(CHECK_LOG, encoding="utf-8", errors="replace") as fh:
            log = fh.read() or output
    tail = "\n".join(line for line in log.strip().splitlines()[-12:])
    return None, "MATLAB ran but wrote no result" + (f":\n{tail}" if tail else "")


# --------------------------------------------------------------------- state
def load_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(DATA_DIR, exist_ok=True)
    bridge_server.atomic_write_json(STATE_FILE, state)


# ------------------------------------------------------------------ commands
def cmd_install(args):
    port = args.port
    say("=" * 72)
    say(" LIVE LINK SETUP  web dashboard <-> MATLAB on this PC   (one time)")
    say("=" * 72)

    step("1/3 Bridge (connects the website to MATLAB)")
    status, started = start_bridge(port)
    say(f"  OK   bridge {'started' if started else 'already running'} on {bridge_url(port)} "
        f"(pid {status.get('pid')})")
    if IS_WINDOWS:
        autostart_set(bridge_command(port))
        say("  OK   it now starts by itself every time you log in to Windows (no window)")
    else:
        say("  --   automatic start at log-in is set up on Windows only")

    step("2/3 MATLAB")
    exe = args.matlab_exe or bridge_server.find_matlab(max_age=0)
    userpath_dir = None
    check = None
    if not exe:
        say("  --   MATLAB not found. Set MATLAB_EXE to matlab.exe and run this again,")
        say(f"       or open MATLAB and run:  cd('{MATLAB_DIR}'); live_verify")
    elif args.skip_matlab_check:
        say(f"  OK   MATLAB: {exe} (check skipped)")
    else:
        say(f"  OK   MATLAB: {exe}")
        say("  ..   one-time check inside MATLAB (starts MATLAB in batch mode, ~1 minute) ...")
        check, problem = run_matlab_check(exe, port)
        if check:
            userpath_dir = check.get("userpath") or None
            say(f"  {'OK  ' if check.get('engine_ok') else 'FAIL'} engines : {check.get('engine_message')}")
            say(f"  {'OK  ' if check.get('bridge_ok') else 'FAIL'} bridge  : {check.get('bridge_message')}")
            if check.get("verify_summary"):
                verdict = " ".join(x for x in (check.get("verify_status"), check.get("verify_summary")) if x)
                say(f"       input   : {verdict}")
            say(f"       version : {check.get('matlab_version')}")
        else:
            say(f"  FAIL the MATLAB check could not run: {problem}")
            say(f"       full log: {CHECK_LOG}")

    state = load_state()
    hook_file = None
    if not args.no_startup_hook:
        hook_file = os.path.join(userpath_dir or default_userpath(), "startup.m")
        created = add_hook(hook_file, MATLAB_DIR)
        if state.get("startup_m") == hook_file and state.get("startup_m_created"):
            created = True
        say(f"  OK   every MATLAB session now opens the live link ({hook_file})")
    else:
        created = False

    save_state({
        "port": port,
        "autostart": IS_WINDOWS,
        "startup_m": hook_file,
        "startup_m_created": created,
        "matlab_exe": exe,
        "check": check,
        "installed_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    })

    step("3/3 Website")
    url = website_url(port)
    say(f"  ->   {url}")
    say("       If the browser asks to allow access to devices / apps on this device,")
    say("       click Allow. The website then starts MATLAB with the live window.")
    if not args.no_browser:
        webbrowser.open(f"{SITE_URL}?bridge={port}")
    say()
    say("Done. The website is always online; MATLAB connects whenever this PC is on.")
    say("Undo everything: uninstall_live_link.bat")
    return 0


def cmd_uninstall(args):
    state = load_state()
    port = int(state.get("port") or args.port)
    say("Removing the live link setup ...")
    if autostart_remove():
        say("  OK   no longer starts at Windows log-in")
    try:
        if stop_bridge(port):
            say("  OK   bridge stopped")
    except RuntimeError as exc:
        say(f"  --   {exc}")
    hook_file = state.get("startup_m") or os.path.join(default_userpath(), "startup.m")
    if remove_hook(hook_file, delete_if_empty=bool(state.get("startup_m_created"))):
        say(f"  OK   live link removed from MATLAB's startup ({hook_file})")
    if os.path.exists(STATE_FILE):
        os.remove(STATE_FILE)
    say("Done. (The website stays online; it just cannot reach MATLAB on this PC.)")
    return 0


def cmd_status(args):
    state = load_state()
    port = args.port
    status = bridge_server.running_bridge(port)
    if status:
        say(f"Bridge     : running on {bridge_url(port)} (pid {status.get('pid')})")
        if status.get("matlab_connected"):
            res = status.get("matlab_result") or {}
            say(f"MATLAB     : LIVE ({status.get('matlab_version') or 'version ?'})"
                + (f" - last verdict #{res.get('seq')}: {res.get('summary')}" if res else ""))
        elif status.get("matlab_starting"):
            say("MATLAB     : starting ...")
        else:
            say("MATLAB     : not connected (open the website, or run live_verify in MATLAB)")
    elif bridge_server.old_bridge_running(port):
        say(f"Bridge     : an OLD version is running on port {port} - close its window")
    else:
        say("Bridge     : not running (start_live_verification.bat starts it)")
    if IS_WINDOWS:
        say(f"Auto-start : {'on (Windows log-in)' if autostart_get() else 'off'}")
    hook_file = state.get("startup_m") or os.path.join(default_userpath(), "startup.m")
    say(f"MATLAB hook: {'in ' + hook_file if has_hook(hook_file) else 'not installed'}")
    say(f"MATLAB exe : {bridge_server.find_matlab(max_age=0) or 'not found (set MATLAB_EXE)'}")
    say(f"Website    : {website_url(port)}")
    return 0


def cmd_start(args):
    port = args.port
    status, started = start_bridge(port)
    say(f"Bridge {'started' if started else 'already running'} on {bridge_url(port)} "
        f"(pid {status.get('pid')})")
    if args.open:
        url = f"{bridge_url(port)}/" if args.local else f"{SITE_URL}?bridge={port}"
        webbrowser.open(url)
        say(f"Opened {url}")
    if args.matlab:
        try:
            res = post_json(f"{bridge_url(port)}/api/matlab/launch", {"target": "live"})
            say(f"MATLAB: {res.get('message', res.get('status'))}")
        except (OSError, URLError, ValueError) as exc:
            say(f"MATLAB: could not ask the bridge to start it ({exc})")
    return 0


def cmd_stop(args):
    say("Bridge stopped." if stop_bridge(args.port) else "No bridge was running.")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Keep the web dashboard <-> MATLAB live link running.")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="bridge port (8000)")
    sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("install", help="one-time setup (bridge at log-in, MATLAB startup hook)")
    p.add_argument("--matlab-exe", help="path to matlab.exe (default: newest installed)")
    p.add_argument("--skip-matlab-check", action="store_true", help="do not run the MATLAB check")
    p.add_argument("--no-startup-hook", action="store_true", help="leave MATLAB's startup.m alone")
    p.add_argument("--no-browser", action="store_true", help="do not open the website")
    sub.add_parser("uninstall", help="undo install")
    sub.add_parser("status", help="show what is installed / running")
    p = sub.add_parser("start", help="start the bridge in the background")
    p.add_argument("--open", action="store_true", help="open the website")
    p.add_argument("--local", action="store_true", help="with --open: the dashboard served by the bridge")
    p.add_argument("--matlab", action="store_true", help="ask the bridge to start MATLAB (live_verify)")
    sub.add_parser("stop", help="stop the background bridge")
    args = ap.parse_args(argv)
    commands = {"install": cmd_install, "uninstall": cmd_uninstall, "status": cmd_status,
                "start": cmd_start, "stop": cmd_stop}
    try:
        return commands[args.command](args)
    except RuntimeError as exc:
        say(f"\nERROR: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
