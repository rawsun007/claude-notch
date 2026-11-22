from claudenotch.state import PermissionCard

from claudenotch_win import cardmodel as m


def test_titles_match_the_mac():
    assert m.human_title("Bash") == "Run shell command"
    assert m.human_title("MultiEdit") == "Edit file"
    assert m.human_title("ExitPlanMode") == "Approve plan"
    assert m.human_title("exec_command") == "Run shell command"
    assert m.human_title("web.run") == "Search the web"
    assert m.human_title("PowerShell") == "Run PowerShell"
    assert m.human_title("mcp__x__y") == "Run mcp__x__y"


def test_details():
    assert m.human_detail("Bash", {"command": "npm install"}) == "npm install"
    assert m.human_detail("Bash", {"description": "install"}) == "install"
    assert m.human_detail("Edit", {"file_path": "C:\\p\\a.py"}) == "C:\\p\\a.py"
    assert m.human_detail("Task", {"subagent_type": "Explore", "description": "find"}) == "Explore: find"
    assert m.human_detail("TodoWrite", {"todos": [{"status": "in_progress"}, {}]}) == "2 todos  ·  1 in progress"
    assert m.human_detail("TodoWrite", {}) == "no todos"
    assert m.human_detail("TaskUpdate", {"subject": "a", "status": "done"}) == "a  →  done"
    assert m.human_detail("PowerShell", {"command": "Get-ChildItem"}) == "Get-ChildItem"
    assert m.human_detail("mcp__x", {"query": "  ", "url": "https://a"}) == "https://a"
    assert m.human_detail("exec", {"command": ["bash", "-lc", "ls"]}) == "bash -lc ls"
    assert m.human_detail("Bash", "not a dict") == ""


def test_edit_diff_preview_is_cut_at_ten():
    old = "\n".join(f"o{i}" for i in range(12))
    p = m.preview("Edit", {"old_string": old, "new_string": "n"})
    assert p.kind == "diff"
    assert len(p.hunk.old) == 10 and p.hunk.cut_old and not p.hunk.cut_new
    assert p.hunk.new == ["n"]
    assert m.preview_budget(p) == {"diff_rows": 12}
    assert m.preview("Edit", {}) is None


def test_multi_edit_preview():
    p = m.preview("MultiEdit", {"edits": [{"old_string": "a", "new_string": "b"}, {}]})
    assert p.kind == "multi" and p.count == 2
    assert m.preview_budget(p) == {"diff_rows": 3, "multi": True}


def test_write_preview_head_and_more_lines():
    text = "\n".join(str(i) for i in range(20))
    p = m.preview("Write", {"content": text})
    assert p.kind == "write" and p.total == 20 and p.head.count("\n") == 11
    assert m.more_lines_text(20) == "…and 8 more lines"
    assert m.more_lines_text(13) == "…and 1 more line"
    assert m.preview_budget(p) == {"write_rows": 12}


def test_todo_preview_icons():
    p = m.preview("TodoWrite", {"todos": [{"status": "completed", "content": "a"},
                                          {"status": "in_progress", "activeForm": "b"}, {"content": "c"}]})
    assert p.head == "✓ a\n▣ b\n□ c"


def test_secrets_are_redacted_in_detail_and_preview():
    secret = "sk-ant-api03-" + "A" * 40
    card = PermissionCard("Bash", {"command": f"curl -H 'x-api-key: {secret}'"}, "C:\\work\\proj", "permission")
    t = m.card_text(card)
    assert secret not in t.detail
    assert t.title == "Run shell command" and t.source == "Claude Code" and t.project == "proj"
    p = m.preview("Write", {"content": f"KEY={secret}"})
    assert secret not in p.head


def test_failure_wording_matches_eventserver():
    assert m.failure_title("rate_limit") == "Rate limited, session stopped"
    assert m.failure_title("weird") == "Session stopped on an error"
    assert m.failure_detail("overloaded", "overloaded") == \
        "Anthropic's servers are busy. Try the turn again in a moment."
    assert m.failure_detail("x", "some_code") == "The turn stopped before it finished."
    assert m.failure_detail("x", "The API said no.") == "The API said no."


def test_notice_text_for_each_kind():
    from claudenotch.state import Toast
    done = m.notice_text(Toast("Claude is done", "proj", kind="done", cwd="C:/w/proj"))
    assert (done.card, done.source, done.title, done.detail) == ("completed", "Claude Code", "Claude finished",
                                                                 "proj")
    n = m.notice_text(Toast("Claude Code", "Claude is waiting for your input", kind="notice", cwd="C:/w/p"))
    assert (n.card, n.title, n.detail) == ("notification", "Claude is waiting for your input", "p")
    t = m.notice_text(Toast("Custom title", "Claude needs your attention", kind="notice"))
    assert t.title == "Custom title"
    f = m.notice_text(Toast("Claude stopped with an error", "rate_limit", kind="failure", reason="rate_limit"))
    assert f.title == "⚠️ Rate limited, session stopped"
    assert f.detail.startswith("You have hit the usage limit")
    hello = m.notice_text(Toast("ClaudeNotch is running", "Claude Code prompts will appear here.", system=True))
    assert (hello.source, hello.title) == ("ClaudeNotch", "ClaudeNotch is running")


def test_build_answers_matches_the_mac():
    assert m.build_answers([False, True], [{"B"}, {"z", "a"}], ["", ""]) == [["B"], ["a", "z"]]
    assert m.build_answers([False], [{"B"}], ["  mine "]) == [["mine"]]
    assert m.build_answers([True], [{"a"}], ["mine"]) == [["a", "mine"]]
    assert m.build_answers([False], [set()], [""]) == [[]]
    assert m.question_count_text(1) == "1 question" and m.question_count_text(3) == "3 questions"


def test_idle_meter_from_the_top_session():
    from claudenotch.state import Session
    s = Session("a", "C:/p", model="claude-opus-5-5", effort="high", context_pct=0.42, context_window=200000,
                context_tokens=85000, cost_usd=1.234)
    mt = m.idle_meter(s, "feature/really-long-name")
    assert (mt.model_name, mt.model_version, mt.effort) == ("Opus", "5.5", "High")
    assert mt.branch_short == "featur…-name"
    assert mt.meter_label == "85k/200k" and mt.cost_label == "$1.23"


def test_idle_meter_before_any_status_line():
    from claudenotch.state import Session
    mt = m.idle_meter(Session("a", "C:/p"))
    assert (mt.model_name, mt.meter_label, mt.cost_label) == ("", "no usage yet", "")
    assert m.idle_meter(Session("a", "C:/p", context_pct=0.3)).meter_label == "30%"
    assert m.idle_meter(None, "main").branch_short == "main"
