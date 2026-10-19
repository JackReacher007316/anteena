#!/usr/bin/env python3
"""
live_link_bootstrap.py - ONE-COMMAND setup of the web dashboard <-> MATLAB live link.

Windows, press Win+R and paste (install.ps1 finds or installs Python, then runs this):
    powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((New-Object Net.WebClient).DownloadString('https://jackreacher007316.github.io/anteena/install.ps1'))"

With Python already installed, this works too:
    py -3 -c "import urllib.request as u; exec(u.urlopen('https://jackreacher007316.github.io/anteena/dashboard/live_link_bootstrap.py').read())"

What it does
  1. downloads the PC connector (this repository) into %USERPROFILE%\\anteena-live
     (running it again updates that copy)
  2. stops a bridge that is already running on port 8000 - also the old one
     from before the live link - so the new one can take over
  3. runs  dashboard/live_link_setup.py install  from the new copy: bridge now
     and at every Windows log-in, one-time MATLAB check, MATLAB startup hook,
     then opens the website (which starts MATLAB)

It never touches anything else: your own repository checkout stays as it is.
Only the Python standard library is used. Works without __file__ (exec'd).
"""

import argparse
import io
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import zipfile
from urllib.request import urlopen

ZIP_URL = ("https://github.com/JackReacher007316/anteena/archive/refs/heads/"
           "arena/000da5f3-anteena.zip")
DEFAULT_DEST = os.path.join(os.path.expanduser("~"), "anteena-live")
DEFAULT_PORT = 8000


def say(msg=""):
    print(msg, flush=True)


def fetch(url, timeout=180):
    with urlopen(url, timeout=timeout) as resp:
        return resp.read()


def bridge_status(port, timeout=2.0):
    """JSON from /api/status of whatever answers on the port, else None."""
    try:
        with urlopen(f"http://127.0.0.1:{port}/api/status", timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return data if isinstance(data, dict) else None
    except Exception:  # noqa: BLE001 - nothing (usable) answers
        return None


def pids_from_netstat(text, port):
    """PIDs listening on the port in "netstat -ano -p tcp" output (Windows)."""
    pids = set()
    for line in text.splitlines():
        parts = line.split()
        # "TCP  0.0.0.0:8000  0.0.0.0:0  LISTENING  1234" - the state word is
        # localized, but a listening socket always has the remote end x:0
        if (len(parts) >= 5 and parts[0].upper() == "TCP" and parts[1].endswith(f":{port}")
                and parts[2].endswith(":0") and parts[-1].isdigit()):
            pids.add(int(parts[-1]))
    return pids


def listening_pids(port):
    """Process ids listening on the TCP port (Windows: netstat, else: ss)."""
    pids = set()
    try:
        if os.name == "nt":
            out = subprocess.run(["netstat", "-ano", "-p", "tcp"], capture_output=True,
                                 text=True, timeout=20).stdout
            pids |= pids_from_netstat(out, port)
        else:
            out = subprocess.run(["ss", "-ltnpH", f"sport = :{port}"], capture_output=True,
                                 text=True, timeout=20).stdout
            pids.update(int(p) for p in re.findall(r"pid=(\d+)", out))
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    pids.discard(0)
    pids.discard(os.getpid())
    return pids


def kind_of(status):
    if status is None:
        return None
    if isinstance(status.get("session"), str):
        return "bridge"          # live-link bridge (this project)
    if "matlab_connected" in status:
        return "old-bridge"      # the bridge from before the live link
    return "other"


def stop_existing_bridge(port, wait_s=10.0):
    """Free the port if one of our bridges (new or old) holds it.
    Returns a short description of what happened; raises if a foreign program uses it."""
    status = bridge_status(port)
    kind = kind_of(status)
    if kind is None:
        if listening_pids(port):
            raise RuntimeError(f"port {port} is used by another program - close it, or run this "
                               f"with --port 8001 and open the website with ?bridge=8001")
        return "no bridge was running"
    if kind == "other":
        raise RuntimeError(f"port {port} is used by another web server - close it, or use --port 8001")
    pids = {status["pid"]} if kind == "bridge" and isinstance(status.get("pid"), int) else set()
    pids |= listening_pids(port)
    if not pids:
        raise RuntimeError(f"a bridge answers on port {port} but its process was not found - "
                           "close its window (or restart the PC) and run this again")
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.time() + wait_s
    while time.time() < deadline:
        if bridge_status(port, timeout=0.5) is None and not listening_pids(port):
            return f"stopped the {'old ' if kind == 'old-bridge' else ''}bridge (pid {', '.join(map(str, sorted(pids)))})"
        time.sleep(0.25)
    raise RuntimeError(f"could not stop the bridge on port {port} - restart the PC and run this again")


def install_files(zip_bytes, dest):
    """Unpack the GitHub archive into dest (replacing an earlier copy)."""
    dest = os.path.abspath(dest)
    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=".anteena-live-", dir=parent)
    try:
        with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
            names = zf.namelist()
            root = names[0].split("/")[0]
            if not all(n.startswith(root + "/") for n in names):
                raise RuntimeError("unexpected archive layout")
            zf.extractall(tmp)
        fresh = os.path.join(tmp, root)
        if not os.path.isfile(os.path.join(fresh, "dashboard", "live_link_setup.py")):
            raise RuntimeError("the download does not contain dashboard/live_link_setup.py")
        if not os.path.exists(dest):
            os.replace(fresh, dest)
            return "installed"
        old = dest + ".old"
        shutil.rmtree(old, ignore_errors=True)
        try:
            os.replace(dest, old)          # swap folders ...
            os.replace(fresh, dest)
            shutil.rmtree(old, ignore_errors=True)
        except OSError:
            if os.path.exists(old) and not os.path.exists(dest):
                os.replace(old, dest)      # ... or, if a program sits in it (MATLAB's
            shutil.copytree(fresh, dest, dirs_exist_ok=True)   # current folder), overwrite
        return "updated"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description="One-command setup of the dashboard <-> MATLAB live link")
    ap.add_argument("--dest", default=DEFAULT_DEST, help=f"where to put the PC connector ({DEFAULT_DEST})")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--zip-url", default=ZIP_URL, help=argparse.SUPPRESS)
    args, passthrough = ap.parse_known_args(argv)   # e.g. --no-browser, --matlab-exe ...

    say("=" * 72)
    say(" WEB DASHBOARD <-> MATLAB : one-command setup")
    say("=" * 72)
    try:
        say("[1/3] downloading the PC connector ...")
        data = fetch(args.zip_url)
        say(f"      {len(data) / 1e6:.1f} MB")
        say(f"[2/3] {stop_existing_bridge(args.port)}")
        what = install_files(data, args.dest)
        say(f"      files {what}: {args.dest}")
    except Exception as exc:  # noqa: BLE001 - explain and stop
        say(f"\nERROR: {exc}")
        return 1
    say("[3/3] setting up the live link ...")
    setup = os.path.join(args.dest, "dashboard", "live_link_setup.py")
    cmd = [sys.executable, setup, "--port", str(args.port), "install"] + passthrough
    return subprocess.call(cmd)


if __name__ == "__main__":
    code = main()
    if code:
        sys.exit(code)
