import unittest

from claudenotch import updatecheck as u


class UpdateCheckTests(unittest.TestCase):
    def test_the_macs_version_rules(self):
        self.assertTrue(u.is_newer("0.2.10", "0.2.9"))
        self.assertFalse(u.is_newer("v1.0.0", "1.0.0"))
        self.assertTrue(u.is_newer("1.2.3-beta", "1.2.2"))
        self.assertFalse(u.is_newer("1.2", "1.2.0"))
        self.assertEqual(u.version_from_tag("windows-v0.45.0", "windows-v"), "0.45.0")
        self.assertIsNone(u.version_from_tag("v0.45.0", "windows-v"))
        self.assertIsNone(u.version_from_tag("windows-vX", "windows-v"))

    def test_newest_for_the_edition(self):
        rel = [
            {"tag_name": "v0.50.0", "html_url": u.PAGE_PREFIX + "tag/v0.50.0"},
            {"tag_name": "windows-v0.46.0", "draft": True},
            {"tag_name": "windows-v0.45.1", "prerelease": True},
            {"tag_name": "windows-v0.45.0", "html_url": "https://evil.example/x"},
            {"tag_name": "windows-v0.44.2", "html_url": u.PAGE_PREFIX + "tag/windows-v0.44.2"},
            "junk",
        ]
        self.assertEqual(u.newest(rel, "windows-v"), ("0.45.0", u.PAGE_PREFIX + "tag/windows-v0.45.0"))
        self.assertEqual(u.available("0.44.0", rel, "windows-v")[0], "0.45.0")
        self.assertIsNone(u.available("0.45.0", rel, "windows-v"))
        self.assertIsNone(u.newest({"message": "rate limited"}, "windows-v"))


if __name__ == "__main__":
    unittest.main()
