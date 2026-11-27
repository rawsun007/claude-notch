import json
import os
import stat
import sys
import tempfile
import unittest
from unittest import mock

from claudenotch import hooks


class MergeTests(unittest.TestCase):
    def test_the_users_own_hooks_are_kept(self):
        mine = {"matcher": "Bash", "hooks": [{"type": "command", "command": "my-audit.sh"}]}
        out = hooks.merged({"model": "opus", "hooks": {"PreToolUse": [mine]}}, "tok")
        self.assertEqual(out["model"], "opus")
        rules = out["hooks"]["PreToolUse"]
        self.assertEqual(rules[0], mine)
        self.assertEqual(rules[1]["hooks"][0]["url"], "http://127.0.0.1:53127/hook?t=tok")
        self.assertEqual(rules[1]["hooks"][0]["timeout"], 290)

    def test_installing_twice_does_not_duplicate(self):
        once = hooks.merged({}, "tok")
        twice = hooks.merged(once, "tok")
        self.assertEqual(once, twice)

    def test_the_macs_entries_are_recognised_as_ours(self):
        mac = {"hooks": {"Stop": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:53127/hook?t=old"}]}],
                         "Notification": [{"hooks": [{"type": "command",
                                                      "command": "~/.claudenotch/bin/claudenotch-hook.sh"}]}]}}
        out = hooks.merged(mac, "new")
        self.assertEqual(len(out["hooks"]["Stop"]), 1)
        self.assertEqual(len(out["hooks"]["Notification"]), 1)
        self.assertIn("t=new", out["hooks"]["Stop"][0]["hooks"][0]["url"])

    def test_unmerge_removes_every_one_of_ours(self):
        mine = {"hooks": [{"type": "command", "command": "keep.sh"}]}
        out = hooks.unmerged(hooks.merged({"hooks": {"Stop": [mine]}}, "t"))
        self.assertEqual(out["hooks"], {"Stop": [mine]})
        self.assertNotIn("hooks", hooks.unmerged(hooks.merged({}, "t")))

    def test_is_installed(self):
        self.assertTrue(hooks.is_installed(hooks.merged({}, "t"), "t"))
        self.assertFalse(hooks.is_installed(hooks.merged({}, "t"), "other"))
        self.assertFalse(hooks.is_installed({}, "t"))

    def test_an_install_without_permission_denied_is_migrated(self):
        # Older installs lack it; is_installed says no, so start-up adds it.
        old = hooks.merged({}, "t")
        del old["hooks"]["PermissionDenied"]
        self.assertFalse(hooks.is_installed(old, "t"))
        self.assertEqual(hooks.merged(old, "t")["hooks"]["PermissionDenied"][0]["matcher"], ".*")


class DiskTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        home = self.tmp.name
        self.env = mock.patch.dict(os.environ, {"HOME": home, "USERPROFILE": home, "APPDATA": os.path.join(home, "AppData", "Roaming"),
                                                "CLAUDE_CONFIG_DIR": os.path.join(home, ".claude")})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_install_writes_backs_up_and_secures(self):
        os.makedirs(hooks.claude_dir())
        with open(hooks.settings_path(), "w") as f:
            json.dump({"theme": "dark"}, f)
        hooks.install()
        with open(hooks.settings_path()) as f:
            data = json.load(f)
        self.assertEqual(data["theme"], "dark")
        self.assertTrue(hooks.installed())
        backups = [n for n in os.listdir(hooks.claude_dir()) if ".before-claudenotch." in n]
        self.assertEqual(len(backups), 1)
        if sys.platform != "win32":   # no POSIX modes on Windows; the profile ACL protects it
            self.assertEqual(stat.S_IMODE(os.stat(hooks.token_path()).st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(os.stat(hooks.settings_path()).st_mode), 0o600)

    def test_an_unparseable_file_is_never_written(self):
        os.makedirs(hooks.claude_dir())
        with open(hooks.settings_path(), "w") as f:
            f.write("{ not json")
        with self.assertRaises(hooks.UnreadableSettings):
            hooks.install()
        with open(hooks.settings_path()) as f:
            self.assertEqual(f.read(), "{ not json")

    def test_backups_are_pruned(self):
        for _ in range(8):
            hooks.install()
            hooks.uninstall()
        backups = [n for n in os.listdir(hooks.claude_dir()) if ".before-claudenotch." in n]
        self.assertLessEqual(len(backups), hooks.BACKUPS_KEPT)

    def test_uninstall_after_install_restores_the_users_file(self):
        os.makedirs(hooks.claude_dir())
        with open(hooks.settings_path(), "w") as f:
            json.dump({"theme": "dark"}, f)
        hooks.install()
        hooks.uninstall()
        with open(hooks.settings_path()) as f:
            self.assertEqual(json.load(f), {"theme": "dark"})


if __name__ == "__main__":
    unittest.main()


class StatusLineTests(unittest.TestCase):
    CMD = "powershell -NoProfile -File C:/x/claudenotch-statusline.ps1"

    def test_the_users_line_is_kept_to_chain_to(self):
        out, prior = hooks.with_status_line({"statusLine": {"type": "command", "command": "my-line.sh"}}, self.CMD)
        self.assertEqual(out["statusLine"], {"type": "command", "command": self.CMD})
        self.assertEqual(prior, "my-line.sh")

    def test_rewiring_never_saves_our_own_forwarder_as_theirs(self):
        out, _ = hooks.with_status_line({}, self.CMD)
        _, prior = hooks.with_status_line(out, self.CMD + " --new")
        self.assertIsNone(prior)
        # The Mac's forwarder counts as ours too.
        _, prior = hooks.with_status_line({"statusLine": {"command": "bash ~/x/claudenotch-statusline.sh"}}, self.CMD)
        self.assertIsNone(prior)

    def test_unwiring_puts_theirs_back_or_removes_ours(self):
        ours = {"statusLine": {"type": "command", "command": self.CMD}, "theme": "dark"}
        self.assertEqual(hooks.without_status_line(ours, "my-line.sh")["statusLine"]["command"], "my-line.sh")
        self.assertEqual(hooks.without_status_line(ours, ""), {"theme": "dark"})
        theirs = {"statusLine": {"type": "command", "command": "their.sh"}}
        self.assertEqual(hooks.without_status_line(theirs, "x"), theirs)


class StatusLineDiskTests(DiskTests):
    CMD = StatusLineTests.CMD

    def test_install_and_uninstall_round_trip_the_users_status_line(self):
        os.makedirs(hooks.claude_dir())
        mine = {"theme": "dark", "statusLine": {"type": "command", "command": "my-line.sh"}}
        with open(hooks.settings_path(), "w") as f:
            json.dump(mine, f)
        hooks.install(status_command=self.CMD)
        with open(hooks.settings_path()) as f:
            self.assertEqual(json.load(f)["statusLine"]["command"], self.CMD)
        with open(hooks.status_inner_path(), encoding="utf-8") as f:
            self.assertEqual(f.read(), "my-line.sh")
        hooks.install(status_command=self.CMD)        # again: the saved line survives
        with open(hooks.status_inner_path(), encoding="utf-8") as f:
            self.assertEqual(f.read(), "my-line.sh")
        hooks.uninstall()
        with open(hooks.settings_path()) as f:
            self.assertEqual(json.load(f), mine)

    def test_plain_install_leaves_the_status_line_alone(self):
        os.makedirs(hooks.claude_dir())
        with open(hooks.settings_path(), "w") as f:
            json.dump({"statusLine": {"type": "command", "command": "my-line.sh"}}, f)
        hooks.install()
        with open(hooks.settings_path()) as f:
            self.assertEqual(json.load(f)["statusLine"]["command"], "my-line.sh")
