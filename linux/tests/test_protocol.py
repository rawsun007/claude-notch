import json
import unittest

from claudenotch import protocol as p


class BodyTests(unittest.TestCase):
    def test_pretool_bodies_match_the_mac_app(self):
        self.assertEqual(json.loads(p.pretool_body("allow")),
                         {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}})
        deny = json.loads(p.pretool_body("deny", "x" * 500))["hookSpecificOutput"]
        self.assertEqual(deny["permissionDecision"], "deny")
        self.assertEqual(len(deny["permissionDecisionReason"]), 200)
        # A reason only travels with a deny.
        self.assertNotIn("permissionDecisionReason", json.loads(p.pretool_body("allow", "r"))["hookSpecificOutput"])

    def test_permission_request_has_no_ask(self):
        self.assertEqual(p.permreq_body("ask"), p.OK_BODY)
        self.assertEqual(json.loads(p.permreq_body("deny"))["hookSpecificOutput"]["decision"], {"behavior": "deny"})

    def test_answers_body(self):
        qs = [p.Question("Agent", "Which?", False, [("Claude", ""), ("Codex", "")]),
              p.Question("", "Tests?", True, [("Unit", ""), ("E2E", "")])]
        out = json.loads(p.answers_body(qs, [["Claude"], []]))["hookSpecificOutput"]
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("  - Agent: Claude", out["permissionDecisionReason"])
        self.assertIn("  - Tests?: (no preference)", out["permissionDecisionReason"])

    def test_a_card_nobody_answered_has_no_opinion(self):
        self.assertEqual(json.loads(p.timeout_body(p.PERMISSION))["hookSpecificOutput"]["permissionDecision"], "ask")
        self.assertEqual(p.timeout_body(p.QUESTION), p.OK_BODY)


class ClassifyTests(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(p.classify({"hook_event_name": "PreToolUse", "tool_name": "Bash"}), p.PERMISSION)
        self.assertEqual(p.classify({"hook_event_name": "PreToolUse", "tool_name": "Grep"}), p.PASS)
        self.assertEqual(p.classify({"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion"}), p.QUESTION)
        self.assertEqual(p.classify({"hook_event_name": "PermissionRequest", "tool_name": "Bash"}), p.PERM_REQUEST)
        self.assertEqual(p.classify({"hook_event_name": "Stop"}), p.EVENT)

    def test_parse_questions_skips_malformed_entries(self):
        payload = {"tool_input": {"questions": [
            {"question": "Pick", "header": "H", "options": [{"label": "A", "description": "a"}, {"nolabel": 1}]},
            {"question": "No options", "options": []},
            "junk",
        ]}}
        qs = p.parse_questions(payload)
        self.assertEqual(len(qs), 1)
        self.assertEqual(qs[0].options, [("A", "a")])


class PreviewTests(unittest.TestCase):
    def test_edit_and_bash(self):
        pv = p.preview("Edit", {"file_path": "/src/app.py", "old_string": "a", "new_string": "b"})
        self.assertEqual((pv.title, pv.old, pv.new), ("Edit app.py", "a", "b"))
        self.assertEqual(p.preview("Bash", {"command": "npm test"}).detail, "npm test")
        self.assertEqual(p.preview("shell", {"command": ["ls", "-la"]}).detail, "ls -la")


class RequestCheckTests(unittest.TestCase):
    def test_browser_requests_are_refused(self):
        self.assertTrue(p.is_local_request({"Host": "127.0.0.1:53127"}))
        self.assertFalse(p.is_local_request({"Host": "127.0.0.1:53127", "Origin": "https://evil.example"}))
        self.assertFalse(p.is_local_request({"Host": "evil.example:53127"}))

    def test_token(self):
        self.assertTrue(p.token_allows("", None))
        self.assertTrue(p.token_allows("t=abc", "abc"))
        self.assertFalse(p.token_allows("", "abc"))
        self.assertFalse(p.token_allows("t=abd", "abc"))


if __name__ == "__main__":
    unittest.main()
