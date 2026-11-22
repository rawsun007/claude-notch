import unittest

from claudenotch import autoapprove as aa


class VerdictTests(unittest.TestCase):
    def test_off_or_out_of_scope_shows_the_card(self):
        self.assertEqual(aa.verdict(False, aa.EVERYTHING, aa.ASK, "Bash", False), aa.SHOW_CARD)
        self.assertEqual(aa.verdict(True, aa.FILES, aa.ASK, "Bash", False), aa.SHOW_CARD)
        self.assertEqual(aa.verdict(True, aa.COMMANDS, aa.ASK, "Edit", False), aa.SHOW_CARD)

    def test_in_scope_and_safe_is_allowed(self):
        self.assertEqual(aa.verdict(True, aa.EVERYTHING, aa.ASK, "WebFetch", False), aa.ALLOW)
        self.assertEqual(aa.verdict(True, aa.COMMANDS, aa.ASK, "PowerShell", False), aa.ALLOW)
        self.assertEqual(aa.verdict(True, aa.FILES, aa.ASK, "Edit", False), aa.ALLOW)

    def test_destructive_follows_the_choice(self):
        self.assertEqual(aa.verdict(True, aa.EVERYTHING, aa.ASK, "Bash", True), aa.SHOW_CARD)
        self.assertEqual(aa.verdict(True, aa.EVERYTHING, aa.CONFIRM, "Bash", True), aa.CONFIRM_NOW)
        self.assertEqual(aa.verdict(True, aa.EVERYTHING, aa.ALLOW_TOO, "Bash", True), aa.ALLOW)

    def test_strict_mode_wins_over_everything(self):
        self.assertEqual(aa.verdict(True, aa.EVERYTHING, aa.ALLOW_TOO, "Bash", True, strict_blocks=True),
                         aa.SHOW_CARD)

    def test_authentication_only_to_start_allowing_destructive(self):
        self.assertTrue(aa.needs_authentication(aa.ASK, aa.ALLOW_TOO))
        self.assertTrue(aa.needs_authentication(aa.CONFIRM, aa.ALLOW_TOO))
        self.assertFalse(aa.needs_authentication(aa.ALLOW_TOO, aa.ALLOW_TOO))
        self.assertFalse(aa.needs_authentication(aa.ALLOW_TOO, aa.ASK))

    def test_timed_window(self):
        self.assertTrue(aa.active(True, None, 100))
        self.assertTrue(aa.active(True, 200, 100))
        self.assertFalse(aa.active(True, 50, 100))
        self.assertFalse(aa.active(False, None, 100))

    def test_labels_have_no_em_dash(self):
        for d in (aa.SCOPE_LABELS, aa.DANGEROUS_LABELS):
            for title, note in d.values():
                self.assertNotIn("—", title + note)


if __name__ == "__main__":
    unittest.main()
