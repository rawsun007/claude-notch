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
