import os
import sys
import unittest
from types import SimpleNamespace as S

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

try:
    import PySide6  # noqa: F401
    HAVE_QT = True
except ImportError:
    HAVE_QT = False


@unittest.skipUnless(HAVE_QT, "needs PySide6")
class FreshItemsTests(unittest.TestCase):
    def test_off_by_default_and_each_card_once(self):
        from claudenotch_win.notify import fresh_items
        seen = set()
        perms = [S(id=1, title="Bash", detail="npm test", dangers=[]),
                 S(id=2, title="Bash", detail="rm -rf x", dangers=["rm -rf"])]
        self.assertEqual(fresh_items(perms, [], seen, False, False), [])
        self.assertEqual(fresh_items(perms, [], seen, True, False), [])   # already seen

    def test_dangerous_only(self):
        from claudenotch_win.notify import fresh_items
        perms = [S(id=1, title="Bash", detail="npm test", dangers=[]),
                 S(id=2, title="Bash", detail="rm -rf x", dangers=["rm -rf"])]
        items = fresh_items(perms, [], set(), False, True)
        self.assertEqual(items, [("Claude wants to use Bash", "rm -rf x", True)])


if __name__ == "__main__":
    unittest.main()
