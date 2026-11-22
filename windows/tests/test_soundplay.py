import sys
import unittest

from claudenotch import sounds

from claudenotch_win import soundplay


class SoundPlayTests(unittest.TestCase):
    def test_names_cannot_leave_the_media_folder(self):
        self.assertIsNone(soundplay.path("..\\..\\evil"))
        self.assertIsNone(soundplay.path("a/b"))
        self.assertIsNone(soundplay.path(""))
        self.assertFalse(soundplay.play(None))
        self.assertFalse(soundplay.play("No Such Sound"))

    @unittest.skipUnless(sys.platform == "win32", "Windows only")
    def test_defaults_exist_on_windows(self):
        names = [d for _, _, _, d in sounds.EVENTS if d] + [d for *_, d in sounds.CATEGORIES]
        self.assertEqual(soundplay.available(names), names)


if __name__ == "__main__":
    unittest.main()
