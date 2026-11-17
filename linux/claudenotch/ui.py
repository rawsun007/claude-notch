"""The card at the top of the screen. GTK 3 through PyGObject.

Linux laptops have no notch, so this is the Dynamic-Island-style pill the
macOS app draws on displays without one: a small black shape hanging from the
top centre that grows into a card when Claude needs an answer, and into the
session list when the cursor is on it.

All drawing happens on the GTK main thread. AppState calls back from server
threads, so its listener only schedules a render with GLib.idle_add.
"""

from __future__ import annotations

import json
import os
import time

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk, Pango  # noqa: E402

from . import protocol  # noqa: E402
from .layout import card_origin  # noqa: E402
from .state import AppState  # noqa: E402

try:  # Optional: a real overlay layer on wlroots / KDE Wayland compositors.
    gi.require_version("GtkLayerShell", "0.1")
    from gi.repository import GtkLayerShell  # type: ignore
except (ValueError, ImportError):
    GtkLayerShell = None

PILL_WIDTH = 240
CARD_WIDTH = 600
TOAST_SECONDS = 4.0
CONFIRM_SECONDS = 4.0
COLLAPSE_DELAY_MS = 350
DIFF_LINES = 12

CSS = b"""
window.claudenotch { background-color: transparent; }
.notch {
    background-color: #000000;
    border-radius: 0 0 18px 18px;
    padding: 8px 22px 14px 22px;
    color: #ffffff;
}
.notch.pill { padding: 6px 16px 8px 16px; border-radius: 0 0 14px 14px; }
.notch label { color: #ffffff; }
.title { font-weight: bold; font-size: 13px; }
.notch label.muted { color: rgba(255,255,255,0.55); font-size: 11px; }
.notch label.status { font-size: 11px; color: rgba(255,255,255,0.8); }
.notch label.dot-working { color: #f5a623; }
.notch label.dot-waiting { color: #ff6b5a; }
.notch label.dot-ready { color: #3ecf6e; }
.code {
    font-family: monospace; font-size: 11px;
    background-color: #161616; border-radius: 8px; padding: 8px 10px;
}
.notch label.diff-del { font-family: monospace; font-size: 11px; color: #ff8a80; background-color: rgba(255,80,80,0.12); }
.notch label.diff-add { font-family: monospace; font-size: 11px; color: #9be89b; background-color: rgba(80,255,120,0.10); }
.danger {
    background-color: rgba(255,120,40,0.16); border-radius: 8px; padding: 8px 10px;
}
.notch .danger label { color: #ffb37a; font-size: 11px; }
.notch .danger label.title { color: #ff9a4d; font-size: 12px; }
button {
    background-image: none; background-color: #262626; color: #ffffff;
    border: none; border-radius: 8px; padding: 5px 14px; box-shadow: none; text-shadow: none;
}
button:hover { background-color: #333333; }
button label { color: #ffffff; }
button.primary { background-color: #d97757; }
button.primary:hover { background-color: #e08a6c; }
button.warn { background-color: #c2410c; }
radiobutton label, checkbutton label { color: #ffffff; font-size: 12px; }
.notch label.option-desc { color: rgba(255,255,255,0.5); font-size: 11px; }
.session-row { padding: 3px 0; }
"""


def _label(text: str, *classes: str, wrap: bool = False, mono: bool = False, select: bool = False,
           max_chars: int | None = None, xalign: float = 0.0) -> Gtk.Label:
    lbl = Gtk.Label(label=text)
    lbl.set_xalign(xalign)
    if wrap:
        lbl.set_line_wrap(True)
        lbl.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
    else:
        lbl.set_ellipsize(Pango.EllipsizeMode.END)
    if max_chars:
        lbl.set_max_width_chars(max_chars)
    if select:
        lbl.set_selectable(True)
    ctx = lbl.get_style_context()
    for c in classes:
        ctx.add_class(c)
    if mono:
        ctx.add_class("code")
    return lbl


