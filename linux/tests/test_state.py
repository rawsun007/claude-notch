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

    def test_a_card_too_late_to_answer_stays_until_dismissed(self):
        # The Mac's expired card: kept, never answered, never a rule.
        st, got = AppState(persist=False), []
        st.keep_expired = True
        old, live = card(answers=got), card(command="npm run lint")
        st.enqueue_permission(old)
        st.enqueue_permission(live)
        st.drop_permission(old.id)
        perms = st.snapshot()[0]
        self.assertEqual([c.id for c in perms], [live.id, old.id])     # the live card first
        self.assertTrue(old.stale)
        st.resolve_all_permissions(protocol.ALLOW)
        self.assertEqual([c.id for c in st.permissions], [old.id])      # Allow All leaves it
        st.resolve_permission(old.id, protocol.ALLOW, always=True)
        self.assertEqual((st.permissions, st.rules, got), ([], [], []))
        # Without keep_expired (Linux), the card just goes.
        st2 = AppState(persist=False)
        c = card()
        st2.enqueue_permission(c)
        st2.drop_permission(c.id)
        self.assertEqual(st2.permissions, [])

    def test_allowed_n_times_suggests_a_rule(self):
        # The Mac's priorApprovals: three manual approvals of one exact command.
        st = AppState(persist=False)
        for i in range(3):
            c = card()
            self.assertFalse(st.suggests_rule(c))
            st.enqueue_permission(c)
            st.resolve_permission(c.id, protocol.ALLOW)
        nxt = card()
        self.assertEqual(st.approval_count(nxt), 3)
        self.assertTrue(st.suggests_rule(nxt))
        self.assertFalse(st.suggests_rule(card(command="npm run lint")))
        self.assertNotIn("npm test", "".join(st.repeat_approvals))    # hashed, never the command
        # Never for a dangerous command, however often.
        for _ in range(4):
            d = card(command="rm -rf build")
            st.enqueue_permission(d)
            st.resolve_permission(d.id, protocol.ALLOW)
        self.assertFalse(st.suggests_rule(card(command="rm -rf build")))
        # Making the rule spends the tally.
        st.enqueue_permission(nxt)
        st.resolve_permission(nxt.id, protocol.ALLOW, always=True)
        self.assertEqual(st.approval_count(card()), 0)
        self.assertFalse(st.suggests_rule(card()))

    def test_the_running_tool_and_its_clock(self):
        from claudenotch.state import activity_label, running_duration
        st = AppState(persist=False)
        st.rules = [AllowRule("Bash", "")]
        st.enqueue_permission(card(command="npm   test\n--watch"))       # answered by the rule, still noted
        s = st.sessions["s1"]
        self.assertEqual(s.activity, "Bash: npm test --watch")
        self.assertIsNotNone(s.activity_started)
        st.handle_event({"hook_event_name": "Stop", "session_id": "s1", "cwd": "/home/a/proj"})
        self.assertEqual((s.activity, s.activity_started), ("", None))
        self.assertEqual(activity_label("Read", ""), "Read")
        self.assertEqual(len(activity_label("Bash", "x" * 200)), 80)
        self.assertEqual([running_duration(x) for x in (0.4, 42, 187, 7500, 97_200)],
                         ["0s", "42s", "3m 07s", "2h 05m", "1d 03h"])

    def test_powershell_cards_show_the_command_and_old_rules_still_match(self):
        from claudenotch.state import migrate_exact
        c = card(tool="PowerShell", command="npm test, then lint")
        self.assertEqual((c.title, c.detail, c.match_text), ("PowerShell", "npm test, then lint", "npm test, then lint"))
        self.assertEqual(migrate_exact("PowerShell", "command: npm test, then lint"), "npm test, then lint")
        kept = "command: npm test, description: run tests"
        self.assertEqual(migrate_exact("PowerShell", kept), kept)
        self.assertEqual(migrate_exact("Bash", "command: x"), "command: x")
        self.assertTrue(AllowRule("PowerShell", migrate_exact("PowerShell", "command: npm test, then lint")).matches(c))

    def test_task_list_progress(self):
        st = AppState(persist=False)
        post = lambda tool, ti: st.handle_event({"hook_event_name": "PostToolUse", "session_id": "s1",
                                                 "cwd": "/p", "tool_name": tool, "tool_input": ti})
        post("TaskUpdate", {"taskId": "1", "status": "in_progress"})
        post("TaskUpdate", {"taskId": "2", "status": "completed"})
        post("TaskUpdate", {"taskId": "3", "status": "pending"})
        post("TaskUpdate", {"taskId": "3", "status": "deleted"})
        self.assertEqual(st.sessions["s1"].task_progress, (1, 2))
        post("TodoWrite", {"todos": [{"status": "completed"}, {"status": "in_progress"}, {"status": "pending"}, "x"]})
        self.assertEqual(st.sessions["s1"].task_progress, (1, 3))        # the checklist wins
        post("TodoWrite", {"todos": "nonsense"})
        self.assertEqual(st.sessions["s1"].task_progress, (1, 2))

    def test_a_destructive_allow_is_logged_as_such(self):
        st = AppState(persist=False)
        c = card(command="rm -rf build")
        st.enqueue_permission(c)
        st.resolve_permission(c.id, protocol.ALLOW)
        self.assertEqual(st.history[-1]["what"], "allowed, destructive")

    def test_the_last_reply_is_kept_from_the_stop_payload(self):
        st = AppState(persist=False)
        st.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/p", "prompt": "go"})
        st.handle_event({"hook_event_name": "Stop", "session_id": "s1", "cwd": "/p",
                         "last_assistant_message": "## Done\n\n- fixed it"})
        self.assertEqual(st.sessions["s1"].last_reply, "## Done\n\n- fixed it")
        st.handle_event({"hook_event_name": "Stop", "session_id": "s1", "cwd": "/p",
                         "transcript_path": "/etc/passwd"})                    # refused, the old reply stays
        self.assertEqual(st.sessions["s1"].last_reply, "## Done\n\n- fixed it")

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

    def test_auto_approve_allows_without_a_card_and_says_so(self):
        st, got = AppState(persist=False), []
        st.approver = lambda c: "allow"
        self.assertFalse(st.enqueue_permission(card(command="sudo rm -rf /tmp/x", answers=got)))
        self.assertEqual(got, ["allow"])
        self.assertEqual(st.permissions, [])
        self.assertEqual(st.history[-1]["what"], "auto-approved, destructive")
        self.assertIsNotNone(st.auto_info)
        self.assertGreater(st.auto_info_at, 0)
        st.dismiss_auto_info()
        self.assertIsNone(st.auto_info)

    def test_auto_approve_confirm_now_shows_the_card_flagged(self):
        st, got = AppState(persist=False), []
        st.approver = lambda c: "confirm_now"
        self.assertTrue(st.enqueue_permission(card(command="sudo rm -rf /tmp/x", answers=got)))
        self.assertTrue(st.permissions[0].confirm_now)
        self.assertEqual(got, [])

    def test_no_approver_or_card_verdict_changes_nothing(self):
        st = AppState(persist=False)
        st.approver = lambda c: "card"
        self.assertTrue(st.enqueue_permission(card()))
        self.assertFalse(st.permissions[0].confirm_now)

    def test_stats_count_decisions(self):
        st = AppState(persist=False)
        c = card()
        st.enqueue_permission(c)
        st.resolve_permission(c.id, protocol.ALLOW)
        d = card(command="sudo rm -rf /x")
        st.enqueue_permission(d)
        st.resolve_permission(d.id, protocol.DENY)
        v = st.stats.value
        self.assertEqual((v.allowed, v.denied, v.dangerous_flagged), (1, 1, 1))
        self.assertEqual(v.tool_counts, {"Bash": 2})

    def test_each_finished_turn_is_archived(self):
        st = AppState(persist=False)
        st.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": "a", "cwd": "/p/one",
                         "prompt": "fix the build"})
        st.handle_event({"hook_event_name": "Stop", "session_id": "a", "cwd": "/p/one"})
        recs = st.archive.newest_first()
        self.assertEqual([(r.id, r.project, r.summary, r.turns) for r in recs], [("a", "one", "fix the build", 1)])

    def test_plan_limit_warning_once_per_threshold(self):
        from claudenotch.statusline import Reading
        st = AppState(persist=False)
        st.note_status(Reading(session_id="a", five_hour_pct=0.83, five_hour_resets_at=4_000_000_000))
        self.assertEqual((st.toasts[-1].kind, st.toasts[-1].title), ("limit", "80% of your 5-hour limit used"))
        st.note_status(Reading(session_id="a", five_hour_pct=0.85, five_hour_resets_at=4_000_000_000))
        self.assertEqual(len(st.toasts), 1)
        st.limit_warnings = False
        st.note_status(Reading(session_id="a", five_hour_pct=0.97, five_hour_resets_at=4_000_000_000))
        self.assertEqual(len(st.toasts), 1)

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
