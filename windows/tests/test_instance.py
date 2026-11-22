import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from claudenotch_win import instance  # noqa: E402


class DecideTests(unittest.TestCase):
    def test_nothing_running_starts(self):
        self.assertEqual(instance.decide(None, "0.45.0"), instance.START)

    def test_same_version_shows_the_running_copy(self):
        self.assertEqual(instance.decide("0.45.0", "0.45.0"), instance.SHOW)

    def test_any_other_version_is_replaced_by_this_launch(self):
        self.assertEqual(instance.decide("0.44.0", "0.45.0"), instance.TAKE_OVER)
        self.assertEqual(instance.decide("", "0.45.0"), instance.TAKE_OVER)
        self.assertEqual(instance.decide("0.46.0", "0.45.0"), instance.TAKE_OVER)


@unittest.skipUnless(sys.platform == "win32", "named mutexes are Windows-only")
class MutexTests(unittest.TestCase):
    def test_second_holder_sees_the_first(self):
        name = "Local\\ClaudeNotchTest-%d" % os.getpid()
        a = instance.SingleInstance(name)
        b = instance.SingleInstance(name)
        try:
            self.assertTrue(a.acquired)
            self.assertFalse(b.acquired)
        finally:
            b.release()
            a.release()


if __name__ == "__main__":
    unittest.main()
