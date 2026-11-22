import os
import tempfile
import unittest
from unittest import mock

from claudenotch import fsutil


class ReplaceTests(unittest.TestCase):
    def test_retries_while_another_process_holds_the_file(self):
        real = os.replace
        calls = []

        def flaky(src, dst):
            calls.append(1)
            if len(calls) <= 2:
                raise PermissionError(13, "in use")
            real(src, dst)

        with tempfile.TemporaryDirectory() as d:
            src, dst = os.path.join(d, "a.tmp"), os.path.join(d, "a")
            open(src, "w").close()
            with mock.patch.object(fsutil.os, "replace", flaky):
                fsutil.replace(src, dst, pause=0)
            self.assertTrue(os.path.exists(dst))
        self.assertEqual(len(calls), 3)

    def test_gives_up_after_the_last_try(self):
        with mock.patch.object(fsutil.os, "replace", side_effect=PermissionError(13, "in use")) as m:
            with self.assertRaises(PermissionError):
                fsutil.replace("a", "b", tries=3, pause=0)
        self.assertEqual(m.call_count, 3)

    def test_other_errors_are_not_retried(self):
        with mock.patch.object(fsutil.os, "replace", side_effect=FileNotFoundError()) as m:
            with self.assertRaises(FileNotFoundError):
                fsutil.replace("a", "b", pause=0)
        self.assertEqual(m.call_count, 1)


if __name__ == "__main__":
    unittest.main()
