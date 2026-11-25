import os
import tempfile
import unittest
from unittest import mock

from claudenotch_win import macsounds, soundplay

from test_soundplay import _aiff


class MacSoundsTests(unittest.TestCase):
    def test_only_real_aiff_under_the_cap_is_kept(self):
        self.assertTrue(macsounds.check(_aiff()[0]))
        self.assertFalse(macsounds.check(b"<html>404</html>"))
        self.assertFalse(macsounds.check(b""))
        self.assertFalse(macsounds.check(b"FORM" + b"\0" * (macsounds.MAX_BYTES + 10)))

    def test_download_keeps_good_files_and_skips_what_it_has(self):
        good = _aiff()[0]

        class Resp:
            def __init__(self, data):
                self.data = data

            def read(self, n):
                return self.data[:n]

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def fake(req, timeout=0):
            return Resp(b"not a sound" if "Frog" in req.full_url else good)

        with tempfile.TemporaryDirectory() as d, mock.patch.object(soundplay, "user_dir", lambda: d), \
                mock.patch("urllib.request.urlopen", side_effect=fake) as opener:
            n, failed = macsounds.download()
            self.assertEqual((n, failed), (len(macsounds.NAMES) - 1, ["Frog"]))
            self.assertFalse(os.path.exists(os.path.join(d, "Frog.aiff")))
            calls = opener.call_count
            macsounds.download()
            self.assertEqual(opener.call_count, calls + 1)              # only Frog is tried again
            self.assertTrue(soundplay.path("Glass").endswith(os.path.join(".converted", "Glass.wav")))


if __name__ == "__main__":
    unittest.main()
