import unittest

from claudenotch.danger import bash_danger, danger_reasons, nested_scripts, path_danger

HOME = "/home/alice"


class BashDangerTests(unittest.TestCase):
    def test_rm_rf_in_every_spelling(self):
        for cmd in ("rm -rf build", "rm -r -f build", "rm --recursive --force build", "rm -fR x"):
            self.assertIn("rm -rf, deletes files recursively without prompting", bash_danger(cmd), cmd)

    def test_flags_from_another_command_in_a_chain_do_not_count(self):
        self.assertNotIn("rm -rf, deletes files recursively without prompting",
                         bash_danger("git push -f origin x && rm -r tmp"))

    def test_free_text_in_quotes_does_not_fire(self):
        self.assertEqual(bash_danger('git commit -m "remove the rm -rf helper and sudo"'), [])

    def test_a_quoted_script_is_still_scanned(self):
        self.assertEqual(nested_scripts("bash -c 'sudo rm -rf ~'"), ["sudo rm -rf ~"])
        reasons = bash_danger("bash -c 'sudo rm -rf ~'")
        self.assertIn("sudo, runs with root privileges", reasons)
        self.assertIn("rm -rf, deletes files recursively without prompting", reasons)

    def test_inline_interpreter_programs(self):
        self.assertIn("the script deletes a directory tree",
                      bash_danger("python3 -c 'import shutil; shutil.rmtree(\"/tmp/x\")'"))

    def test_linux_specific_rules(self):
        self.assertIn("pkexec, runs with root privileges", bash_danger("pkexec apt install x"))
        self.assertIn("systemctl enable, installs a service that starts by itself",
                      bash_danger("systemctl --user enable evil.service"))
        self.assertIn("writes raw bytes to a disk device", bash_danger("cat img > /dev/mmcblk0"))

    def test_ordinary_commands_are_quiet(self):
        for cmd in ("npm test", "git status", "ls -la", "rm file.txt", 'grep -r "sudo" .'):
            self.assertEqual(bash_danger(cmd), [], cmd)


class PathDangerTests(unittest.TestCase):
    def test_credentials_and_startup(self):
        self.assertTrue(path_danger("/home/alice/.ssh/authorized_keys", HOME))
        self.assertTrue(path_danger("~/.bashrc".replace("~", HOME), HOME))
        self.assertTrue(path_danger("/home/alice/.config/autostart/x.desktop", HOME))
        self.assertTrue(path_danger("/home/alice/.config/systemd/user/x.service", HOME))

    def test_relative_forms_count_too(self):
        self.assertTrue(path_danger(".ssh/authorized_keys", HOME))
        self.assertTrue(path_danger("repo/.git/hooks/pre-commit", HOME))
        self.assertTrue(path_danger("sub/.claude/settings.json", HOME))

    def test_dot_dot_cannot_hide_a_path(self):
        self.assertTrue(path_danger("/home/alice/.ssh/../.ssh/id_rsa", HOME))

    def test_lookalikes_do_not_count(self):
        self.assertEqual(path_danger("/home/alice/notes.ssh/x", HOME), [])
        self.assertEqual(path_danger("/home/alice/project/src/main.py", HOME), [])

    def test_system_dirs(self):
        self.assertEqual(path_danger("/etc/hosts", HOME), ["writes inside /etc/, a system directory"])


class DispatchTests(unittest.TestCase):
    def test_tools(self):
        self.assertTrue(danger_reasons("Bash", {"command": "sudo ls"}))
        self.assertTrue(danger_reasons("Write", {"file_path": "/etc/passwd"}))
        self.assertTrue(danger_reasons("shell", {"command": ["bash", "-lc", "sudo reboot"]}))
        self.assertEqual(danger_reasons("Read", {"file_path": "/etc/passwd"}), [])


if __name__ == "__main__":
    unittest.main()
