"""Where the card goes on screen. Pure, so it is testable without a display."""

from __future__ import annotations


def card_origin(monitor: tuple[int, int, int, int], workarea: tuple[int, int, int, int] | None,
                width: int) -> tuple[int, int]:
    """Top-left corner for a card `width` wide.

    Centred on the whole monitor, so it lines up with the middle of the screen
    whatever docks sit at the sides, and hung from the top of the work area,
    not the top of the monitor: GNOME's top bar (and KDE's or XFCE's top
    panel) is drawn over every window, so a card at y=0 sits behind it. On
    stock Ubuntu that hid the idle pill completely and the first row of every
    card. Below a black top bar the black pill reads as the bar's own notch.

    `monitor` and `workarea` are (x, y, width, height). A work area that is
    missing, empty or not on this monitor is ignored.
    """
    mx, my, mw, mh = monitor
    top = my
    if workarea is not None:
        wx, wy, ww, wh = workarea
        # Only trust a work area that lies on this monitor and leaves room.
        if ww > 0 and wh > 0 and my <= wy < my + mh // 2:
            top = wy
    return mx + (mw - width) // 2, top
