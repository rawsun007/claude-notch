import unittest

from claudenotch.layout import card_origin


class CardOriginTests(unittest.TestCase):
    def test_hangs_below_a_top_bar(self):
        # Ubuntu: 1440x900 monitor, 32 px GNOME top bar.
        self.assertEqual(card_origin((0, 0, 1440, 900), (0, 32, 1440, 868), 600), (420, 32))

    def test_centred_on_the_monitor_not_the_work_area(self):
        # A dock down the left edge narrows the work area; the card still
        # centres on the screen.
        self.assertEqual(card_origin((0, 0, 1440, 900), (64, 32, 1376, 868), 600), (420, 32))

    def test_no_panel_means_the_very_top(self):
        self.assertEqual(card_origin((0, 0, 1440, 900), (0, 0, 1440, 900), 240), (600, 0))
        self.assertEqual(card_origin((0, 0, 1440, 900), None, 240), (600, 0))

    def test_second_monitor_offsets(self):
        self.assertEqual(card_origin((1440, 0, 1920, 1080), (1440, 27, 1920, 1053), 600), (2100, 27))

    def test_a_nonsense_work_area_is_ignored(self):
        self.assertEqual(card_origin((0, 0, 1440, 900), (0, 0, 0, 0), 600), (420, 0))
        self.assertEqual(card_origin((0, 0, 1440, 900), (0, 800, 1440, 100), 600), (420, 0))


if __name__ == "__main__":
    unittest.main()
