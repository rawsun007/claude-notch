import os
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

try:
    from PySide6.QtWidgets import QApplication
    HAVE_QT = True
except ImportError:
    HAVE_QT = False


@unittest.skipUnless(HAVE_QT, "needs PySide6")
class UpdaterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def test_newer_windows_release_is_offered_and_only_on_github(self):
        from claudenotch_win import updater
        from claudenotch_win.overlay import Overlay
        from claudenotch_win.tray import Tray
        from claudenotch.state import AppState
        u = updater.Updater()
        offered, results = [], []
        u.available.connect(lambda v, p: offered.append((v, p)))
        u.finished.connect(results.append)
        page = "https://github.com/rawsun007/claude-notch/releases/tag/windows-v9.0.0"
        u._apply([{"tag_name": "windows-v9.0.0", "html_url": page}, {"tag_name": "v99.0.0"}], True)
        u._apply(None, True)
        self.assertEqual(offered, [("9.0.0", page)])
        self.assertEqual(results, ["update", "failed"])

        class Store:
            value = type("v", (), {"show_pill": True})()

            def subscribe(self, f):
                pass

        tray = Tray(Overlay(AppState(persist=False)), Store(), on_settings=lambda: None, on_quit=lambda: None)
        tray.showMessage = lambda *a, **k: None
        tray.show_update("9.0.0", "https://evil.example/x")
        self.assertFalse(tray.update_action.isVisible())
        tray.show_update("9.0.0", page)
        self.assertTrue(tray.update_action.isVisible())
        self.assertEqual(tray.update_action.text(), "Update available: 9.0.0")


if __name__ == "__main__":
    unittest.main()
