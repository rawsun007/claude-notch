import sys
import unittest

from claudenotch import sounds

from claudenotch_win import soundplay


class SoundPlayTests(unittest.TestCase):
    def test_names_cannot_leave_the_media_folder(self):
        self.assertIsNone(soundplay.path("..\\..\\evil"))
        self.assertIsNone(soundplay.path("a/b"))
        self.assertIsNone(soundplay.path("C:evil"))
        self.assertIsNone(soundplay.path(""))
        self.assertFalse(soundplay.play(None))
        self.assertFalse(soundplay.play("No Such Sound"))

    def test_every_mac_sound_ships_with_the_app(self):
        self.assertEqual(soundplay.available(sounds.CHOICES), list(sounds.CHOICES))
        names = [d for _, _, _, d in sounds.EVENTS if d] + [d for *_, d in sounds.CATEGORIES]
        self.assertEqual(soundplay.available(names), names)

    def test_the_users_own_copy_wins(self):
        import os
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as d, mock.patch.object(soundplay, "user_dir", lambda: d):
            mine = os.path.join(d, "Funk.wav")
            open(mine, "wb").close()
            self.assertEqual(soundplay.path("Funk"), mine)
            self.assertNotEqual(soundplay.path("Pop"), None)


if __name__ == "__main__":
    unittest.main()
