"""The CLI flags that do one thing and exit. Runs anywhere: no Qt needed."""

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from claudenotch_win import app, paths  # noqa: E402


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": self.tmp.name, "HOME": self.tmp.name,
                                                "APPDATA": self.tmp.name, "USERPROFILE": self.tmp.name})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def run_cli(self, *argv):
        out = io.StringIO()
        with redirect_stdout(out), mock.patch.object(app, "running_version", return_value=None):
            code = app.main(list(argv))
        return code, out.getvalue()

    def test_install_then_uninstall_hooks(self):
        code, out = self.run_cli("--install-hooks")
        self.assertEqual(code, 0)
        self.assertIn("Hooks installed", out)
        with open(os.path.join(self.tmp.name, "settings.json"), encoding="utf-8") as f:
            self.assertIn("PreToolUse", json.load(f)["hooks"])
        code, out = self.run_cli("--uninstall-hooks")
        self.assertEqual(code, 0)
        with open(os.path.join(self.tmp.name, "settings.json"), encoding="utf-8") as f:
            self.assertNotIn("hooks", json.load(f))

    def test_status(self):
        code, out = self.run_cli("--status")
        self.assertEqual(code, 0)
        self.assertIn("hooks: not installed", out)
        self.assertIn("app:   not running", out)

    def test_quit_running_when_nothing_runs(self):
        code, out = self.run_cli("--quit-running")
        self.assertEqual(code, 0)

    def test_unreadable_settings_are_left_alone(self):
        path = os.path.join(self.tmp.name, "settings.json")
        with open(path, "w") as f:
            f.write("{ not json")
        code, out = self.run_cli("--install-hooks")
        self.assertEqual(code, 1)
        with open(path) as f:
            self.assertEqual(f.read(), "{ not json")


class PathTests(unittest.TestCase):
    def test_windows_locations(self):
        with mock.patch.dict(os.environ, {"APPDATA": "C:/R", "LOCALAPPDATA": "C:/L"}):
            self.assertEqual(paths.config_dir(), os.path.join("C:/R", "ClaudeNotch"))
            self.assertEqual(paths.log_path(), os.path.join("C:/L", "ClaudeNotch", "claudenotch.log"))
            self.assertEqual(paths.install_dir(), os.path.join("C:/L", "Programs", "ClaudeNotch"))

    def test_run_key_command_from_a_checkout(self):
        cmd = paths.executable_command("--background")
        self.assertIn("claudenotch_win", cmd)
        self.assertTrue(cmd.endswith("--background"))


if __name__ == "__main__":
    unittest.main()
