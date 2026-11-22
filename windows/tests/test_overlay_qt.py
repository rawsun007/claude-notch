"""Smoke test of the real Qt overlay, offscreen: every view builds, the
buttons answer the hook, and the dangerous two-click rule holds. Skipped
where PySide6 is not installed."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

try:
    from PySide6.QtWidgets import QApplication
    HAVE_QT = True
except ImportError:
    HAVE_QT = False

from claudenotch import protocol  # noqa: E402
from claudenotch.state import AppState, PermissionCard, QuestionCard  # noqa: E402


@unittest.skipUnless(HAVE_QT, "needs PySide6")
class OverlayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        from claudenotch_win.overlay import Overlay
        self.state = AppState(persist=False)
        self.overlay = Overlay(self.state)
        self.app.processEvents()

    def tearDown(self):
        self.overlay.close()
        self.overlay.deleteLater()
        self.app.processEvents()

    def perm(self, command="npm test", tool="PowerShell"):
        got = []
        card = PermissionCard(tool, {"command": command}, "C:\\Users\\a\\proj", protocol.PERMISSION, "s1",
                              resolve=lambda d, r: got.append(d))
        self.state.enqueue_permission(card)
        self.app.processEvents()
        return card, got

    def test_the_idle_pill_shows(self):
        self.assertEqual(self.overlay._view, "pill")
        self.assertTrue(self.overlay.isVisible())
        self.assertGreater(self.overlay.width(), 100)

    def test_allow_answers_the_hook(self):
        card, got = self.perm()
        self.assertEqual(self.overlay._view, "perm")
        self.assertIn("always", self.overlay.buttons)
        self.overlay.buttons["allow"].click()
        self.app.processEvents()
        self.assertEqual(got, ["allow"])
        self.assertEqual(self.overlay._view, "pill")

    def test_deny(self):
        card, got = self.perm()
        self.overlay.buttons["deny"].click()
        self.assertEqual(got, ["deny"])

    def test_dangerous_needs_two_clicks_and_has_no_always_allow(self):
        card, got = self.perm("Remove-Item C:\\proj -Recurse -Force")
        self.assertTrue(card.dangers)
        self.assertNotIn("always", self.overlay.buttons)
        self.overlay.buttons["allow"].click()
        self.app.processEvents()
        self.assertEqual(got, [])
        self.assertEqual(self.overlay.buttons["allow"].text(), "Click again to allow")
        self.overlay.buttons["allow"].click()
        self.assertEqual(got, ["allow"])

    def test_payload_text_is_never_rendered_as_html(self):
        from PySide6.QtCore import Qt
        from PySide6.QtWidgets import QLabel
        self.perm("<b>bold</b><img src=x>")
        labels = self.overlay.findChildren(QLabel)
        self.assertTrue(labels)
        self.assertTrue(all(lbl.textFormat() == Qt.PlainText for lbl in labels if "<b>" in lbl.text()))
        self.assertTrue(any("<b>bold</b>" in lbl.text() for lbl in labels))

    def test_question_card_sends_the_picked_option(self):
        got = []
        q = protocol.Question("Pick", "Which one?", False, [("Alpha", "first"), ("Beta", "")])
        self.state.enqueue_question(QuestionCard([q], "C:\\proj", "s1", resolve=lambda a: got.append(a)))
        self.app.processEvents()
        self.assertEqual(self.overlay._view, "question")
        self.overlay.buttons["q0o1"].setChecked(True)
        self.overlay.buttons["send"].click()
        self.assertEqual(got, [[["Beta"]]])

    def test_session_list_on_hover(self):
        self.state.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": "s1",
                                 "cwd": "C:\\Users\\a\\proj", "prompt": "fix the build"})
        self.overlay.hovering = True
        self.overlay.render()
        self.assertEqual(self.overlay._view, "sessions")

    def test_toast_then_pill(self):
        self.state.greet(version="0.45.0")
        self.app.processEvents()
        self.assertEqual(self.overlay._view, "toast")


if __name__ == "__main__":
    unittest.main()
