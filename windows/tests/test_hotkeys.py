import unittest

from claudenotch_win import hotkeys as hk


class HotkeyTests(unittest.TestCase):
    def test_the_macs_shortcuts_with_ctrl_alt(self):
        self.assertEqual(hk.parse(hk.SETTINGS_DEFAULT), (hk.MOD_CONTROL | hk.MOD_ALT, 0xBC))
        self.assertEqual(hk.parse(hk.NOTCH_DEFAULT), (hk.MOD_CONTROL | hk.MOD_ALT, ord("N")))
        self.assertEqual(hk.parse("win+shift+f5"), (hk.MOD_WIN | hk.MOD_SHIFT, 0x74))
        self.assertEqual(hk.parse("Ctrl+Alt++"), (hk.MOD_CONTROL | hk.MOD_ALT, 0xBB))
        self.assertEqual(hk.parse(hk.HISTORY_DEFAULT), (hk.MOD_CONTROL | hk.MOD_ALT, 0x20))
        self.assertEqual(hk.label("ctrl+alt+space"), "Ctrl+Alt+Space")

    def test_rejects_what_would_steal_typing_or_is_not_a_key(self):
        for bad in ("", "N", "Shift+N", "Ctrl+", "Ctrl+Ctrl+N", "Ctrl+Hyper+N", "Ctrl+Alt+Enterprise", None, "Ctrl+F25"):
            self.assertIsNone(hk.parse(bad), bad)

    def test_label(self):
        self.assertEqual(hk.label("ctrl+alt+n"), "Ctrl+Alt+N")
        self.assertEqual(hk.label("Ctrl+Alt+,"), "Ctrl+Alt+,")
        self.assertEqual(hk.label("nope"), "")

    def test_fire_calls_only_registered(self):
        h = hk.GlobalHotkeys()
        got = []
        h._callbacks[7] = lambda: got.append(7)
        self.assertTrue(h.fire(7))
        self.assertFalse(h.fire(8))
        self.assertEqual(got, [7])


if __name__ == "__main__":
    unittest.main()
