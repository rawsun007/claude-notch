import os
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from claudenotch_win import settingskit as kit  # noqa: E402

ITEMS = [
    kit.SearchItem("Launch at login", "startup boot open", "general"),
    kit.SearchItem("Hide from screen capture", "recording screenshot privacy", "privacy"),
    kit.SearchItem("Require Windows Hello", "biometric fingerprint face pin", "privacy"),
    kit.SearchItem("Auto-approve permissions", "allow automatic bypass", "general"),
]


class SearchTests(unittest.TestCase):
    def test_every_word_must_match(self):
        self.assertEqual([i.title for i in kit.search(ITEMS, "screen")], ["Hide from screen capture"])
        self.assertEqual([i.title for i in kit.search(ITEMS, "fingerprint hello")], ["Require Windows Hello"])
        self.assertEqual(kit.search(ITEMS, "screen boot"), [])
        self.assertEqual(kit.search(ITEMS, "   "), [])

    def test_titles_starting_with_the_query_come_first(self):
        hits = kit.search(ITEMS + [kit.SearchItem("Auto-approve for a while", "timed", "session")], "auto")
        self.assertEqual(hits[0].title, "Auto-approve for a while")


class ThemeTests(unittest.TestCase):
    def test_both_themes(self):
        self.assertTrue(kit.theme(True).dark)
        self.assertFalse(kit.theme(False).dark)
        self.assertIn(kit.windows_dark_mode(), (True, False))


class WidgetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from PySide6.QtWidgets import QApplication
        cls.app = QApplication.instance() or QApplication([])

    def test_switch_and_rows_build(self):
        t = kit.theme(True)
        s = kit.Switch(t)
        heard = []
        s.toggled.connect(heard.append)
        s.set_quietly(True)
        self.assertTrue(s.isChecked())
        self.assertEqual(heard, [])            # matching a setting is not a click
        s.click()
        self.assertEqual(heard, [False])
        card = kit.Card(t)
        card.add(kit.Row(t, "Title", "Caption <b>not html</b>", kit.Switch(t)))
        card.add(kit.Row(t, "Second"))
        self.assertEqual(card.lay.count(), 3)  # row, divider, row
        row = card.lay.itemAt(0).widget()
        self.assertEqual(row.subtitle.textFormat(), __import__("PySide6.QtCore", fromlist=["Qt"]).Qt.PlainText)


class ColourTests(WidgetTests):
    def test_a_disabled_button_never_dims_the_theme(self):
        t = kit.theme(False)
        before = t.text.alphaF()
        b = kit.PushButton(t, "Stop")
        b.setEnabled(False)
        b.resize(80, 26)
        b.grab()                        # paints it
        self.assertEqual(t.text.alphaF(), before)


if __name__ == "__main__":
    unittest.main()
