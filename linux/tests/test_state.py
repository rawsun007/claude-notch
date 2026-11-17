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

    def test_greet(self):
        st = AppState(persist=False)
        st.greet()
        self.assertEqual(st.toasts[-1].title, "ClaudeNotch is running")

    def test_sessions_are_capped(self):
        st = AppState(persist=False)
        for i in range(MAX_SESSIONS + 5):
            st.handle_event({"hook_event_name": "SessionStart", "session_id": f"s{i}", "cwd": f"/p/{i}"})
        self.assertEqual(len(st.sessions), MAX_SESSIONS)


if __name__ == "__main__":
    unittest.main()
