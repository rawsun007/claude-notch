"""The PowerShell status line forwarder posts exactly what the Mac's jq
program posts (checked against the Python port of it), draws the default
line, and never fails. Runs the real script; Windows only."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest import mock

from claudenotch import statusline

from claudenotch_win import paths, winstatus

RAW = {
    "session_id": "abc",
    "session_name": "fix the build",
    "workspace": {"current_dir": "C:\\work\\proj", "git_worktree": "wt-1"},
    "model": {"id": "claude-opus-5-5", "display_name": "Opus 5.5"},
    "effort": {"level": "high"},
    "cost": {"total_cost_usd": 1.25, "total_lines_added": 10, "total_lines_removed": 2},
    "context_window": {"used_percentage": 42.5, "context_window_size": 200000, "total_input_tokens": 85000},
    "rate_limits": {"five_hour": {"used_percentage": 30, "resets_at": 1764000000}},
    "prompt_cache": {"warm": False, "ttl": "5m", "last_miss_cause": {"causes": ["ttl", "edit"]}},
    "pr": {"number": 7, "url": "https://github.com/o/r/pull/7", "review_state": "approved"},
}


class CommandTests(unittest.TestCase):
    def test_command_quotes_a_forward_slash_path(self):
        cmd = winstatus.command("C:\\Users\\a b\\AppData\\Roaming\\ClaudeNotch\\claudenotch-statusline.ps1")
        self.assertIn('-File "C:/Users/a b/AppData/Roaming/ClaudeNotch/claudenotch-statusline.ps1"', cmd)
        self.assertIn(hooks_mark(), cmd)

    def test_the_script_ships_with_the_app(self):
        self.assertTrue(os.path.exists(paths.resource(winstatus.SCRIPT)))

    def test_prepare_copies_next_to_the_token(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, {"APPDATA": d}):
            cmd = winstatus.prepare()
            self.assertTrue(os.path.exists(winstatus.installed_path()))
            self.assertIn("claudenotch-statusline.ps1", cmd)


def hooks_mark() -> str:
    from claudenotch import hooks
    return hooks.STATUS_MARK


@unittest.skipUnless(sys.platform == "win32" and shutil.which("powershell"), "needs Windows PowerShell")
class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.script = os.path.join(self.dir.name, winstatus.SCRIPT)
        shutil.copyfile(paths.resource(winstatus.SCRIPT), self.script)
        with open(os.path.join(self.dir.name, "hook-token"), "w") as f:
            f.write("tok123\n")
        got = self.got = []

        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                got.append((self.path, json.loads(self.rfile.read(n).decode("utf-8"))))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"ok":true}')

            def log_message(self, *a):
                pass

        self.httpd = HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.dir.cleanup()

    def run_script(self, stdin: str) -> subprocess.CompletedProcess:
        env = dict(os.environ, CLAUDENOTCH_PORT=str(self.httpd.server_address[1]))
        return subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                               "-File", self.script], input=stdin.encode("utf-8"), capture_output=True, env=env,
                              timeout=60)

    def test_posts_the_macs_body_and_draws_the_default_line(self):
        out = self.run_script(json.dumps(RAW))
        self.assertEqual(out.returncode, 0)
        self.assertEqual(len(self.got), 1)
        path, body = self.got[0]
        self.assertEqual(path, "/statusline?t=tok123")
        self.assertEqual(body, statusline.flatten(RAW))
        self.assertEqual(out.stdout.decode("utf-8"), "Opus 5.5  C:\\work\\proj  ctx 42.5%")

    def test_no_app_running_still_draws_the_line_quickly(self):
        import socket
        import time
        with socket.socket() as probe:          # a port nobody listens on
            probe.bind(("127.0.0.1", 0))
            free = probe.getsockname()[1]
        env = dict(os.environ, CLAUDENOTCH_PORT=str(free))
        t0 = time.monotonic()
        out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                              "-File", self.script], input=json.dumps(RAW).encode(), capture_output=True,
                             env=env, timeout=60)
        self.assertEqual(out.returncode, 0)
        self.assertIn("ctx 42.5%", out.stdout.decode("utf-8"))
        # PowerShell's own start-up is most of it; the probe adds at most 0.15 s
        # where a refused connection would add about two seconds.
        self.assertLess(time.monotonic() - t0, 6)

    def test_junk_input_never_fails(self):
        out = self.run_script("not json at all")
        self.assertEqual(out.returncode, 0)
        self.assertEqual(self.got, [])

    def test_runs_the_users_previous_line(self):
        with open(os.path.join(self.dir.name, "statusline-inner.cmd"), "w") as f:
            f.write("echo mine")
        out = self.run_script(json.dumps(RAW))
        self.assertEqual(out.returncode, 0)
        self.assertIn("mine", out.stdout.decode("utf-8", "replace"))
        self.assertEqual(len(self.got), 1)


if __name__ == "__main__":
    unittest.main()
