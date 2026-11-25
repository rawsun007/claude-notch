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
            self.assertEqual(argv[:6], [r"C:\wt.exe", "-w", "new", "new-tab", "-d", os.path.abspath(d)])
            self.assertEqual(argv[6:9], ["--title", terminal.window_title(d), "--suppressApplicationTitle"])
            self.assertTrue(terminal.window_title(d).startswith("Claude Code · "))
            self.assertNotIn(";", terminal.window_title(r"C:;b"))
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

    def test_a_dropped_file_starts_claude_with_it_quoted(self):
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, "it's $(evil); x.txt")
            open(f, "w").close()
            self.assertEqual(terminal.drop_launch(d), (os.path.abspath(d), None))
            folder, msg = terminal.drop_launch(f)
            self.assertEqual((folder, msg), (os.path.abspath(d), "@it's $(evil); x.txt"))
            argv, _ = terminal.plan(folder, wt=r"C:\wt.exe", message=msg)
            self.assertEqual(argv[0], "powershell.exe")                  # the ; keeps wt out
            self.assertEqual(argv[-1], "claude '@it''s $(evil); x.txt'")  # single-quoted: nothing expands
            self.assertIsNone(terminal.drop_launch(os.path.join(d, "missing")))
        self.assertEqual(terminal.ps_quote("a’; calc"), "'a’’; calc'")

    def test_compose_rules(self):
        self.assertTrue(terminal.is_terminal(r"C:\Program Files\WindowsApps\WindowsTerminal.exe"))
        self.assertTrue(terminal.is_terminal("pwsh.exe"))
        self.assertFalse(terminal.is_terminal(r"C:\Program Files\Microsoft VS Code\Code.exe"))
        self.assertFalse(terminal.is_terminal("notepad.exe"))
        self.assertEqual(terminal.terminal_name("mintty.exe"), "Git Bash")
        self.assertEqual(terminal.one_line("fix it\n\tnow\x07 please "), "fix it now please")
        self.assertEqual(terminal.claude_command("abc", "keep going\nthanks"), "claude --resume abc 'keep going thanks'")
        self.assertIsNone(terminal.claude_command("bad id", "x"))


if __name__ == "__main__":
    unittest.main()
