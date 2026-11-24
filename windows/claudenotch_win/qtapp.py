"""Starting the windowed app: single instance, hooks, server, overlay, tray.

Order matters:
1. AppUserModelID first, so toasts and the taskbar group under our id.
2. The named mutex and /ping decide whether this launch runs, opens the
   running copy's Settings, or replaces an older running copy (W4).
3. Hooks, then the server. A port taken by something that is not us gets
   one toast and a tray icon that says "Not listening"; we never move to
   another port, since the hooks in settings.json name 53127.
4. Quitting answers every open card with "no opinion" first, so Claude
   Code falls back to its terminal prompt instead of hanging (the
   installer's Restart Manager close goes through the same path).
"""

from __future__ import annotations

import os
import signal
import sys

from claudenotch import hooks, protocol
from claudenotch import settings as settings_mod
from claudenotch.server import HookServer
from claudenotch.state import AppState

from . import __version__, autostart, instance, paths, urlscheme, winstatus, winutil
from .app import control, quit_running, running_version, say

FIRST_RUN_TIP = ("It sits at the top centre of your screen and in the tray. Windows may tuck new tray icons "
                 "under the ^ arrow; drag ClaudeNotch onto the taskbar to keep it in view.")


def run(args) -> int:
    winutil.set_app_user_model_id(paths.AUMID)
    from . import crashreport
    crashreport.install()

    # --- one copy at a time ----------------------------------------------------------
    lock = instance.SingleInstance()
    running = running_version()
    action = instance.decide(running, __version__)
    updated_from = os.environ.pop("CLAUDENOTCH_UPDATED_FROM", None)
    if action == instance.SHOW:
        # Launching it again while it runs opens its Settings, the way
        # reopening an app does, instead of quietly doing nothing.
        control("settings")
        say("ClaudeNotch is already running; opened its Settings.")
        lock.release()
        return 0
    if action == instance.TAKE_OVER:
        say(f"Replacing the running ClaudeNotch {running or '(older)'} with {__version__}.")
        quit_running()
        updated_from = updated_from or running or "an older version"
    if not lock.acquired and not lock.wait_for_release(6.0):
        say("Another ClaudeNotch is starting or stuck; not starting a second one.")
        return 1

    # --- Qt ------------------------------------------------------------------------------
    from PySide6.QtCore import QTimer
    from PySide6.QtGui import QIcon
    from PySide6.QtWidgets import QApplication, QSystemTrayIcon

    app = QApplication.instance() or QApplication(sys.argv)
    app.setApplicationName("ClaudeNotch")
    app.setApplicationDisplayName("ClaudeNotch")
    app.setApplicationVersion(__version__)
    app.setQuitOnLastWindowClosed(False)       # Settings closing must not quit the tray app
    app.setWindowIcon(QIcon(paths.resource("ClaudeNotch.ico")))

    # --- hooks and server ---------------------------------------------------------------
    store = settings_mod.Store()
    hook_error = ""
    if not args.no_install:
        try:
            winstatus.install_hooks()
        except hooks.UnreadableSettings as e:
            hook_error = str(e)
    state = AppState()
    server = None
    listen_error = ""
    try:
        server = HookServer(state, app_id="claudenotch-windows")
    except OSError as e:
        listen_error = f"127.0.0.1:{hooks.PORT} is in use by another program"
        say(f"ClaudeNotch: cannot listen on 127.0.0.1:{hooks.PORT} ({e.strerror}).")

    # --- UI -------------------------------------------------------------------------------
    from .notify import Notifier
    from .overlay import Overlay
    from .settings_window import SettingsWindow
    from .tray import Tray

    quitting = {"done": False}

    def open_settings(page=None):
        SettingsWindow.present(state, store, page, on_quit=quit_app, overlay=overlay)

    def quit_app():
        if quitting["done"]:
            return
        quitting["done"] = True
        release_open_cards(state)
        app.quit()

    overlay = Overlay(state, store=store, on_settings=open_settings, on_quit=quit_app)
    tray = Tray(overlay, store, on_settings=open_settings, on_quit=quit_app,
                paused=server.paused if server is not None else None)
    tray.show()
    Notifier(state, store, tray, overlay)

    # --- system-wide shortcuts (the Mac's GlobalHotkey) -------------------------------------
    from . import hotkeys
    keys = hotkeys.APP = hotkeys.GlobalHotkeys()
    bound: dict = {}

    def apply_hotkeys() -> None:
        want = {hotkeys.SETTINGS_ID: (store.value.settings_hotkey, lambda: open_settings()),
                hotkeys.NOTCH_ID: (store.value.notch_hotkey, lambda: overlay.show_sessions(8)),
                hotkeys.HISTORY_ID: (store.value.history_hotkey, overlay.toggle_history)}
        for ident, (text, action) in want.items():
            if bound.get(ident) != text:
                bound[ident] = text
                keys.register(ident, text, action)
        tray.set_shortcuts(store.value.settings_hotkey, store.value.notch_hotkey, store.value.history_hotkey)

    apply_hotkeys()
    # Is a newer ClaudeNotch out? At start, then daily (the Mac's UpdateChecker).
    from . import updater
    updater.APP = updater.Updater(app)
    updater.APP.available.connect(tray.show_update)
    updater.APP.start()

    # The taskbar and Start jump list: Open the Notch, Settings, Usage, History.
    from . import jumplist
    QTimer.singleShot(1500, jumplist.install)
    store.subscribe(lambda _s: QTimer.singleShot(0, apply_hotkeys))
    app.aboutToQuit.connect(keys.unregister_all)

    if server is not None:
        # Called on server threads: hop to the GUI thread with a 0 ms timer
        # posted through a queued signal on the overlay's bridge.
        from PySide6.QtCore import QObject, Signal

        class _Controls(QObject):
            settings = Signal(str)
            open_notch = Signal()
            standup = Signal()
            history = Signal()
            quit = Signal()

        controls = _Controls()
        controls.settings.connect(lambda page: open_settings(page or None))
        controls.open_notch.connect(lambda: overlay.show_sessions(8))
        controls.quit.connect(quit_app)
        server.controls["settings"] = lambda page="": controls.settings.emit(page)
        server.controls["open"] = controls.open_notch.emit
        controls.standup.connect(tray.copy_standup)
        server.controls["standup"] = controls.standup.emit
        controls.history.connect(overlay.open_history)
        server.controls["history"] = controls.history.emit
        server.controls["quit"] = controls.quit.emit
        server.start()
    else:
        tray.set_listening(False, "port in use")
        tray.showMessage("ClaudeNotch is not listening",
                         f"{listen_error}. Close that program, then start ClaudeNotch again. "
                         "Claude Code keeps asking in its terminal meanwhile.", QSystemTrayIcon.MessageIcon.Warning, 15000)

    # --- start at login --------------------------------------------------------------------
    try:
        if args.first_run and store.value.start_at_login:
            autostart.set_enabled(True)
        else:
            autostart.refresh()
    except OSError:
        pass

    # --- hello ------------------------------------------------------------------------------
    if hook_error:
        tray.showMessage("ClaudeNotch could not install its hooks",
                         f"{hook_error}. Fix it, then use Settings > Claude Code > Install hooks.",
                         QSystemTrayIcon.MessageIcon.Warning, 15000)
    if args.first_run:
        state.greet(version=__version__)
        tray.showMessage("ClaudeNotch is running", FIRST_RUN_TIP, QSystemTrayIcon.MessageIcon.Information, 12000)
    elif updated_from or (store.value.greeting and not args.background):
        state.greet(updated_from=updated_from, version=__version__)
    if args.settings:
        QTimer.singleShot(0, open_settings)
    link = urlscheme.parse(getattr(args, "url", None) or "") if getattr(args, "url", None) else None
    if link is not None:
        verb, page = link
        QTimer.singleShot(300, (lambda: open_settings(page or None)) if verb == "settings"
                          else tray.copy_standup if verb == "standup"
                          else overlay.open_history if verb == "history"
                          else (lambda: overlay.show_sessions(8)))

    # Ctrl+C in a console run: let Python see the signal now and then.
    signal.signal(signal.SIGINT, lambda *_: quit_app())
    pulse = QTimer(interval=500)
    pulse.timeout.connect(lambda: None)
    pulse.start()

    say(f"ClaudeNotch {__version__} listening on 127.0.0.1:{hooks.PORT}" if server else
        f"ClaudeNotch {__version__} started without listening")
    code = app.exec()
    release_open_cards(state)
    if server is not None:
        server.stop()
    lock.release()
    return code


def release_open_cards(state: AppState) -> None:
    """Answer every waiting card with no opinion, so Claude Code asks in its
    terminal right away rather than waiting out a hook whose app is gone."""
    perms, questions, _, _ = state.snapshot()
    for card in perms:
        state.resolve_permission(card.id, protocol.ASK)
    for q in questions:
        state.resolve_question(q.id, None)
