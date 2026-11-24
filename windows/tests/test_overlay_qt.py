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

    def test_the_session_list_needs_two_sessions(self):
        from claudenotch_win.notchcards import IdleCardView
        self.state.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "C:/w/one",
                                 "prompt": "a"})
        self.overlay.hovering = True
        self.overlay.render()
        self.assertIsNone(self.overlay._content.findChild(IdleCardView).list_view)
        self.state.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": "s2", "cwd": "C:/w/two",
                                 "prompt": "b"})
        self.overlay.render()
        card = self.overlay._content.findChild(IdleCardView)
        self.assertIsNotNone(card.list_view)
        self.assertEqual(len(card.list_view.rows), 1)          # the top session is the header

    def _with_settings(self, **values):
        from types import SimpleNamespace
        defaults = dict(auto_approve=False, auto_approve_scope="everything", auto_approve_dangerous="ask",
                        enforce_budget=False, daily_cost_cap=0.0, session_cost_cap=0.0, limit_warnings=True,
                        keep_open=False, hide_from_capture=False,
                        require_hello=True, skip_destructive_confirm=False, hover_sessions=True, toasts=True,
                        position="top", show_pill=True, hide_in_fullscreen=True)
        defaults.update(values)
        self.overlay.store = SimpleNamespace(value=SimpleNamespace(**defaults), update=lambda **kw: None)

    def test_auto_approve_allows_and_shows_the_auto_allowed_card(self):
        from claudenotch_win.notchcards import AutoInfoCardView
        self._with_settings(auto_approve=True)
        _, got = self.perm("npm test")
        self.assertEqual(got, ["allow"])
        self.assertEqual(self.overlay._view, "auto")
        self.assertIsNotNone(self.overlay._content.findChild(AutoInfoCardView))
        self.state.auto_info_at -= 10                 # past its four seconds
        self.overlay._tick()
        self.app.processEvents()
        self.assertEqual(self.overlay._view, "pill")

    def test_destructive_waits_unless_approve_them_too(self):
        self._with_settings(auto_approve=True)
        _, got = self.perm(r"Remove-Item C:\proj -Recurse -Force")
        self.assertEqual(got, [])
        self.assertEqual(self.overlay._view, "perm")
        self.state.resolve_permission(self.state.permissions[0].id, "deny")
        self._with_settings(auto_approve=True, auto_approve_dangerous="allow")
        _, got = self.perm(r"Remove-Item C:\proj -Recurse -Force")
        self.assertEqual(got, ["allow"])

    def test_scope_commands_leaves_edits_to_the_card(self):
        self._with_settings(auto_approve=True, auto_approve_scope="commands")
        _, got = self.perm("npm test")
        self.assertEqual(got, ["allow"])
        got2 = []
        self.state.enqueue_permission(PermissionCard("Edit", {"file_path": "C:/a.py", "old_string": "a",
                                                              "new_string": "b"}, "C:/p", protocol.PERMISSION,
                                                     "s1", resolve=lambda d, r: got2.append(d)))
        self.assertEqual(got2, [])

    def test_over_budget_holds_the_card_and_raise_saves_the_next_cap(self):
        from types import SimpleNamespace
        saved = {}
        self._with_settings(auto_approve=True, enforce_budget=True, session_cost_cap=5.0, daily_cost_cap=0.0)
        self.overlay.store.update = lambda **kw: saved.update(kw)
        self.state.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "C:/p",
                                 "prompt": "x"})
        self.state.sessions["s1"].cost_usd = 6.2
        _, got = self.perm("npm test")
        self.assertEqual(got, [])                      # Auto-Approve does not answer it
        self.assertIn("raise", self.overlay.buttons)
        self.assertEqual(self.overlay.buttons["raise"].label, "Raise to $10.00")
        self.overlay.buttons["raise"].click()
        self.app.processEvents()
        self.assertEqual(got, ["allow"])
        self.assertEqual(saved, {"session_cost_cap": 10.0})

    def test_sounds_for_a_card_and_for_your_answer(self):
        from unittest import mock
        from claudenotch_win import soundplay
        self._with_settings(sound_muted=False, per_tool_sounds=True, alert_sound="A", sound_events={},
                            sound_tools={"bash": "SHELL"})
        with mock.patch.object(soundplay, "play") as play:
            self.perm("npm test", tool="Bash")
            self.overlay.buttons["deny"].click()
            self.app.processEvents()
        names = [c.args[0] for c in play.call_args_list]
        self.assertEqual(names[0], "SHELL")                       # the per-tool prompt sound
        self.assertIn("Pop", names)                               # dismissed, as on the Mac

    def test_muted_plays_nothing(self):
        from unittest import mock
        from claudenotch_win import soundplay
        self._with_settings(sound_muted=True, per_tool_sounds=False, alert_sound="A", sound_events={},
                            sound_tools={})
        with mock.patch.object(soundplay, "play") as play:
            self.perm("npm test")
        self.assertTrue(all(c.args[0] is None for c in play.call_args_list))

    def test_pet_limbs_follow_the_rig(self):
        from PySide6.QtGui import QColor, QImage, QPainter
        from claudenotch_win import notchwidgets as nw, petengine as pe

        def shot(rig):
            img = QImage(64, 64, QImage.Format_ARGB32)
            img.fill(QColor(0, 0, 0, 0))
            p = QPainter(img)
            nw.draw_pet(p, 32, 32, 64, None, rig=rig)
            p.end()
            return img

        still = shot(pe.rig("peek", 0.5, 1.0))
        up = shot(pe.rig("celebrate", 1 / 6, 0.0))           # arms at 70 degrees
        asleep = shot(pe.rig("sleep", 0.5, 10.0))
        # Arms up: coral beside the head (grid x 1, y 6.5), none there at rest.
        self.assertEqual(still.pixelColor(6, 26).alpha(), 0)
        self.assertGreater(up.pixelColor(6, 26).alpha(), 0)
        # Asleep: legs tucked away, eyes nearly shut.
        self.assertEqual(asleep.pixelColor(13, 49).alpha(), 0)
        self.assertGreater(still.pixelColor(13, 49).alpha(), 0)
        self.assertNotEqual(asleep.pixelColor(18, 21), still.pixelColor(18, 21))

    def test_pet_badges_show_only_with_pet_mode(self):
        from claudenotch_win import notchwidgets as nw
        for on in (False, True):
            self._with_settings(pet_enabled=on)
            self.perm(r"Remove-Item -Recurse -Force C:\proj")
            self.app.processEvents()
            self.assertEqual(bool(self.overlay.findChildren(nw.PetBadge)), on)

    def test_pet_badge_dances_and_follows_its_slot(self):
        from PySide6.QtWidgets import QVBoxLayout, QWidget
        from claudenotch_win import notchwidgets as nw
        host = QWidget()
        host.resize(200, 120)
        card = QWidget(host)
        card.setGeometry(40, 30, 100, 60)
        slot = nw.pet_badge_slot(card, 32, loop=3.4, dance=True)
        QVBoxLayout(card).addWidget(slot)
        host.show()
        badge = slot.badge
        badge._tick()
        self.assertIs(badge.parentWidget(), host)            # not clipped by the card
        self.assertTrue(badge.geometry().contains(slot.mapTo(host, slot.rect().center())))
        _, _, dy, pose = badge.frame(3.4 * 0.9)              # the jump
        self.assertLess(dy, 0)
        card.deleteLater()
        self.app.processEvents()
        from PySide6.QtCore import QCoreApplication, QEvent
        for _ in range(2):                                    # the card, then its badge
            QCoreApplication.sendPostedEvents(None, QEvent.DeferredDelete)
            self.app.processEvents()
        self.assertFalse(host.findChildren(nw.PetBadge))
        host.close()

    def test_a_card_too_late_to_answer_only_dismisses(self):
        card, got = self.perm("npm test")
        self.state.drop_permission(card.id)
        self.app.processEvents()
        self.overlay.render()
        self.app.processEvents()
        self.assertEqual(set(self.overlay.buttons), {"dismiss"})
        self.overlay.buttons["dismiss"].click()
        self.app.processEvents()
        self.assertEqual((self.state.permissions, got, self.state.rules), ([], [], []))

    def test_allowed_n_times_beside_always_allow(self):
        for _ in range(3):
            card, _ = self.perm("npm test")
            self.overlay.buttons["allow"].click()
            self.app.processEvents()
        card, _ = self.perm("npm test")
        self.overlay.render()
        self.app.processEvents()
        from claudenotch_win import notchwidgets as nw
        texts = [t._text for t in self.overlay.findChildren(nw.Text)]
        self.assertIn("allowed 3 times", texts)

if __name__ == "__main__":
    unittest.main()
