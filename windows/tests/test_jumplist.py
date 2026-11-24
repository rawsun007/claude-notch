import sys
import unittest

from claudenotch_win import jumplist, urlscheme


class JumpListTests(unittest.TestCase):
    def test_every_task_is_one_of_our_links(self):
        lines = jumplist.task_lines(r"C:\Apps\ClaudeNotch.exe")
        self.assertEqual([t for t, *_ in lines], ["Send to Claude", "Open the Notch", "Settings", "Usage", "History"])
        for _, exe, args, _ in lines:
            self.assertEqual(exe, r"C:\Apps\ClaudeNotch.exe")
            link = args.split('"')[1]
            self.assertIsNotNone(urlscheme.parse(link), link)
        self.assertEqual(urlscheme.parse("claudenotch://settings/usage"), ("settings", "usage"))

    def test_only_for_the_installed_exe(self):
        self.assertFalse(jumplist.install(exe=None) if not getattr(sys, "frozen", False) else False)

    @unittest.skipUnless(sys.platform == "win32", "Windows shell")
    def test_the_shell_takes_the_list(self):
        app_id = "Rawsun.ClaudeNotch.Test"
        try:
            self.assertTrue(jumplist.install(app_id, exe=sys.executable))
        finally:
            jumplist.remove(app_id)


if __name__ == "__main__":
    unittest.main()
