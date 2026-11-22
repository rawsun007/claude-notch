import unittest

from claudenotch import protocol
from claudenotch.state import MAX_SESSIONS, AllowRule, AppState, PermissionCard


def card(tool="Bash", command="npm test", answers=None):
    answers = answers if answers is not None else []
    return PermissionCard(tool, {"command": command}, "/home/a/proj", protocol.PERMISSION, "s1",
                          resolve=lambda d, r: answers.append(d))


class PermissionTests(unittest.TestCase):
    def test_a_card_waits_until_answered(self):
        st, got = AppState(persist=False), []
        c = card(answers=got)
        self.assertTrue(st.enqueue_permission(c))
        self.assertEqual(got, [])
        self.assertEqual(st.sessions["s1"].status, "waiting")
        st.resolve_permission(c.id, protocol.ALLOW)
        self.assertEqual(got, ["allow"])
        self.assertEqual(st.permissions, [])

    def test_always_allow_answers_the_next_identical_call(self):
        st = AppState(persist=False)
        first = card()
        st.enqueue_permission(first)
        st.resolve_permission(first.id, protocol.ALLOW, always=True)
        got = []
        self.assertFalse(st.enqueue_permission(card(answers=got)))
        self.assertEqual(got, ["allow"])
        # A different command still asks.
        self.assertTrue(st.enqueue_permission(card(command="npm publish")))

    def test_a_dangerous_call_never_gets_a_rule_and_never_matches_one(self):
        st = AppState(persist=False)
        st.rules = [AllowRule("Bash", "")]          # "allow every Bash call"
        got = []
        self.assertTrue(st.enqueue_permission(card(command="sudo rm -rf /", answers=got)))
        self.assertEqual(got, [])
        c = st.permissions[0]
        st.resolve_permission(c.id, protocol.ALLOW, always=True)
        self.assertNotIn(AllowRule("Bash", "sudo rm -rf /"), st.rules)

    def test_always_allow_the_whole_tool(self):
        st = AppState(persist=False)
        first = card()
        st.enqueue_permission(first)
        st.resolve_permission(first.id, protocol.ALLOW, always=True, scope="tool")
        self.assertIn(AllowRule("Bash", ""), st.rules)
        got = []
        self.assertFalse(st.enqueue_permission(card(command="npm run lint", answers=got)))
        self.assertEqual(got, ["allow"])

    def test_allow_all_skips_dangerous_cards(self):
        st, got = AppState(persist=False), []
        for cmd in ("npm test", "npm run build", "sudo rm -rf /"):
            st.enqueue_permission(card(command=cmd, answers=got))
        st.resolve_all_permissions(protocol.ALLOW)
        self.assertEqual(got, ["allow", "allow"])
        self.assertEqual([c.match_text for c in st.permissions], ["sudo rm -rf /"])
        st.resolve_all_permissions(protocol.DENY)
        self.assertEqual(got, ["allow", "allow", "deny"])

    def test_the_card_is_redacted_but_the_rule_matches_the_raw_text(self):
        secret = "export API_KEY=abc123"
        c = card(command=secret)
        self.assertNotIn("abc123", c.detail)
        self.assertEqual(c.match_text, secret)


class SessionTests(unittest.TestCase):
    def test_session_lifecycle(self):
        st = AppState(persist=False)
        st.handle_event({"hook_event_name": "SessionStart", "session_id": "a", "cwd": "/p/one"})
        st.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": "a", "cwd": "/p/one", "prompt": "hi"})
        self.assertEqual(st.sessions["a"].status, "working")
        st.handle_event({"hook_event_name": "Stop", "session_id": "a", "cwd": "/p/one"})
        self.assertEqual(st.sessions["a"].status, "ready")
        self.assertEqual(st.toasts[-1].body, "one")
        st.handle_event({"hook_event_name": "SessionEnd", "session_id": "a"})
        self.assertNotIn("a", st.sessions)

    def test_a_notification_can_carry_its_own_title(self):
        st = AppState(persist=False)
        st.handle_event({"hook_event_name": "Notification", "title": "ClaudeNotch is running", "message": "hi"})
        self.assertEqual((st.toasts[-1].title, st.toasts[-1].body), ("ClaudeNotch is running", "hi"))
        st.handle_event({"hook_event_name": "Notification", "message": "Claude needs input"})
        self.assertEqual(st.toasts[-1].title, "Claude Code")

    def test_toasts_say_what_they_report(self):
        st = AppState(persist=False)
        st.handle_event({"hook_event_name": "Stop", "session_id": "a", "cwd": "C:/work/proj"})
        self.assertEqual((st.toasts[-1].kind, st.toasts[-1].cwd), ("done", "C:/work/proj"))
        st.handle_event({"hook_event_name": "Notification", "cwd": "/p", "message": "m"})
        self.assertEqual(st.toasts[-1].kind, "notice")
        st.handle_event({"hook_event_name": "StopFailure", "cwd": "/p", "error": "rate_limit"})
        self.assertEqual((st.toasts[-1].kind, st.toasts[-1].reason), ("failure", "unknown"))
        st.handle_event({"hook_event_name": "StopFailure", "cwd": "/p", "failure_reason": "overloaded",
                         "message": "Overloaded, try again"})
        self.assertEqual((st.toasts[-1].reason, st.toasts[-1].body), ("overloaded", "Overloaded, try again"))
        st.greet()
        self.assertEqual(st.toasts[-1].kind, "")

    def test_status_line_updates_without_reordering(self):
        from claudenotch.statusline import Reading
        st, heard = AppState(persist=False), []
        st.subscribe(lambda: heard.append(1))
        st.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": "a", "cwd": "/p/a", "prompt": "x"})
        st.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": "b", "cwd": "/p/b", "prompt": "y"})
        order = [x.id for x in st.snapshot()[3]]
        n = len(heard)
        st.note_status(Reading(session_id="a", model="claude-opus-5-5", context_pct=0.5, effort="high"))
        self.assertEqual(st.sessions["a"].model, "claude-opus-5-5")
        self.assertEqual([x.id for x in st.snapshot()[3]], order)
        self.assertEqual(len(heard), n + 1)
        st.note_status(Reading(session_id="a", model="claude-opus-5-5", context_pct=0.5, effort="high"))
        self.assertEqual(len(heard), n + 1)          # the same reading again: nobody is told

    def test_status_line_never_revives_an_ended_session(self):
        from claudenotch.statusline import Reading
        st = AppState(persist=False)
        st.handle_event({"hook_event_name": "SessionEnd", "session_id": "gone", "cwd": "/p"})
        st.note_status(Reading(session_id="gone", cwd="/p", context_pct=0.2))
        self.assertNotIn("gone", st.sessions)
        st.note_status(Reading(session_id="new", cwd="/q", context_pct=0.2))
        self.assertIn("new", st.sessions)

    def test_greet(self):
        st = AppState(persist=False)
        st.greet()
        self.assertEqual(st.toasts[-1].title, "ClaudeNotch is running")
        st.greet(updated_from="0.43.1", version="0.44.0")
        self.assertEqual(st.toasts[-1].title, "ClaudeNotch updated to 0.44.0")

    def test_sessions_are_capped(self):
        st = AppState(persist=False)
        for i in range(MAX_SESSIONS + 5):
            st.handle_event({"hook_event_name": "SessionStart", "session_id": f"s{i}", "cwd": f"/p/{i}"})
        self.assertEqual(len(st.sessions), MAX_SESSIONS)


if __name__ == "__main__":
    unittest.main()
