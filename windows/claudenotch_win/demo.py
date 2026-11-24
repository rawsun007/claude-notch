"""The sample cards, as on the Mac's Demos menu (DemoCards.swift).

    python -m claudenotch_win.demo permission
    python -m claudenotch_win.demo dangerous --shot out.png --after 1500
    python -m claudenotch_win.demo --list

Runs the real overlay against a private, in-memory AppState: it installs no
hooks, binds no port and writes no settings, so it is safe to run next to a
running ClaudeNotch. A demo card's answer goes nowhere. `--shot` saves the
top of the screen the notch is on once the card has settled, for comparing
with the Mac.
"""

from __future__ import annotations

import argparse
import sys
from types import SimpleNamespace

from claudenotch import protocol, statusline
from claudenotch.danger import danger_reasons
from claudenotch.state import AppState, PermissionCard, QuestionCard

HOME = "C:\\Users\\example"


def _perm(tool: str, tool_input: dict, cwd: str = HOME) -> PermissionCard:
    return PermissionCard(tool, tool_input, cwd, protocol.PERMISSION, "demo")


def permission() -> PermissionCard:
    return _perm("Bash", {"command": "npm install"})


def dangerous() -> PermissionCard:
    # The reasons come from the real detector, so this also proves it fires.
    card = _perm("Bash", {"command": "rm -rf /tmp/cache && sudo chmod -R 777 /Library/LaunchAgents"})
    assert card.dangers, "the danger detector no longer fires on the demo command"
    return card


def dangerous_powershell() -> PermissionCard:
    return _perm("PowerShell", {"command": "Remove-Item -Recurse -Force C:\\Users\\example\\proj"})


def diff() -> PermissionCard:
    return _perm("Edit", {"file_path": "C:\\Users\\example\\main.swift",
                          "old_string": "let x = 42\nprint(\"hello\")\nreturn x",
                          "new_string": "let x = 100\nprint(\"hello, world\")\nreturn x * 2"},
                 cwd="C:\\Users\\example")


def write() -> PermissionCard:
    body = "\n".join(f"line {i}: some content" for i in range(1, 19))
    return _perm("Write", {"file_path": "C:\\Users\\example\\notes.md", "content": body})


def question() -> QuestionCard:
    qs = protocol.parse_questions({"tool_input": {"questions": [
        {"header": "Format", "question": "Which formats should the export include?", "multiSelect": True,
         "options": [{"label": "CSV"}, {"label": "JSON"}, {"label": "PDF summary"}]},
        {"header": "Storage", "question": "Where should the exported reports live?", "multiSelect": False,
         "options": [
             {"label": "Local disk", "description": "Fastest, but nothing is shared between machines and a "
                                                    "reinstall loses it."},
             {"label": "OneDrive", "description": "Syncs across your PCs. Conflicts are possible when two "
                                                  "sessions write at once."},
             {"label": "S3 bucket", "description": "Durable and shareable, needs credentials."}]}]}})
    return QuestionCard(qs, HOME, "demo")


PERMISSIONS = {"permission": permission, "dangerous": dangerous, "dangerous-powershell": dangerous_powershell,
               "diff": diff, "write": write}
NOTICES = {
    "notification": {"hook_event_name": "Notification", "message": "Claude is waiting for your input"},
    "completed": {"hook_event_name": "Stop"},
    "failure": {"hook_event_name": "StopFailure", "failure_reason": "rate_limit", "message": "rate_limit"},
}
HISTORY_TABS = ("history", "history-projects", "history-activity")
COMPOSE = ("compose", "deny-reason", "reply")
MINIMIZED = ("question-minimized",)
DEMO_REPLY = """## Fixed the history drawer

The search lost its text whenever **new activity** arrived, because the drawer was rebuilt on every
change. It now refreshes in place.

- `overlay.py`: refresh the open drawer instead of rebuilding it
- `historydrawer.py`: keep the tab, the filter and the search
- added a test for both

1. Open the notch and press the clock
2. Type in the search, then run something in Claude

```powershell
pytest windows/tests -k history
```

All 31 tests pass."""
ALL = [*HISTORY_TABS, *COMPOSE, *MINIMIZED, *PERMISSIONS, "budget", "queue", "question", "expired", "expired-question", *NOTICES, "limit", "idle", "hover", "working", "sessions"]


