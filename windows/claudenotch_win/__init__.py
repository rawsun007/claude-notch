"""ClaudeNotch for Windows.

Claude Code permission prompts, questions and session status in a small pill
at the top centre of the screen, plus a tray icon. Claude Code posts its HTTP
hooks to 127.0.0.1:53127, the same wire protocol as the macOS and Linux
editions, so the entries in %USERPROFILE%\\.claude\\settings.json are the same
on every machine.

Everything that is not drawing comes from the Linux edition's pure modules
(`claudenotch.protocol`, `danger`, `redact`, `hooks`, `server`, `state`,
`settings`): one copy of the core, tested on Linux and Windows CI. This
package adds only the Windows parts: Qt UI, tray, toasts, start at login,
single instance, fullscreen detection.
"""

from . import paths

paths.ensure_core_importable()

from claudenotch import __version__  # noqa: E402  the shared version line (D5)

__all__ = ["__version__"]
