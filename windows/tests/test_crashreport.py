import os
import sys
import tempfile
import unittest
from unittest import mock

from claudenotch_win import crashreport as cr


class CrashReportTests(unittest.TestCase):
    def test_report_has_version_thread_and_traceback(self):
        try:
            raise ValueError("boom")
        except ValueError:
            text = cr.report_text(*sys.exc_info(), thread="server")
        self.assertIn("ClaudeNotch", text)
        self.assertIn("Thread: server", text)
        self.assertIn("ValueError: boom", text)

    def test_keeps_the_newest_ten(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(cr, "folder", lambda: d):
            for i in range(13):
                open(os.path.join(d, f"crash-2026010{i:02d}.txt"), "w").close()
            open(os.path.join(d, "fatal.txt"), "w").close()
            try:
                raise KeyError("x")
            except KeyError:
                path = cr.write(*sys.exc_info())
            names = sorted(n for n in os.listdir(d) if cr.is_report(n))
            self.assertEqual(len(names), cr.MAX_REPORTS)
            self.assertIn(os.path.basename(path), names)
            self.assertTrue(os.path.exists(os.path.join(d, "fatal.txt")))


if __name__ == "__main__":
    unittest.main()
