import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from claudenotch_win import winutil  # noqa: E402


class FullscreenTests(unittest.TestCase):
    def test_fullscreen_states_hide_the_pill(self):
        for state, hidden in ((winutil.QUNS_BUSY, True), (winutil.QUNS_RUNNING_D3D_FULL_SCREEN, True),
                              (winutil.QUNS_PRESENTATION_MODE, True), (winutil.QUNS_ACCEPTS_NOTIFICATIONS, False),
                              (winutil.QUNS_QUIET_TIME, False)):
            with mock.patch.object(winutil, "notification_state", return_value=state):
                self.assertEqual(winutil.fullscreen_in_front(), hidden, state)

    @unittest.skipIf(sys.platform == "win32", "checks the off-Windows fallbacks")
    def test_off_windows_everything_is_a_no_op(self):
        winutil.set_no_activate(123)
        winutil.keep_topmost(123)
        self.assertEqual(winutil.foreground_window(), 0)
        self.assertFalse(winutil.fullscreen_in_front())
        self.assertFalse(winutil.system_uses_light_theme())


if __name__ == "__main__":
    unittest.main()
