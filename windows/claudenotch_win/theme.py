"""The overlay's look: the same black notch, colours and sizes as the Linux
edition (ui.py CSS), in Qt style-sheet form, with Windows fonts.

Segoe UI Variable is the Windows 11 UI font; Segoe UI is its Windows 10
fallback. Cascadia Mono ships with Windows Terminal; Consolas is everywhere.
"""

from __future__ import annotations

BG = "#000000"
FG = "#ffffff"
MUTED = "rgba(255,255,255,0.55)"
STATUS = "rgba(255,255,255,0.80)"
CODE_BG = "#161616"
BUTTON = "#262626"
BUTTON_HOVER = "#333333"
PRIMARY = "#d97757"
PRIMARY_HOVER = "#e08a6c"
WARN = "#c2410c"
WARN_HOVER = "#d4511a"
DANGER_BG = "rgba(255,120,40,0.16)"
DANGER_FG = "#ffb37a"
DANGER_TITLE = "#ff9a4d"
DEL_FG, DEL_BG = "#ff8a80", "rgba(255,80,80,0.12)"
ADD_FG, ADD_BG = "#9be89b", "rgba(80,255,120,0.10)"

DOTS = {"working": "#f5a623", "waiting": "#ff6b5a", "ready": "#3ecf6e"}

UI_FONT = '"Segoe UI Variable Text", "Segoe UI", sans-serif'
MONO_FONT = '"Cascadia Mono", "Cascadia Code", Consolas, monospace'

RADIUS_CARD = 18
RADIUS_PILL = 14

STYLE = f"""
QWidget#notch {{ background: transparent; }}
QWidget {{ color: {FG}; font-family: {UI_FONT}; font-size: 12px; }}
QLabel {{ background: transparent; }}
QLabel[role="title"] {{ font-weight: 600; font-size: 13px; }}
QLabel[role="muted"] {{ color: {MUTED}; font-size: 11px; }}
QLabel[role="status"] {{ color: {STATUS}; font-size: 11px; }}
QLabel[role="code"] {{
    font-family: {MONO_FONT}; font-size: 11px;
    background: {CODE_BG}; border-radius: 8px; padding: 8px 10px;
}}
QWidget[role="diff"] {{ background: {CODE_BG}; border-radius: 8px; }}
QLabel[role="del"] {{ font-family: {MONO_FONT}; font-size: 11px; color: {DEL_FG}; background: {DEL_BG}; }}
QLabel[role="add"] {{ font-family: {MONO_FONT}; font-size: 11px; color: {ADD_FG}; background: {ADD_BG}; }}
QWidget[role="danger"] {{ background: {DANGER_BG}; border-radius: 8px; }}
QLabel[role="danger"] {{ color: {DANGER_FG}; font-size: 11px; }}
QLabel[role="danger-title"] {{ color: {DANGER_TITLE}; font-size: 12px; font-weight: 600; }}
QLabel[role="option-desc"] {{ color: rgba(255,255,255,0.5); font-size: 11px; }}
QPushButton {{
    background: {BUTTON}; color: {FG}; border: none; border-radius: 8px;
    padding: 5px 14px; min-height: 18px;
}}
QPushButton:hover {{ background: {BUTTON_HOVER}; }}
QPushButton[role="primary"] {{ background: {PRIMARY}; }}
QPushButton[role="primary"]:hover {{ background: {PRIMARY_HOVER}; }}
QPushButton[role="warn"] {{ background: {WARN}; }}
QPushButton[role="warn"]:hover {{ background: {WARN_HOVER}; }}
QRadioButton, QCheckBox {{ color: {FG}; font-size: 12px; background: transparent; }}
"""
