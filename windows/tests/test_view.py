import os
import sys
import unittest
from types import SimpleNamespace as S

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from claudenotch_win import view  # noqa: E402


class PlaceTests(unittest.TestCase):
    def test_top_centre_hangs_from_the_work_area(self):
        self.assertEqual(view.place("top", (0, 0, 1920, 1032), 240, 30), (840, 0))
        # Taskbar docked at the top: the work area starts below it.
        self.assertEqual(view.place("top", (0, 48, 1920, 1032), 240, 30), (840, 48))
        # Second monitor to the left.
        self.assertEqual(view.place("top", (-1280, 0, 1280, 984), 240, 30), (-1280 + 520, 0))

    def test_bottom_right_sits_above_the_tray(self):
        self.assertEqual(view.place("bottom-right", (0, 0, 1920, 1032), 240, 30), (1920 - 252, 1032 - 42))

    def test_bottom_right_never_leaves_the_work_area(self):
        self.assertEqual(view.place("bottom-right", (0, 0, 200, 100), 600, 400), (0, 0))


class SummaryTests(unittest.TestCase):
    def s(self, status, project="proj"):
        return S(status=status, project=project, agents=0)

    def test_summaries(self):
        self.assertEqual(view.summary([]), ("ClaudeNotch", "ready"))
        self.assertEqual(view.summary([self.s("working")]), ("proj working", "working"))
        self.assertEqual(view.summary([self.s("working"), self.s("ready")]), ("1 of 2 working", "working"))
        self.assertEqual(view.summary([self.s("waiting"), self.s("working")]), ("1 waiting on you", "waiting"))
        self.assertEqual(view.summary([self.s("ready"), self.s("ready")]), ("2 sessions ready", "ready"))

    def test_session_note(self):
        self.assertEqual(view.session_note(S(status="working", agents=2)), "working · 2 agents")
        self.assertEqual(view.session_note(S(status="ready", agents=0)), "ready")


class CardTests(unittest.TestCase):
    def test_headings(self):
        self.assertEqual(view.permission_heading(S(tool="PowerShell", title="PowerShell")),
                         "Claude wants to run PowerShell")
        self.assertEqual(view.permission_heading(S(tool="Edit", title="Edit main.py")),
                         "Claude wants to use Edit main.py")
        self.assertEqual(view.tail("proj", 2), "proj · +2 more")
        self.assertEqual(view.tail("", 0), "")

    def test_diff_rows_are_cut(self):
        rows = view.diff_rows("a\nb", "\n".join(str(i) for i in range(20)), limit=3)
        self.assertEqual(rows[:2], [("del", "- a"), ("del", "- b")])
        self.assertEqual(rows[-1], ("more", "  …"))
        self.assertEqual(len(rows), 2 + 3 + 1)

    def test_allow_label(self):
        self.assertEqual(view.allow_label(False, False), "Allow  ⏎")
        self.assertEqual(view.allow_label(True, False), "Allow anyway")
        self.assertEqual(view.allow_label(True, True), "Click again to allow")


class ChooseTests(unittest.TestCase):
    def test_order(self):
        # AppState.recompute: question, permission, completed, then idle.
        self.assertEqual(view.choose([1], [1], [1], True, True), view.QUESTION)
        self.assertEqual(view.choose([1], [], [1], True, True), view.PERMISSION)
        self.assertEqual(view.choose([], [], [1], True, True), view.TOAST)
        self.assertEqual(view.choose([], [], [], True, True), view.SESSIONS)
        self.assertEqual(view.choose([], [], [], True, False), view.PILL)
        # The Auto-allowed card: after done cards, ahead of the hover card.
        self.assertEqual(view.choose([], [], [], True, True, auto_info=1), view.AUTO)
        self.assertEqual(view.choose([], [], [1], True, True, auto_info=1), view.TOAST)
        self.assertEqual(view.choose([], [], [], False, True), view.PILL)

    def test_only_the_idle_pill_hides(self):
        self.assertFalse(view.visible(view.PILL, True, True, True))
        self.assertTrue(view.visible(view.PILL, True, True, False))
        self.assertFalse(view.visible(view.PILL, False, False, True))
        self.assertTrue(view.visible(view.PERMISSION, False, True, True))
        self.assertTrue(view.visible(view.TOAST, True, True, True))


if __name__ == "__main__":
    unittest.main()
