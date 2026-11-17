import os
import tempfile
import unittest

from claudenotch.upgrade import QUIT, RESTART, decide, installed_version, parse


class UpgradeTests(unittest.TestCase):
    def test_reads_the_version_on_disk(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "__init__.py")
            with open(p, "w") as f:
                f.write('"""doc"""\n# comment\n__version__ = "0.44.0"\n')
            self.assertEqual(installed_version(p), "0.44.0")
            self.assertIsNone(installed_version(os.path.join(d, "nope.py")))

    def test_a_new_version_on_disk_restarts(self):
        self.assertEqual(decide("0.43.1", "0.44.0", 0), RESTART)
        self.assertEqual(decide("0.44.0", "0.43.1", 0), RESTART)   # a chosen downgrade too
        self.assertIsNone(decide("0.44.0", "0.44.0", 0))

    def test_missing_files_mean_uninstalled_only_after_a_while(self):
        self.assertIsNone(decide("0.44.0", None, 1))   # mid-upgrade
        self.assertEqual(decide("0.44.0", None, 3), QUIT)

    def test_parse(self):
        self.assertGreater(parse("0.44.0"), parse("0.43.10")[:1] + (43, 9))
        self.assertGreater(parse("0.43.10"), parse("0.43.9"))
        self.assertEqual(parse("garbage"), (0,))


if __name__ == "__main__":
    unittest.main()