def load(state: AppState, name: str) -> SimpleNamespace:
    """Put demo `name` on `state`. Returns what the overlay needs to know
    (whether to hold the hover card open)."""
    out = SimpleNamespace(hover=False)
    if name == "budget":
        from claudenotch.budget import BudgetBlock
        card = permission()
        state.approver = lambda c: (setattr(c, "budget_block", BudgetBlock("daily", 12.4, 10.0)), "card")[1]
        state.enqueue_permission(card)
    elif name in ("expired", "expired-question"):
        # The Mac's "Expired Card (Too Late)": the hook gave up waiting.
        if name == "expired":
            card = permission()
            state.enqueue_permission(card)
            state.drop_permission(card.id)
        else:
            card = question()
            state.enqueue_question(card)
            state.drop_question(card.id)
    elif name in PERMISSIONS:
        state.enqueue_permission(PERMISSIONS[name]())
    elif name == "queue":
        for _ in range(3):
            state.enqueue_permission(permission())
    elif name == "question":
        state.enqueue_question(question())
    elif name == "limit":
        import time
        from claudenotch.limits import Armed
        from claudenotch.state import Toast
        title, body = Armed().check("5-hour", 0.96, time.time() + 2400, time.time())
        state.toasts = [Toast(title, body, kind="limit")]
        state._changed()
    elif name in NOTICES:
        state.handle_event({**NOTICES[name], "session_id": "demo", "cwd": HOME + "\\proj"})
    elif name == "sessions":
        # Three live sessions: the top one is the header, two more are rows.
        for sid, folder, model, pct, tokens, cost in (
                ("s3", "api-server", "gpt-5-codex", 0, 0, 0.0),
                ("s2", "notch-website", "claude-sonnet-5-5", 71, 142000, 3.12),
                ("demo", "claude-notch", "claude-opus-5-5", 42, 84000, 1.84)):
            state.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": sid,
                                "cwd": f"{HOME}\\{folder}", "prompt": "go"})
            state.note_status(statusline.parse(statusline.flatten({
                "session_id": sid, "model": {"id": model}, "effort": {"level": "high"},
                "context_window": {"used_percentage": pct, "context_window_size": 200000,
                                   "total_input_tokens": tokens},
                "cost": {"total_cost_usd": cost}, "workspace": {"git_worktree": "docs-refresh" if sid == "s2" else ""}})))
        state.handle_event({"hook_event_name": "Stop", "session_id": "s2", "cwd": f"{HOME}\\notch-website"})
        state.handle_event({"hook_event_name": "SubagentStart", "session_id": "s3", "cwd": f"{HOME}\\api-server"})
        state.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": "demo",
                            "cwd": f"{HOME}\\claude-notch", "prompt": "go"})
        state.toasts = []
        # The clock is coarse on Windows: make "most recent hook" explicit.
        for i, sid in enumerate(("s3", "s2", "demo")):
            state.sessions[sid].updated += i
        out.hover = True
    elif name in ("hover", "working"):
        state.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": "demo", "cwd": HOME,
                            "prompt": "fix the build"})
        if name == "hover":
            state.handle_event({"hook_event_name": "Stop", "session_id": "demo", "cwd": HOME})
            state.toasts = []
        if name == "working":
            state.sessions["demo"].permission_mode = "plan"
            state.sessions["demo"].edited_files.update({"overlay.py", "historydrawer.py", "test_overlay_qt.py"})
            # A tool running for a while, for the command strip and its clock.
            import time as _time
            from claudenotch.state import PermissionCard
            from claudenotch import protocol as _protocol
            state.rules.append(__import__("claudenotch.state", fromlist=["AllowRule"]).AllowRule("PowerShell", ""))
            state.enqueue_permission(PermissionCard("PowerShell", {"command": "npm run build -- --watch"}, HOME,
                                                    _protocol.PERMISSION, "demo"))
            state.sessions["demo"].activity_started = _time.time() - 75
            state.handle_event({"hook_event_name": "PostToolUse", "session_id": "demo", "cwd": HOME,
                                "tool_name": "TodoWrite", "tool_input": {"todos": [
                                    {"status": "completed"}, {"status": "completed"}, {"status": "in_progress"},
                                    {"status": "pending"}, {"status": "pending"}]}})
        # What Claude Code's status line reports, as the forwarder posts it.
        state.note_status(statusline.parse(statusline.flatten({
            "session_id": "demo", "model": {"id": "claude-opus-5-5"}, "effort": {"level": "high"},
            "context_window": {"used_percentage": 42, "context_window_size": 200000, "total_input_tokens": 84000},
            "cost": {"total_cost_usd": 1.84}})))
        out.hover = True
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="claudenotch_win.demo")
    ap.add_argument("name", nargs="?", default="permission", choices=ALL)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--pet", action="store_true", help="as with Pet Mode on: the pet's badges on the cards")
    ap.add_argument("--shot", help="save a screenshot of the top of the screen here, then quit")
    ap.add_argument("--after", type=int, default=1200, help="ms to wait before --shot")
    ap.add_argument("--height", type=int, default=420, help="how much of the screen --shot keeps")
    args = ap.parse_args(argv)
    if args.list:
        print("\n".join(ALL))
        return 0

    from PySide6.QtCore import QTimer
    from PySide6.QtWidgets import QApplication

    from .overlay import Overlay

    app = QApplication.instance() or QApplication(sys.argv)
    state = AppState(persist=False)
    overlay = Overlay(state)
    # Demo cards hold nothing private, so they stay visible to --shot and to
    # screen recordings; --pet shows them as with Pet Mode on.
    forced = {"hide_from_capture": False, **({"pet_enabled": True} if args.pet else {})}
    real = overlay._setting
    overlay._setting = lambda n, d: forced[n] if n in forced else real(n, d)
    app.processEvents()
    QTimer.singleShot(400, lambda: _show(state, overlay, args.name))

    if args.shot:
        def shoot():
            screen = app.primaryScreen()
            g = screen.geometry()
            w = min(g.width(), 1000)
            pix = screen.grabWindow(0, g.x() + (g.width() - w) // 2, g.y(), w, args.height)
            pix.save(args.shot)
            print(f"saved {args.shot} ({pix.width()}x{pix.height()} px, dpr {screen.devicePixelRatio()})")
            app.quit()
        QTimer.singleShot(400 + args.after, shoot)
    return app.exec()


def _history(state: AppState) -> None:
    """The drawer's demo: a week of sessions in three projects, and the
    activity log's every outcome."""
    import time as _time
    now = _time.time()
    for sid, folder, prompt, model, cost, ago, turns in (
            ("a1", "claude-notch", "Port the history drawer from the Mac", "claude-opus-5-5", 4.12, 600, 9),
            ("a2", "notch-website", "Fix the changelog page on mobile", "claude-sonnet-5-5", 0.86, 7200, 3),
            ("a3", "claude-notch", "Add the jump list and the hotkeys", "claude-opus-5-5", 6.40, 26 * 3600, 14),
            ("a4", "api-server", "Rate limit the export endpoint", "claude-sonnet-5-5", 1.95, 3 * 86400, 5)):
        for i in range(turns):
            state.archive.note_turn(sid, f"{HOME}\\{folder}", folder, prompt=prompt, model=model,
                                    branch="windows" if folder == "claude-notch" else "main", cost_usd=cost,
                                    now=now - ago - (turns - i) * 300)
    for what, title, detail, project, ago in (
            ("notice", "Claude is done", "claude-notch", "claude-notch", 30),
            ("allowed", "Run PowerShell", "npm test", "claude-notch", 90),
            ("auto-approved", "Edit overlay.py", f"{HOME}\\claude-notch\\overlay.py", "claude-notch", 200),
            ("allowed, destructive", "Run PowerShell", "Remove-Item -Recurse -Force .\\build", "claude-notch", 400),
            ("denied", "Run shell command", "git push --force origin main", "api-server", 1800),
            ("answered", "Question", "Which formats should the export include?", "api-server", 3600),
            ("sent to terminal", "Fetch a web page", "https://example.com/docs", "notch-website", 7200)):
        state.history.append({"at": now - ago, "what": what, "title": title, "detail": detail, "project": project})
    state.history.sort(key=lambda e: e["at"])
    state.limits.update({"five_hour_pct": 0.42, "five_hour_resets_at": now + 2 * 3600 + 300,
                         "seven_day_pct": 0.18, "seven_day_resets_at": now + 3 * 86400 + 4 * 3600})


def _show(state: AppState, overlay, name: str) -> None:
    if name == "question-minimized":
        # Two questions put away: the stub on the notch's left, with its count.
        for _ in range(2):
            q = question()
            state.enqueue_question(q)
            state.minimize_question(q.id)
        return
    if name == "reply":
        state.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": "demo",
                            "cwd": HOME + "\\claude-notch", "prompt": "fix the drawer"})
        state.handle_event({"hook_event_name": "Stop", "session_id": "demo", "cwd": HOME + "\\claude-notch",
                            "last_assistant_message": DEMO_REPLY})
        state.toasts = []
        overlay.show_reply()
        return
    if name == "compose":
        _history(state)                       # recent projects for the target menu
        overlay.begin_compose()
        if overlay._compose_view is not None:
            overlay._compose_view.edit.setPlainText("Now add a test for the empty search case")
        return
    if name == "deny-reason":
        card = permission()
        state.enqueue_permission(card)
        overlay.begin_deny_reason(card)
        if overlay._compose_view is not None:
            overlay._compose_view.edit.setPlainText("Run the unit tests first, not the whole suite")
        return
    if name in HISTORY_TABS:
        _history(state)
        overlay.open_history()
        if overlay._history_view is not None and name != "history":
            overlay._history_view.set_tab("projects" if name == "history-projects" else "events")
        return
    info = load(state, name)
    if info.hover:
        overlay.show_sessions(3600)


if __name__ == "__main__":
    sys.exit(main())
