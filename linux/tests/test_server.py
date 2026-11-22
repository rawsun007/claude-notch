"""The server end to end: real sockets, real HTTP, payloads shaped like Claude
Code's, answered through AppState the way a click on the card answers them."""

import json
import os
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from unittest import mock

from claudenotch import hooks
from claudenotch.server import HookServer, normalize
from claudenotch.state import AppState


def post(port, payload, path="/hook", query="", headers=None, timeout=10):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}{query}", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json", **(headers or {})}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"HOME": self.tmp.name, "USERPROFILE": self.tmp.name, "APPDATA": self.tmp.name,
                                                "CLAUDE_CONFIG_DIR": os.path.join(self.tmp.name, ".claude")})
        self.env.start()
        self.state = AppState(persist=False)
        self.server = HookServer(self.state, port=0, window=3)
        self.server.start()
        self.port = self.server.port

    def tearDown(self):
        self.server.stop()
        self.env.stop()
        self.tmp.cleanup()

    def answer_when_card_appears(self, decision, always=False):
        def run():
            for _ in range(200):
                if self.state.permissions:
                    self.state.resolve_permission(self.state.permissions[0].id, decision, always)
                    return
                time.sleep(0.01)
        threading.Thread(target=run, daemon=True).start()

    def test_allow_from_the_card_reaches_claude_code(self):
        self.answer_when_card_appears("allow")
        out = post(self.port, {"hook_event_name": "PreToolUse", "tool_name": "Bash",
                               "tool_input": {"command": "npm test"}, "cwd": "/p", "session_id": "s"})
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "allow")

    def test_permission_request_deny(self):
        self.answer_when_card_appears("deny")
        out = post(self.port, {"hook_event_name": "PermissionRequest", "tool_name": "Write",
                               "tool_input": {"file_path": "/p/x"}, "cwd": "/p"})
        self.assertEqual(out["hookSpecificOutput"]["decision"], {"behavior": "deny"})

    def test_nobody_answering_means_no_opinion(self):
        out = post(self.port, {"hook_event_name": "PreToolUse", "tool_name": "Bash",
                               "tool_input": {"command": "ls"}})
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "ask")
        self.assertEqual(self.state.permissions, [], "the card goes when the hook gives up")

    def test_status_line_fills_the_meters(self):
        from claudenotch import statusline
        raw = {"session_id": "s9", "workspace": {"current_dir": "/p/proj"}, "model": {"id": "claude-opus-5-5"},
               "context_window": {"used_percentage": 40, "context_window_size": 200000,
                                  "total_input_tokens": 80000},
               "cost": {"total_cost_usd": 2.5}, "rate_limits": {"five_hour": {"used_percentage": 12}}}
        out = post(self.port, statusline.flatten(raw), path="/statusline")
        self.assertEqual(out, {"ok": True})
        s = self.state.sessions["s9"]
        self.assertEqual((s.model, s.context_tokens, s.cost_usd), ("claude-opus-5-5", 80000, 2.5))
        self.assertAlmostEqual(self.state.limits["five_hour_pct"], 0.12)

    def test_control_with_an_argument(self):
        got = []
        self.server.controls["settings"] = lambda page="": got.append(page)
        self.assertTrue(self.server.control("settings:privacy"))
        self.assertTrue(self.server.control("settings"))
        self.assertFalse(self.server.control("nope:x"))
        self.server.controls["quit"] = lambda: got.append("quit")
        self.assertFalse(self.server.control("quit:now"))      # takes no argument
        self.assertEqual(got, ["privacy", ""])

    def test_read_only_tools_pass_straight_through(self):
        t0 = time.monotonic()
        out = post(self.port, {"hook_event_name": "PreToolUse", "tool_name": "Grep", "tool_input": {}})
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "ask")
        self.assertLess(time.monotonic() - t0, 1)

    def test_question_answers(self):
        def run():
            for _ in range(200):
                if self.state.questions:
                    self.state.resolve_question(self.state.questions[0].id, [["Codex"]])
                    return
                time.sleep(0.01)
        threading.Thread(target=run, daemon=True).start()
        out = post(self.port, {"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
                               "tool_input": {"questions": [{"question": "Which?", "header": "Agent",
                                                             "options": [{"label": "Claude"}, {"label": "Codex"}]}]}})
        self.assertIn("Agent: Codex", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_informational_events_update_sessions(self):
        post(self.port, {"hook_event_name": "UserPromptSubmit", "session_id": "a", "cwd": "/w/proj", "prompt": "go"})
        self.assertEqual(self.state.sessions["a"].status, "working")
        self.assertEqual(self.state.sessions["a"].project, "proj")

    def test_a_browser_origin_gets_nothing(self):
        with self.assertRaises((urllib.error.URLError, ConnectionError, OSError)):
            post(self.port, {"hook_event_name": "Stop"}, headers={"Origin": "https://evil.example"}, timeout=3)

    def test_the_token_is_required_once_the_hooks_carry_one(self):
        hooks.install()
        token = hooks.read_token()
        with self.assertRaises((urllib.error.URLError, ConnectionError, OSError)):
            post(self.port, {"hook_event_name": "Stop"}, timeout=3)
        self.assertEqual(post(self.port, {"hook_event_name": "Stop"}, query=f"?t={token}"), {"ok": True})

    def test_ping_reports_the_version(self):
        from claudenotch import __version__
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/ping", timeout=3) as r:
            self.assertEqual(json.loads(r.read())["version"], __version__)

    def test_control_actions(self):
        called = []
        self.server.controls["settings"] = lambda: called.append("settings")
        self.assertEqual(post(self.port, {}, path="/control/settings"), {"ok": True})
        self.assertEqual(called, ["settings"])
        with self.assertRaises(urllib.error.HTTPError):
            post(self.port, {}, path="/control/format-disk")

    def test_control_needs_the_token_like_a_hook(self):
        self.server.controls["quit"] = lambda: None
        hooks.install()
        with self.assertRaises((urllib.error.URLError, ConnectionError, OSError)):
            post(self.port, {}, path="/control/quit", timeout=3)

    def test_camel_case_keys_are_normalized(self):
        self.assertEqual(normalize({"hookEventName": "Stop", "sessionId": "x", "tool_input": {"aB": 1}}),
                         {"hook_event_name": "Stop", "session_id": "x", "tool_input": {"aB": 1}})


class PauseTests(unittest.TestCase):
    def test_paused_answers_no_opinion_at_once(self):
        from claudenotch.state import AppState
        server = HookServer(AppState(persist=False), port=0, window=30)
        server.paused.set()
        body = server.answer({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "ls"}})
        self.assertIn('"permissionDecision":"ask"', body)
        self.assertEqual(server.answer({"hook_event_name": "PermissionRequest", "tool_name": "Bash"}), '{"ok":true}')
        self.assertEqual(server.state.permissions, [])


class EditionTests(unittest.TestCase):
    def test_ping_names_the_edition(self):
        import urllib.request
        from claudenotch.state import AppState
        for app_id in ("claudenotch-windows", "claudenotch-linux"):
            server = HookServer(AppState(persist=False), port=0, app_id=app_id)
            server.start()
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{server.port}/ping", timeout=5) as r:
                    self.assertEqual(json.loads(r.read())["app"], app_id)
                    self.assertTrue(r.headers["Server"].startswith("ClaudeNotch-"))
            finally:
                server.stop()


if __name__ == "__main__":
    unittest.main()
