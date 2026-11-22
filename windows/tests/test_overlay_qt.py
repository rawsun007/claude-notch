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
from claudenotch.state import AllowRule, AppState, PermissionCard, QuestionCard  # noqa: E402


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

    def test_the_closed_notch_shows(self):
        self.assertEqual(self.overlay._view, "pill")
        self.assertTrue(self.overlay.isVisible())
        self.assertEqual(self.overlay._sizer.size, (200, 28))

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

    def test_dangerous_needs_a_hold_and_has_no_always_allow(self):
        from claudenotch_win.notchwidgets import HoldToConfirmButton
        card, got = self.perm(r"Remove-Item C:\proj -Recurse -Force")
        self.assertTrue(card.dangers)
        self.assertNotIn("always", self.overlay.buttons)
        hold = self.overlay.buttons["allow"]
        self.assertIsInstance(hold, HoldToConfirmButton)
        # Return never allows a dangerous call; only the hold does.
        self.overlay._allow_current()
        self.assertEqual(got, [])
        hold.confirmed.emit()
        self.app.processEvents()
        self.assertEqual(got, ["allow"])

    def test_always_allow_whole_tool_from_the_card(self):
        from claudenotch_win.notchcards import PermissionCardView
        card, got = self.perm("npm run lint")
        self.overlay._content.findChild(PermissionCardView).decided.emit("allow", "tool")
        self.assertEqual(got, ["allow"])
        self.assertIn(AllowRule("PowerShell", ""), self.state.rules)

    def test_allow_all_answers_the_queue(self):
        _, got1 = self.perm("npm test")
        _, got2 = self.perm("npm run build")
        self.assertIn("allow_all", self.overlay.buttons)
        self.overlay.buttons["allow_all"].click()
        self.app.processEvents()
        self.assertEqual((got1, got2), (["allow"], ["allow"]))

    def test_payload_text_is_never_rendered_as_html(self):
        from PySide6.QtCore import Qt
        from PySide6.QtWidgets import QLabel
        from claudenotch_win.notchwidgets import Text
        self.perm("<b>bold</b><img src=x>")
        texts = [t.text() for t in self.overlay.findChildren(Text)]
        self.assertTrue(any("<b>bold</b>" in t for t in texts))
        labels = self.overlay.findChildren(QLabel)
        self.assertTrue(all(lbl.textFormat() == Qt.PlainText for lbl in labels))

    def test_the_card_grows_out_of_the_notch(self):
        self.perm()
        self.assertEqual(self.overlay._sizer.target[0], 620)
        self.overlay._sizer.tick(10.0 + self.overlay._now())
        w, h = self.overlay._sizer.size
        self.assertEqual(w, 620)
        self.assertGreaterEqual(h, 24 + 152)

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


    def test_done_card_waits_until_done(self):
        self.state.handle_event({"hook_event_name": "Stop", "session_id": "s1", "cwd": "C:/w/proj"})
        self.app.processEvents()
        self.assertEqual(self.overlay._view, "toast")
        self.assertIn("dismiss", self.overlay.buttons)
        self.state.toasts[0].created -= 60          # long past the hello's few seconds
        self.overlay._tick()
        self.assertEqual(len(self.state.toasts), 1)
        self.overlay.buttons["dismiss"].click()
        self.app.processEvents()
        self.assertEqual(self.state.toasts, [])
        self.assertEqual(self.overlay._view, "pill")

    def test_open_ide_brings_back_the_window_that_was_in_front(self):
        from unittest import mock
        from claudenotch_win import winutil
        self.overlay._last_foreign = 4242
        with mock.patch.object(winutil, "foreground_window", return_value=0),                 mock.patch.object(winutil, "set_foreground") as fg:
            self.state.handle_event({"hook_event_name": "Notification", "message": "Claude needs input"})
            self.app.processEvents()
            self.overlay.buttons["open"].click()
        fg.assert_called_once_with(4242)
        self.assertEqual(self.state.toasts, [])

    def test_a_question_waits_ahead_of_a_permission(self):
        self.perm()
        q = protocol.Question("", "Which one?", False, [("Alpha", ""), ("Beta", "")])
        self.state.enqueue_question(QuestionCard([q], "C:/proj", "s1"))
        self.app.processEvents()
        self.assertEqual(self.overlay._view, "question")

    def test_question_free_text_replaces_a_single_pick(self):
        from claudenotch_win.notchcards import QuestionCardView
        got = []
        q = protocol.Question("", "Which one?", False, [("Alpha", ""), ("Beta", "")])
        self.state.enqueue_question(QuestionCard([q], "C:/proj", "s1", resolve=lambda a: got.append(a)))
        self.app.processEvents()
        view_ = self.overlay._content.findChild(QuestionCardView)
        self.overlay.buttons["q0o0"].setChecked(True)
        view_.others[0].edit.setText("Gamma")
        self.overlay.buttons["send"].click()
        self.assertEqual(got, [[["Gamma"]]])

if __name__ == "__main__":
    unittest.main()
