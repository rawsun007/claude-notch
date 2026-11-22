import unittest

from claudenotch import limits


class LimitTests(unittest.TestCase):
    def test_levels(self):
        self.assertIsNone(limits.warning_level(0.5, 0))
        self.assertEqual(limits.warning_level(0.81, 0), 0.80)
        self.assertEqual(limits.warning_level(0.97, 0), 0.95)
        self.assertIsNone(limits.warning_level(0.9, 0.80))
        self.assertEqual(limits.warning_level(0.96, 0.80), 0.95)

    def test_countdown_matches_the_mac(self):
        self.assertEqual(limits.reset_countdown(-1), "now")
        self.assertEqual(limits.reset_countdown(41 * 60 + 1), "42m")
        self.assertEqual(limits.reset_countdown(3 * 3600), "3h")
        self.assertEqual(limits.reset_countdown(3 * 3600 + 5 * 60), "3h 5m")
        self.assertEqual(limits.reset_countdown(52 * 3600), "2d 4h")
        self.assertEqual(limits.reset_countdown(48 * 3600), "2d")

    def test_once_per_window_then_rearmed(self):
        a = limits.Armed()
        self.assertEqual(a.check("5-hour", 0.82, 1000, 0),
                         ("80% of your 5-hour limit used", "You are at 82% of the 5-hour plan limit · resets in 17m."))
        self.assertIsNone(a.check("5-hour", 0.85, 1000, 10))
        self.assertEqual(a.check("5-hour", 0.96, 1000, 20)[0], "95% of your 5-hour limit used")
        self.assertIsNone(a.check("5-hour", 0.99, 1000, 30))
        self.assertEqual(a.check("5-hour", 0.81, 9000, 40)[0], "80% of your 5-hour limit used")   # new window


if __name__ == "__main__":
    unittest.main()
