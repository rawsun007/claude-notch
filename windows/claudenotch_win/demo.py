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
ALL = [*PERMISSIONS, "queue", "question", *NOTICES, "idle", "hover", "working", "sessions"]


def load(state: AppState, name: str) -> SimpleNamespace:
    """Put demo `name` on `state`. Returns what the overlay needs to know
    (whether to hold the hover card open)."""
    out = SimpleNamespace(hover=False)
    if name in PERMISSIONS:
        state.enqueue_permission(PERMISSIONS[name]())
    elif name == "queue":
        for _ in range(3):
            state.enqueue_permission(permission())
    elif name == "question":
        state.enqueue_question(question())
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


def _show(state: AppState, overlay, name: str) -> None:
    info = load(state, name)
    if info.hover:
        overlay.show_sessions(3600)


if __name__ == "__main__":
    sys.exit(main())
