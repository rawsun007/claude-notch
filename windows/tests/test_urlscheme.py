import unittest

from claudenotch_win import urlscheme as u


class ParseTests(unittest.TestCase):
    def test_verbs(self):
        self.assertEqual(u.parse("claudenotch://open"), ("open", ""))
        self.assertEqual(u.parse("claudenotch://settings"), ("settings", ""))
        self.assertEqual(u.parse("claudenotch://settings/privacy"), ("settings", "privacy"))
        self.assertEqual(u.parse("CLAUDENOTCH://Settings/Usage"), ("settings", "usage"))
        self.assertEqual(u.parse("claudenotch:///settings/budget"), ("settings", "budget"))
        self.assertEqual(u.parse("claudenotch://history"), ("settings", "history"))

    def test_unknown_page_opens_settings_and_unknown_verb_nothing(self):
        self.assertEqual(u.parse("claudenotch://settings/../../etc"), ("settings", ""))
        self.assertIsNone(u.parse("claudenotch://run/calc.exe"))
        self.assertIsNone(u.parse("https://settings/privacy"))
        self.assertIsNone(u.parse("claudenotch://"))
        self.assertIsNone(u.parse("claudenotch://" + "a" * 600))
        self.assertIsNone(u.parse(None))

    def test_command_line(self):
        self.assertEqual(u.command_line("C:\\A B\\ClaudeNotch.exe"), '"C:\\A B\\ClaudeNotch.exe" --url "%1"')


if __name__ == "__main__":
    unittest.main()
