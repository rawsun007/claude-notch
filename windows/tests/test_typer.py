import sys
import unittest

from claudenotch_win import typer


class TyperTests(unittest.TestCase):
    def test_unicode_units_then_enter(self):
        ev = typer.key_events("hé🙂")
        units = [scan for vk, scan, flags in ev if flags == typer.KEYEVENTF_UNICODE]
        self.assertEqual(units, [ord("h"), ord("é"), 0xD83D, 0xDE42])          # the emoji as a surrogate pair
        self.assertEqual(ev[-2:], [(typer.VK_RETURN, 0, 0), (typer.VK_RETURN, 0, typer.KEYEVENTF_KEYUP)])
        self.assertEqual(len(ev), 2 * 4 + 2)

    def test_refuses_without_a_terminal(self):
        self.assertEqual(typer.type_into(0, "hi"), "That terminal is gone. Pick a project instead to open a fresh one.")
        self.assertEqual(typer.type_into(0, " \n "), "Nothing to send.")
        self.assertFalse(typer.usable(0))

    @unittest.skipUnless(sys.platform == "win32", "Windows")
    def test_never_an_editor_or_this_process(self):
        import ctypes
        desktop = ctypes.windll.user32.GetDesktopWindow()
        self.assertFalse(typer.usable(desktop))          # explorer/desktop: not a terminal
        self.assertNotEqual(typer.type_into(desktop, "hi"), None)


if __name__ == "__main__":
    unittest.main()
