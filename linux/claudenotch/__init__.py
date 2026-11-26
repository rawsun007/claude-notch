"""ClaudeNotch for Linux.

The Linux edition of ClaudeNotch: Claude Code (and Codex) permission prompts,
questions and session status in a small card hanging from the top of the
screen. Claude Code fires its hooks at a loopback server this app runs on
127.0.0.1:53127, the same wire protocol as the macOS app, so the hook entries
in ~/.claude/settings.json are identical on both.

Everything that is not drawing (the danger rules, secret redaction, the hook
protocol, the settings merge, the server) lives in modules with no GTK import,
so it is testable on any machine with Python.
"""

# Matches the macOS release it ships with, so one release page carries both.
__version__ = "0.45.3"
