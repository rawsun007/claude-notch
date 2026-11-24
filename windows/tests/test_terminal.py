import os
import tempfile
import unittest

from claudenotch_win import terminal


class TerminalTests(unittest.TestCase):
    def test_only_plain_session_ids_are_passed(self):
        self.assertEqual(terminal.claude_command(), "claude")
        self.assertEqual(terminal.claude_command("4f1c-9a_2"), "claude --resume 4f1c-9a_2")
        for bad in ("x; rm -rf ~", "$(evil)", "a b", "", "a" * 81, "id`calc`"):
            self.assertIsNone(terminal.claude_command(bad), bad)

    def test_folder_is_only_the_working_directory(self):
        with tempfile.TemporaryDirectory() as d:
            argv, cwd = terminal.plan(d, "abc", wt=r"C:\wt.exe")
            self.assertEqual(argv[:3], [r"C:\wt.exe", "-d", os.path.abspath(d)])
            self.assertEqual(argv[-1], "claude --resume abc")
            self.assertEqual(cwd, os.path.abspath(d))
            argv, _ = terminal.plan(d, None, wt=None)
            self.assertEqual(argv, ["powershell.exe", "-NoExit", "-NoLogo", "-Command", "claude"])
            semi = os.path.join(d, "a;b")
            os.mkdir(semi)
            argv, cwd = terminal.plan(semi, None, wt=r"C:\wt.exe")
            self.assertEqual(argv[0], "powershell.exe")          # wt would split at the ;
            self.assertEqual(cwd, os.path.abspath(semi))
        self.assertIsNone(terminal.plan(r"C:\does\not\exist", None, wt=None))
        self.assertIsNone(terminal.plan(".", "bad id", wt=None))


if __name__ == "__main__":
    unittest.main()