def _trim_lines(text: str, limit: int) -> tuple[list[str], bool]:
    lines = text.splitlines() or [""]
    return lines[:limit], len(lines) > limit


class NotchWindow(Gtk.Window):
    def __init__(self, state: AppState, layout_dump: str | None = None):
        super().__init__(title="ClaudeNotch")
        self.state = state
        self.layout_dump = layout_dump or os.environ.get("CLAUDENOTCH_LAYOUT_DUMP")
        self.hovering = False
        self._collapse_source = None
        self._shown_key = None
        self._confirm_until: dict[int, float] = {}
        self._buttons: dict[str, Gtk.Widget] = {}
        self._question_inputs: list[list[tuple[str, Gtk.ToggleButton]]] = []

        self.get_style_context().add_class("claudenotch")
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.stick()
        self.set_accept_focus(True)
        self.set_focus_on_map(False)   # never take the keyboard from the terminal on its own
        self.set_type_hint(Gdk.WindowTypeHint.DOCK)
        self.set_app_paintable(True)
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None and screen.is_composited():
            self.set_visual(visual)

        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        self._layer = False
        if GtkLayerShell is not None and _on_wayland() and GtkLayerShell.is_supported():
            GtkLayerShell.init_for_window(self)
            GtkLayerShell.set_layer(self, GtkLayerShell.Layer.TOP)
            GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.TOP, True)
            GtkLayerShell.set_keyboard_mode(self, GtkLayerShell.KeyboardMode.ON_DEMAND)
            self._layer = True

        self.box = Gtk.EventBox()
        self.box.set_above_child(False)
        self.box.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        self.box.connect("enter-notify-event", self._on_enter)
        self.box.connect("leave-notify-event", self._on_leave)
        self.add(self.box)
        self.connect("key-press-event", self._on_key)
        self.connect("size-allocate", lambda *_: self._place())
        # Where the window really is is known only once the window manager
        # has applied the move, so the test layout is written from here.
        self.connect("configure-event", lambda *_: GLib.idle_add(self._dump_layout) and False)
        self.connect("delete-event", lambda *_: True)  # only Quit quits

        state.subscribe(lambda: GLib.idle_add(self.render))
        GLib.timeout_add(500, self._tick)
        self.render()
        self.show_all()

    # --- placement -----------------------------------------------------------

    def _monitor(self) -> Gdk.Monitor:
        display = Gdk.Display.get_default()
        return display.get_primary_monitor() or display.get_monitor(0)

    def _place(self) -> None:
        if self._layer:
            return
        mon = self._monitor()
        g, wa = mon.get_geometry(), mon.get_workarea()
        w, _ = self.get_size()
        x, y = card_origin((g.x, g.y, g.width, g.height), (wa.x, wa.y, wa.width, wa.height), w)
        self.move(x, y)

    # --- what to show --------------------------------------------------------

    def _tick(self) -> bool:
        # Toasts age out, the dangerous-allow confirm expires.
        now = time.monotonic()
        _, _, toasts, _ = self.state.snapshot()
        for t in toasts:
            if now - t.created > TOAST_SECONDS:
                self.state.dismiss_toast(t.id)
        expired = [cid for cid, until in self._confirm_until.items() if now > until]
        for cid in expired:
            del self._confirm_until[cid]
            self._shown_key = None
            self.render()
        return True

    def render(self) -> bool:
        perms, questions, toasts, sessions = self.state.snapshot()
        if perms:
            card = perms[0]
            key = ("perm", card.id, len(perms), card.id in self._confirm_until)
            build = lambda: self._permission_card(card, len(perms) - 1)  # noqa: E731
        elif questions:
            card = questions[0]
            key = ("question", card.id, len(questions))
            build = lambda: self._question_card(card, len(questions) - 1)  # noqa: E731
        elif self.hovering:
            key = ("sessions", tuple((s.id, s.status, s.last_prompt, s.agents) for s in sessions))
            build = lambda: self._session_list(sessions)  # noqa: E731
        elif toasts:
            t = toasts[-1]
            key = ("toast", t.id)
            build = lambda: self._toast(t)  # noqa: E731
        else:
            key = ("pill", tuple((s.id, s.status) for s in sessions))
            build = lambda: self._pill(sessions)  # noqa: E731
        if key == self._shown_key:
            return False
        self._shown_key = key
        self._buttons = {}
        child = self.box.get_child()
        if child is not None:
            self.box.remove(child)
        content = build()
        self.box.add(content)
        content.show_all()
        # Shrink to the new content, then re-centre (size-allocate calls _place).
        self.resize(1, 1)
        return False

    def _frame(self, inner: Gtk.Widget, width: int, pill: bool = False) -> Gtk.Widget:
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        outer.get_style_context().add_class("notch")
        if pill:
            outer.get_style_context().add_class("pill")
        outer.set_size_request(width, -1)
        outer.pack_start(inner, True, True, 0)
        return outer

    # --- the pill and the session list ----------------------------------------

    def _summary(self, sessions) -> tuple[str, str]:
        if not sessions:
            return "ClaudeNotch", "dot-ready"
        working = sum(1 for s in sessions if s.status == "working")
        waiting = sum(1 for s in sessions if s.status == "waiting")
        if waiting:
            return f"{waiting} waiting on you", "dot-waiting"
        if working:
            return (f"{sessions[0].project} working" if len(sessions) == 1
                    else f"{working} of {len(sessions)} working"), "dot-working"
        return (f"{sessions[0].project} ready" if len(sessions) == 1 else f"{len(sessions)} sessions ready"), "dot-ready"

    def _pill(self, sessions) -> Gtk.Widget:
        text, dot = self._summary(sessions)
        row = Gtk.Box(spacing=6)
        row.set_halign(Gtk.Align.CENTER)
        row.pack_start(_label("●", dot), False, False, 0)
        row.pack_start(_label(text, "status", max_chars=28), False, False, 0)
        return self._frame(row, PILL_WIDTH, pill=True)

    def _session_list(self, sessions) -> Gtk.Widget:
        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        v.pack_start(_label("Sessions", "title"), False, False, 2)
        if not sessions:
            v.pack_start(_label("No Claude Code sessions yet. Start one with `claude` in a terminal.",
                                "muted", wrap=True, max_chars=50), False, False, 0)
        for s in sessions:
            row = Gtk.Box(spacing=8)
            row.get_style_context().add_class("session-row")
            row.pack_start(_label("●", f"dot-{s.status}"), False, False, 0)
            row.pack_start(_label(s.project, "status"), False, False, 0)
            note = {"working": "working", "waiting": "waiting on you", "ready": "ready"}.get(s.status, s.status)
            if s.agents:
                note += f" · {s.agents} agent{'s' if s.agents != 1 else ''}"
            row.pack_end(_label(note, "muted"), False, False, 0)
            v.pack_start(row, False, False, 0)
            if s.last_prompt:
                v.pack_start(_label(s.last_prompt, "muted", max_chars=60), False, False, 0)
        return self._frame(v, 380)

    def _toast(self, t) -> Gtk.Widget:
        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        v.pack_start(_label(t.title, "title"), False, False, 0)
        if t.body:
            v.pack_start(_label(t.body, "muted", wrap=True, max_chars=60), False, False, 0)
        return self._frame(v, 360)

    # --- permission card --------------------------------------------------------

    def _permission_card(self, card, more: int) -> Gtk.Widget:
        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        head = Gtk.Box(spacing=8)
        verb = "run" if card.tool in ("Bash", "Shell", "shell") else "use"
        head.pack_start(_label(f"Claude wants to {verb} {card.title}", "title"), False, False, 0)
        tail = " · ".join(x for x in (card.project, f"+{more} more" if more else "") if x)
        if tail:
            head.pack_end(_label(tail, "muted"), False, False, 0)
        v.pack_start(head, False, False, 0)

        if card.dangers:
            d = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            d.get_style_context().add_class("danger")
            d.pack_start(_label("Careful: this can do real damage", "title"), False, False, 0)
            for r in card.dangers:
                d.pack_start(_label(f"• {r}", wrap=True, max_chars=80), False, False, 0)
            v.pack_start(d, False, False, 0)

        if card.old or card.new:
            v.pack_start(_label(card.detail, "muted", max_chars=80), False, False, 0)
            diff = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            diff.get_style_context().add_class("code")
            for text, cls, sign in ((card.old, "diff-del", "-"), (card.new, "diff-add", "+")):
                if not text:
                    continue
                lines, cut = _trim_lines(text, DIFF_LINES)
                for line in lines:
                    diff.pack_start(_label(f"{sign} {line}", cls, max_chars=90), False, False, 0)
                if cut:
                    diff.pack_start(_label("  …", "muted"), False, False, 0)
            v.pack_start(diff, False, False, 0)
        elif card.detail:
            lines, cut = _trim_lines(card.detail, 10)
            v.pack_start(_label("\n".join(lines) + ("\n…" if cut else ""), wrap=True, mono=True, select=True,
                                max_chars=90), False, False, 0)
        for x in card.extra:
            v.pack_start(_label(x, "muted", wrap=True, max_chars=80), False, False, 0)

        buttons = Gtk.Box(spacing=8)
        buttons.set_halign(Gtk.Align.END)
        buttons.set_margin_top(4)
        deny = Gtk.Button(label="Deny  Esc")
        deny.connect("clicked", lambda *_: self._decide(card, protocol.DENY))
        buttons.pack_start(deny, False, False, 0)
        self._buttons["deny"] = deny
        if not card.dangers:
            always = Gtk.Button(label="Always allow")
            always.connect("clicked", lambda *_: self._decide(card, protocol.ALLOW, always=True))
            buttons.pack_start(always, False, False, 0)
            self._buttons["always"] = always
        confirming = card.id in self._confirm_until
        allow = Gtk.Button(label=("Click again to allow" if confirming else "Allow anyway") if card.dangers
                           else "Allow  ⏎")
        allow.get_style_context().add_class("warn" if card.dangers else "primary")
        allow.connect("clicked", lambda *_: self._allow_clicked(card))
        buttons.pack_start(allow, False, False, 0)
        self._buttons["allow"] = allow
        v.pack_start(buttons, False, False, 0)
        return self._frame(v, CARD_WIDTH)

    def _allow_clicked(self, card) -> None:
        # A dangerous call takes two deliberate clicks: the first arms it, the
        # second within a few seconds allows. One stray click cannot.
        if card.dangers and card.id not in self._confirm_until:
            self._confirm_until[card.id] = time.monotonic() + CONFIRM_SECONDS
            self._shown_key = None
            self.render()
            return
        self._decide(card, protocol.ALLOW)

    def _decide(self, card, decision: str, always: bool = False) -> None:
        self._confirm_until.pop(card.id, None)
        self.state.resolve_permission(card.id, decision, always=always,
                                      reason="Denied in ClaudeNotch" if decision == protocol.DENY else None)

    # --- question card ----------------------------------------------------------

    def _question_card(self, card, more: int) -> Gtk.Widget:
        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        head = Gtk.Box(spacing=8)
        head.pack_start(_label("Claude has a question", "title"), False, False, 0)
        tail = " · ".join(x for x in (card.project, f"+{more} more" if more else "") if x)
        if tail:
            head.pack_end(_label(tail, "muted"), False, False, 0)
        v.pack_start(head, False, False, 0)
        self._question_inputs = []
        for qi, q in enumerate(card.questions):
            if q.header:
                v.pack_start(_label(q.header, "muted"), False, False, 0)
            v.pack_start(_label(q.text, "status", wrap=True, max_chars=80), False, False, 0)
            group = None
            inputs = []
            for oi, (label, desc) in enumerate(q.options):
                if q.multi_select:
                    btn = Gtk.CheckButton(label=label)
                else:
                    btn = Gtk.RadioButton.new_with_label_from_widget(group, label)
                    group = group or btn
                    if oi == 0:
                        btn.set_active(True)
                v.pack_start(btn, False, False, 0)
                self._buttons[f"q{qi}o{oi}"] = btn
                if desc:
                    d = _label(desc, "option-desc", wrap=True, max_chars=80)
                    d.set_margin_start(26)
                    v.pack_start(d, False, False, 0)
                inputs.append((label, btn))
            self._question_inputs.append(inputs)
        buttons = Gtk.Box(spacing=8)
        buttons.set_halign(Gtk.Align.END)
        skip = Gtk.Button(label="Answer in terminal")
        skip.connect("clicked", lambda *_: self.state.resolve_question(card.id, None))
        send = Gtk.Button(label="Send  ⏎")
        send.get_style_context().add_class("primary")
        send.connect("clicked", lambda *_: self._send_answers(card))
        buttons.pack_start(skip, False, False, 0)
        buttons.pack_start(send, False, False, 0)
        self._buttons["skip"] = skip
        self._buttons["send"] = send
        v.pack_start(buttons, False, False, 0)
        return self._frame(v, CARD_WIDTH)

    def _send_answers(self, card) -> None:
        answers = [[label for label, btn in inputs if btn.get_active()] for inputs in self._question_inputs]
        self.state.resolve_question(card.id, answers)

    # --- input ------------------------------------------------------------------

    def _on_enter(self, *_):
        if self._collapse_source:
            GLib.source_remove(self._collapse_source)
            self._collapse_source = None
        if not self.hovering:
            self.hovering = True
            self.render()

    def _on_leave(self, _w, event):
        # Leaving into a child widget is not leaving the card.
        if event.detail == Gdk.NotifyType.INFERIOR:
            return
        if self._collapse_source:
            GLib.source_remove(self._collapse_source)
        self._collapse_source = GLib.timeout_add(COLLAPSE_DELAY_MS, self._collapse)

    def _collapse(self):
        self._collapse_source = None
        self.hovering = False
        self.render()
        return False

    def _on_key(self, _w, event):
        perms, questions, _, _ = self.state.snapshot()
        key = event.keyval
        if perms:
            card = perms[0]
            if key in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
                self._allow_clicked(card)
                return True
            if key == Gdk.KEY_Escape:
                self._decide(card, protocol.DENY)
                return True
        elif questions:
            if key in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
                self._send_answers(questions[0])
                return True
            if key == Gdk.KEY_Escape:
                self.state.resolve_question(questions[0].id, None)
                return True
        return False

    # --- test support -----------------------------------------------------------

    def _dump_layout(self) -> bool:
        """For the headless end-to-end test: where each button is on screen, so
        it can be clicked for real with xdotool rather than poked in code."""
        if not self.layout_dump:
            return False
        win = self.get_window()
        if win is None:
            return False
        _, ox, oy = win.get_origin()
        out = {"window": {"x": ox, "y": oy, "w": self.get_allocated_width(), "h": self.get_allocated_height()},
               "shown": str(self._shown_key[0]) if self._shown_key else "", "buttons": {}}
        for name, w in self._buttons.items():
            a = w.get_allocation()
            x, y = w.translate_coordinates(self, 0, 0) or (a.x, a.y)
            out["buttons"][name] = {"x": ox + x, "y": oy + y, "w": a.width, "h": a.height}
        tmp = self.layout_dump + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(out, f)
        os.replace(tmp, self.layout_dump)
        return False


def _on_wayland() -> bool:
    display = Gdk.Display.get_default()
    return display is not None and "Wayland" in type(display).__name__
