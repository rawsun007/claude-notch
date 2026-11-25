import json
import unittest

from claudenotch import modelswitch as ms


class ModelSwitchTests(unittest.TestCase):
    def test_families_not_versions(self):
        self.assertTrue(ms.is_upgrade("claude-sonnet-5-5", "claude-opus-5-5"))
        self.assertTrue(ms.is_upgrade("claude-opus-5-5", "claude-fable-5-2"))
        self.assertFalse(ms.is_upgrade("claude-opus-4-8", "claude-opus-5-5"))      # a version bump
        self.assertFalse(ms.is_upgrade("claude-opus-5-5", "claude-sonnet-5-5"))    # down
        self.assertFalse(ms.is_upgrade("", "claude-opus-5-5"))                      # unknown origin
        self.assertFalse(ms.is_upgrade("claude-sonnet-5-5", "gpt-5"))               # unknown family
        self.assertEqual(ms.family("claude-mythos-1"), "Mythos")

    def test_reply_bodies(self):
        self.assertEqual(ms.reply("ask"), '{"ok":true}')
        allow = json.loads(ms.reply("allow"))["hookSpecificOutput"]
        self.assertEqual((allow["hookEventName"], allow["permissionDecision"]), ("PreModelSwitch", "allow"))
        deny = json.loads(ms.reply("deny", "too pricey"))["hookSpecificOutput"]
        self.assertEqual(deny["permissionDecisionReason"], "too pricey")

    def test_drift_only_for_a_drop(self):
        self.assertEqual(ms.drift("claude-opus-5-5", "claude-sonnet-5-5"), ("Opus", "Sonnet"))
        self.assertIsNone(ms.drift("claude-sonnet-5-5", "claude-opus-5-5"))
        self.assertIsNone(ms.drift("claude-opus-4-8", "claude-opus-5-5"))
        self.assertIsNone(ms.drift("", "claude-haiku-4-5"))
        self.assertIsNone(ms.drift("claude-opus-5-5", "some-new-model"))
        self.assertEqual(ms.drift_title(("Opus", "Sonnet")), "This session is now on Sonnet, not Opus")
        self.assertIn("Either you switched it, or your plan moved it", ms.drift_detail(("Opus", "Sonnet")))

    def test_detail(self):
        self.assertIn(" to ", ms.switch_detail("claude-sonnet-5-5", "claude-opus-5-5"))
        self.assertTrue(ms.switch_detail("", "claude-opus-5-5"))


class _Server:
    """Just enough of HookServer to run answer() without a socket."""

    def __init__(self, state, window=2.0):
        import threading
        from claudenotch.server import HookServer
        self.state, self.window, self.paused = state, window, threading.Event()
        self.answer = HookServer.answer.__get__(self)
        self._model_gate = HookServer._model_gate.__get__(self)


class GateTests(unittest.TestCase):
    def setUp(self):
        from claudenotch.state import AllowRule, AppState
        self.st = AppState(persist=False)
        self.st.rules = [AllowRule("PreModelSwitch", "")]
        self.st.approver = lambda c: "allow"                       # Auto-Approve on: must not apply
        self.up = {"hook_event_name": "PreModelSwitch", "session_id": "s", "cwd": "/p",
                   "from_model": "claude-sonnet-5-5", "to_model": "claude-opus-5-5"}

    def test_off_by_default_and_never_for_a_downgrade(self):
        srv = _Server(self.st)
        self.assertEqual(srv.answer(self.up), '{"ok":true}')
        self.st.gate_model_upgrades = True
        down = dict(self.up, from_model="claude-opus-5-5", to_model="claude-sonnet-5-5")
        self.assertEqual(srv.answer(down), '{"ok":true}')
        self.assertEqual(self.st.permissions, [])

    def test_an_upgrade_waits_for_the_card(self):
        import threading
        self.st.gate_model_upgrades = True
        srv = _Server(self.st)
        out = []
        t = threading.Thread(target=lambda: out.append(srv.answer(self.up)))
        t.start()
        for _ in range(100):
            if self.st.permissions:
                break
            import time
            time.sleep(0.01)
        card = self.st.permissions[0]
        self.assertEqual((card.title, card.tool), ("Switch to a pricier model?", "PreModelSwitch"))
        self.st.resolve_permission(card.id, "deny", reason="stay on sonnet")
        t.join(2)
        body = json.loads(out[0])["hookSpecificOutput"]
        self.assertEqual((body["permissionDecision"], body["permissionDecisionReason"]), ("deny", "stay on sonnet"))

    def test_nobody_answering_lets_it_through(self):
        self.st.gate_model_upgrades = True
        self.assertEqual(_Server(self.st, window=0.05).answer(self.up), '{"ok":true}')

    def test_switched_card_and_drift(self):
        from claudenotch import statusline
        st = self.st
        ev = {"hook_event_name": "PostModelSwitch", "session_id": "s", "cwd": "/p",
              "from_model": "claude-sonnet-5-5", "to_model": "claude-opus-5-5"}
        st.handle_event(ev)
        st.handle_event(ev)                                         # reported twice: one card
        self.assertEqual([t.title for t in st.toasts if t.kind == "model"], ["Model switched"])
        self.assertEqual(st.sessions["s"].model, "claude-opus-5-5")
        st.note_status(statusline.parse(statusline.flatten({"session_id": "s", "model": {"id": "claude-sonnet-5-5"},
                                                            "cost": {"total_cost_usd": 1.0}})))
        drift = [t for t in st.toasts if t.title.startswith("This session is now on")]
        self.assertEqual([t.title for t in drift], ["This session is now on Sonnet, not Opus"])


if __name__ == "__main__":
    unittest.main()
