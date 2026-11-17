#!/usr/bin/env python3
"""Restart every running ClaudeNotch into the version just installed.

Run as root by the .deb's postinst on upgrade. Versions from 0.44.0 notice
a new install themselves and restart; 0.43.x cannot, so without this the old
code kept running after `apt install` and the new version only appeared
after uninstalling. Each process is relaunched as its own user, in its own
desktop session (DISPLAY, Wayland and D-Bus taken from the old process), and
told which version it was so it can say it was updated.

Usage: restart-running.py OLD_VERSION
"""

import os
import pwd
import signal
import subprocess
import sys
import time

KEEP = ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS",
        "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
        "CLAUDE_CONFIG_DIR", "LANG", "LC_ALL", "PATH", "HOME", "USER", "LOGNAME", "GDK_BACKEND")


def running():
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/cmdline", "rb") as f:
                argv = [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
            if len(argv) < 2 or "python" not in os.path.basename(argv[0]) or argv[1] != "/usr/bin/claudenotch":
                continue
            with open(f"/proc/{entry}/environ", "rb") as f:
                env = dict(kv.decode("utf-8", "replace").split("=", 1) for kv in f.read().split(b"\0") if b"=" in kv)
            uid = os.stat(f"/proc/{entry}").st_uid
        except OSError:
            continue
        yield int(entry), uid, argv[2:], {k: v for k, v in env.items() if k in KEEP}


def main():
    old = sys.argv[1] if len(sys.argv) > 1 else ""
    procs = list(running())   # only processes whose session could be read
    for pid, _, _, _ in procs:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and any(os.path.exists(f"/proc/{p[0]}") for p in procs):
        time.sleep(0.1)
    for pid, uid, args, env in procs:
        if os.path.exists(f"/proc/{pid}"):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        if uid == 0 or ("--headless" not in args and not (env.get("DISPLAY") or env.get("WAYLAND_DISPLAY"))):
            continue   # never relaunch as root, nor a GUI copy with no session to draw on
        try:
            user = pwd.getpwuid(uid)
        except KeyError:
            continue
        env = dict(env, HOME=user.pw_dir, USER=user.pw_name, LOGNAME=user.pw_name,
                   CLAUDENOTCH_UPDATED_FROM=old)
        env.setdefault("PATH", "/usr/local/bin:/usr/bin:/bin")

        def drop(uid=uid, gid=user.pw_gid, name=user.pw_name):
            os.setsid()
            os.initgroups(name, gid)
            os.setgid(gid)
            os.setuid(uid)

        try:
            # No terminal, so the app logs to its own file, opened as the user.
            subprocess.Popen(["/usr/bin/claudenotch", *args], env=env, cwd=user.pw_dir, preexec_fn=drop,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             close_fds=True)
            print(f"claudenotch: restarted for {user.pw_name}")
        except OSError as e:
            print(f"claudenotch: could not restart for {user.pw_name}: {e}")


if __name__ == "__main__":
    main()
