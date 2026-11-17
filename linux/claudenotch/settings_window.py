"""The Settings window: everything about ClaudeNotch you can change.

An ordinary desktop window in the system theme (not the black notch style),
with a sidebar of pages, as on the Mac. Opened from the notch's right-click
menu, from the app menu entry's Settings action, by launching the app again
while it runs, or with `claudenotch --settings`.

One window at a time: asking again brings the open one to the front.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Pango  # noqa: E402

from . import __version__, autostart, hooks  # noqa: E402
from .settings import Store  # noqa: E402
from .state import AppState  # noqa: E402

GITHUB = "https://github.com/rawsun007/claude-notch"


def _heading(text: str) -> Gtk.Label:
    lbl = Gtk.Label(xalign=0)
    lbl.set_markup(f"<b>{GLib_escape(text)}</b>")
    lbl.set_margin_top(6)
    return lbl


def GLib_escape(text: str) -> str:
    from gi.repository import GLib
    return GLib.markup_escape_text(text)


def _note(text: str) -> Gtk.Label:
    lbl = Gtk.Label(label=text, xalign=0)
    lbl.set_line_wrap(True)
    lbl.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
    lbl.set_max_width_chars(60)
    lbl.get_style_context().add_class("dim-label")
    return lbl


class SettingsWindow(Gtk.Window):
    _open: "SettingsWindow | None" = None

    @classmethod
    def present_for(cls, state: AppState, store: Store, page: str | None = None) -> "SettingsWindow":
        if cls._open is None:
            cls._open = SettingsWindow(state, store)
        win = cls._open
        if page:
            win.stack.set_visible_child_name(page)
        win.refresh()
        win.show_all()
        win.present()
        return win

    def __init__(self, state: AppState, store: Store):
        super().__init__(title="ClaudeNotch Settings")
        self.state, self.store = state, store
        self.set_default_size(720, 480)
        self.set_icon_name("claudenotch")
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("destroy", self._on_destroy)
        self.switches: dict[str, Gtk.Switch] = {}
        self._refreshing = False
        self._alive = True

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        sidebar = Gtk.StackSidebar()
        sidebar.set_stack(self.stack)
        sidebar.set_size_request(170, -1)

        self.stack.add_titled(self._page_general(), "general", "General")
        self.stack.add_titled(self._page_notifications(), "notifications", "Notifications")
        self.stack.add_titled(self._page_claude(), "claude", "Claude Code")
        self.stack.add_titled(self._page_rules(), "rules", "Always allow")
        self.stack.add_titled(self._page_about(), "about", "About")

        box = Gtk.Box()
        box.pack_start(sidebar, False, False, 0)
        box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.VERTICAL), False, False, 0)
        box.pack_start(self.stack, True, True, 0)
        self.add(box)

        state.subscribe(lambda: _idle(self._refresh_rules))

    def _on_destroy(self, *_):
        self._alive = False
        SettingsWindow._open = None

    # --- building blocks ------------------------------------------------------

    def _page(self) -> Gtk.Box:
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        for side in ("top", "bottom", "start", "end"):
            getattr(page, f"set_margin_{side}")(22)
        return page

    def _switch_row(self, page: Gtk.Box, key: str, title: str, note: str, on_set=None) -> Gtk.Switch:
        row = Gtk.Box(spacing=12)
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        text.pack_start(Gtk.Label(label=title, xalign=0), False, False, 0)
        if note:
            text.pack_start(_note(note), False, False, 0)
        sw = Gtk.Switch()
        sw.set_valign(Gtk.Align.CENTER)
        sw.set_name(f"switch-{key}")

        def changed(s, _pspec):
            if self._refreshing:
                return   # we set it to match the settings; not a click
            value = s.get_active()
            if on_set is not None:
                on_set(value)
            else:
                self.store.update(**{key: value})
            self.refresh()

        sw.connect("notify::active", changed)
        row.pack_start(text, True, True, 0)
        row.pack_end(sw, False, False, 0)
        page.pack_start(row, False, False, 4)
        self.switches[key] = sw
        return sw

    # --- pages ------------------------------------------------------------------

    def _page_general(self) -> Gtk.Widget:
        p = self._page()
        p.pack_start(_heading("General"), False, False, 0)
        self._switch_row(p, "start_at_login", "Start at login",
                         "Open ClaudeNotch when you log in, so prompts reach the notch from the first session.",
                         on_set=self._set_autostart)
        self._switch_row(p, "greeting", "Say hello at start",
                         "Show \"ClaudeNotch is running\" for a few seconds after it starts.")
        self._switch_row(p, "hover_sessions", "Show sessions on hover",
                         "Pointing at the notch opens the list of Claude Code sessions.")
        self._switch_row(p, "toasts", "Show session updates",
                         "A short note in the notch when a session finishes or Claude Code sends a notice.")
        return p

    def _page_notifications(self) -> Gtk.Widget:
        p = self._page()
        p.pack_start(_heading("Desktop notifications"), False, False, 0)
        p.pack_start(_note("Permission and question cards always appear in the notch. These also send them to your "
                           "desktop's notification area, which helps when the notch is on another screen or "
                           "behind a fullscreen window. On Ubuntu the notification banner shows at the top of the "
                           "screen, over the card, so they are off unless you want them."), False, False, 0)
        self._switch_row(p, "desktop_notifications", "Notify for every card",
                         "A desktop notification for each permission request and question.")
        self._switch_row(p, "notify_dangerous_only", "Notify for dangerous calls only",
                         "Just for calls that get the red warning, such as rm -rf or sudo.")
        return p

    def _page_claude(self) -> Gtk.Widget:
        p = self._page()
        p.pack_start(_heading("Claude Code hooks"), False, False, 0)
        p.pack_start(_note("ClaudeNotch hears from Claude Code through hooks in its settings file. Your own hooks "
                           "are kept, and a backup is written before any change. Sessions read the hooks when they "
                           "start, so a session that was already open needs restarting."), False, False, 0)
        self.hooks_status = Gtk.Label(xalign=0)
        self.hooks_status.set_selectable(True)
        p.pack_start(self.hooks_status, False, False, 4)
        row = Gtk.Box(spacing=8)
        self.install_btn = Gtk.Button(label="Install hooks")
        self.install_btn.connect("clicked", lambda *_: self._hooks(hooks.install))
        self.remove_btn = Gtk.Button(label="Remove hooks")
        self.remove_btn.connect("clicked", lambda *_: self._hooks(hooks.uninstall))
        row.pack_start(self.install_btn, False, False, 0)
        row.pack_start(self.remove_btn, False, False, 0)
        p.pack_start(row, False, False, 0)
        self.hooks_error = _note("")
        p.pack_start(self.hooks_error, False, False, 0)
        return p

    def _page_rules(self) -> Gtk.Widget:
        p = self._page()
        p.pack_start(_heading("Always allow"), False, False, 0)
        p.pack_start(_note("Calls you allowed with Always allow are answered without a card. Dangerous calls "
                           "never are, whatever is listed here."), False, False, 0)
        self.rules_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.add(self.rules_box)
        p.pack_start(scroller, True, True, 0)
        self._refresh_rules()
        return p

    def _page_about(self) -> Gtk.Widget:
        p = self._page()
        title = Gtk.Label(xalign=0)
        title.set_markup(f"<big><b>ClaudeNotch for Linux</b></big>\nVersion {GLib_escape(__version__)}")
        p.pack_start(title, False, False, 0)
        from .app import log_path
        p.pack_start(_note(f"Log: {log_path()}\nSettings: {os.path.dirname(hooks.settings_path())}"), False, False, 0)
        row = Gtk.Box(spacing=8)
        log_btn = Gtk.Button(label="Open log")
        log_btn.connect("clicked", lambda *_: _open_path(log_path()))
        site = Gtk.LinkButton.new_with_label(GITHUB, "Project page")
        quit_btn = Gtk.Button(label="Quit ClaudeNotch")
        quit_btn.get_style_context().add_class("destructive-action")
        quit_btn.connect("clicked", lambda *_: Gtk.main_quit())
        row.pack_start(log_btn, False, False, 0)
        row.pack_start(site, False, False, 0)
        row.pack_end(quit_btn, False, False, 0)
        p.pack_start(row, False, False, 8)
        return p

    # --- state -------------------------------------------------------------------

    def refresh(self) -> None:
        self._refreshing = True
        try:
            self._refresh()
        finally:
            self._refreshing = False

    def _refresh(self) -> None:
        v = self.store.value
        values = {
            "start_at_login": autostart.enabled(),
            "greeting": v.greeting,
            "hover_sessions": v.hover_sessions,
            "toasts": v.toasts,
            "desktop_notifications": v.desktop_notifications,
            "notify_dangerous_only": v.notify_dangerous_only,
        }
        for key, value in values.items():
            sw = self.switches.get(key)
            if sw is not None and sw.get_active() != value:
                sw.set_active(value)
        if "notify_dangerous_only" in self.switches:
            # Every card already notifies; the narrower switch means nothing then.
            self.switches["notify_dangerous_only"].set_sensitive(not v.desktop_notifications)
        on = hooks.installed()
        self.hooks_status.set_markup(
            f"{'<b>Installed</b>' if on else '<b>Not installed</b>'} in {GLib_escape(hooks.settings_path())}")
        self.install_btn.set_label("Reinstall hooks" if on else "Install hooks")
        self.remove_btn.set_sensitive(on)

    def _refresh_rules(self) -> bool:
        if not self._alive:
            return False   # closed; the state listener outlives the window
        for child in self.rules_box.get_children():
            self.rules_box.remove(child)
        rules = list(self.state.rules)
        if not rules:
            self.rules_box.pack_start(_note("Nothing yet. Use Always allow on a card to add one."), False, False, 0)
        for rule in rules:
            row = Gtk.Box(spacing=8)
            lbl = Gtk.Label(label=rule.label(), xalign=0)
            lbl.set_ellipsize(Pango.EllipsizeMode.END)
            lbl.set_selectable(True)
            btn = Gtk.Button(label="Remove")
            btn.connect("clicked", lambda _b, r=rule: self.state.remove_rule(r))
            row.pack_start(lbl, True, True, 0)
            row.pack_end(btn, False, False, 0)
            self.rules_box.pack_start(row, False, False, 0)
        self.rules_box.show_all()
        return False

    def _set_autostart(self, on: bool) -> None:
        exec_path = os.path.realpath(sys.argv[0]) if sys.argv and sys.argv[0] else "claudenotch"
        if exec_path.startswith("/usr/"):
            exec_path = "claudenotch"
        try:
            autostart.set_enabled(on, exec_path)
        except OSError as e:
            self.hooks_error.set_text(f"Could not change start at login: {e.strerror}")
        self.store.update(start_at_login=on)

    def _hooks(self, action) -> None:
        try:
            action()
            self.hooks_error.set_text("")
        except hooks.UnreadableSettings as e:
            self.hooks_error.set_text(str(e))
        self.refresh()


def _idle(fn) -> None:
    from gi.repository import GLib
    GLib.idle_add(fn)


def _open_path(path: str) -> None:
    opener = shutil.which("xdg-open")
    if opener and os.path.exists(path):
        subprocess.Popen([opener, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
