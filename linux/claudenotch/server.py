"""The loopback HTTP server Claude Code's hooks post to.

127.0.0.1:53127, the same address and protocol as the macOS app. Each request
gets its own thread; a blocking hook (a permission or a question) holds its
connection open until the card is answered or the decision window closes,
and nobody answering means "no opinion", so Claude Code asks in its terminal.
"""

from __future__ import annotations

import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from . import hooks, protocol, statusline
from .state import AppState, PermissionCard, QuestionCard

MAX_BODY = 2 * 1024 * 1024


def _snake(key: str) -> str:
    return re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", key).lower()


def normalize(payload: dict) -> dict:
    """camelCase top-level keys (Codex and others) read as Claude's snake_case.
    tool_input is left exactly as sent: it is the tool's own argument shape."""
    return {(_snake(k) if isinstance(k, str) else k): v for k, v in payload.items()}


class _Handler(BaseHTTPRequestHandler):
    server_version = "ClaudeNotch-Linux"
    protocol_version = "HTTP/1.1"

    # Quiet: the default handler logs every request to stderr.
    def log_message(self, fmt, *args):  # noqa: D401
        pass

    def version_string(self) -> str:
        return self.app.server_name

    @property
    def app(self) -> "HookServer":
        return self.server.app  # type: ignore[attr-defined]

    def _reply(self, text: str, status: int = 200) -> None:
        data = text.encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Claude Code gave up waiting; nothing to tell it.

    def _refuse(self) -> None:
        # Close without a reply, as the Mac does: a page in a browser or a
        # process without the token learns nothing from us.
        self.close_connection = True

    def do_GET(self):
        if urlsplit(self.path).path == "/ping" and protocol.is_local_request(dict(self.headers)):
            # The version lets a newer launch tell an older running copy apart.
            from . import __version__
            self._reply(json.dumps({"ok": True, "app": self.app.app_id, "version": __version__}))
        else:
            self._refuse()

    def do_POST(self):
        url = urlsplit(self.path)
        if not protocol.is_local_request(dict(self.headers)):
            return self._refuse()
        if not protocol.token_allows(url.query, self.app.expected_token()):
            return self._refuse()
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length > MAX_BODY:
            return self._refuse()
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            payload = json.loads(raw.decode("utf-8")) if raw else {}
        except (ValueError, UnicodeDecodeError):
            payload = {}
        if not isinstance(payload, dict):
            payload = {}
        payload = normalize(payload)

        path = url.path.lower()
        if path == "/ping":
            return self._reply(protocol.OK_BODY)
        if path == "/notification":
            # The plain endpoint the old command hooks and `curl` tests use.
            payload.setdefault("hook_event_name", "Notification")
            self.app.state.handle_event(payload)
            return self._reply(protocol.OK_BODY)
        if path.startswith("/control/"):
            # Another launch of this app talking to the running one: open
            # Settings, or quit so a newer version can take over. Same
            # Origin, Host and token checks as a hook.
            done = self.app.control(path[len("/control/"):])
            return self._reply(protocol.OK_BODY if done else '{"ok":false}', 200 if done else 404)
        if path == "/statusline":
            # A pure data feed, sent on every status redraw: it updates the
            # meters and never starts or ends a session's life.
            self.app.state.note_status(statusline.parse(payload))
            return self._reply(protocol.OK_BODY)
        if path != "/hook":
            return self._reply(protocol.OK_BODY)
        self._reply(self.app.answer(payload))


class HookServer:
    def __init__(self, state: AppState, host: str = "127.0.0.1", port: int = hooks.PORT,
                 window: float = protocol.DECISION_WINDOW, app_id: str | None = None):
        import sys
        self.state = state
        # Which edition answers /ping and the Server header.
        self.app_id = app_id or ("claudenotch-windows" if sys.platform == "win32" else "claudenotch-linux")
        self.server_name = "ClaudeNotch-Windows" if self.app_id.endswith("windows") else "ClaudeNotch-Linux"
        self.window = window
        self._token_cache: tuple[float, str | None] = (-1.0, None)
        self._httpd = ThreadingHTTPServer((host, port), _Handler)
        self._httpd.daemon_threads = True
        self._httpd.app = self  # type: ignore[attr-defined]
        self._thread: threading.Thread | None = None
        # action name -> callable, filled in by the app ("settings", "quit").
        self.controls: dict = {}
        # Set while the user has paused the app: blocking hooks get "no
        # opinion" at once and Claude Code asks in its terminal.
        self.paused = threading.Event()

    def control(self, action: str) -> bool:
        """"settings", "quit", or "name:argument" for a handler that takes one
        (the Windows app's "settings:privacy"). Unknown names do nothing."""
        name, _, arg = action.partition(":")
        handler = self.controls.get(name)
        if handler is None:
            return False
        if arg:
            try:
                handler(arg[:64])
            except TypeError:
                return False
        else:
            handler()
        return True

    @property
    def port(self) -> int:
        return self._httpd.server_address[1]

    def expected_token(self) -> str | None:
        # Re-read when settings.json changes, so installing the hooks while
        # running switches the check on without a restart.
        import os
        try:
            mtime = os.stat(hooks.settings_path()).st_mtime
        except OSError:
            mtime = 0.0
        if mtime != self._token_cache[0]:
            self._token_cache = (mtime, hooks.expected_token())
        return self._token_cache[1]

    def start(self) -> None:
        self._thread = threading.Thread(target=self._httpd.serve_forever, name="hook-server", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._httpd.shutdown()
        self._httpd.server_close()

    # --- answering one hook ------------------------------------------------

    def answer(self, payload: dict) -> str:
        kind = protocol.classify(payload)
        if kind == protocol.PASS:
            return protocol.pretool_body(protocol.ASK)
        if self.paused.is_set() and kind in (protocol.PERMISSION, protocol.PERM_REQUEST, protocol.QUESTION):
            return protocol.timeout_body(kind) if kind != protocol.QUESTION else protocol.OK_BODY
        if kind in (protocol.PERMISSION, protocol.PERM_REQUEST):
            return self._wait_for_permission(kind, payload)
        if kind == protocol.QUESTION:
            return self._wait_for_question(payload)
        self.state.handle_event(payload)
        return protocol.OK_BODY

    def _wait_for_permission(self, kind: str, payload: dict) -> str:
        done = threading.Event()
        result: list = [protocol.ASK, None]

        def resolve(decision: str, reason: str | None) -> None:
            result[0], result[1] = decision, reason
            done.set()

        tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
        card = PermissionCard(str(payload.get("tool_name") or "tool"), tool_input, str(payload.get("cwd") or ""),
                              kind, str(payload.get("session_id") or ""), resolve=resolve)
        card.permission_mode = str(payload.get("permission_mode") or "")[:32]
        self.state.enqueue_permission(card)
        if not done.wait(self.window):
            self.state.drop_permission(card.id)
            return protocol.timeout_body(kind)
        decision, reason = result
        if kind == protocol.PERM_REQUEST:
            return protocol.permreq_body(decision)
        return protocol.pretool_body(decision, reason)

    def _wait_for_question(self, payload: dict) -> str:
        questions = protocol.parse_questions(payload)
        if not questions:
            return protocol.OK_BODY
        done = threading.Event()
        result: list = [None]

        def resolve(answers):
            result[0] = answers
            done.set()

        card = QuestionCard(questions, str(payload.get("cwd") or ""), str(payload.get("session_id") or ""),
                            resolve=resolve)
        self.state.enqueue_question(card)
        if not done.wait(self.window):
            self.state.drop_question(card.id)
            return protocol.OK_BODY
        if not result[0]:
            return protocol.OK_BODY
        return protocol.answers_body(questions, result[0])
