# PyInstaller spec for ClaudeNotch.exe (ticket W15).
#   pyinstaller --noconfirm --clean windows\packaging\claudenotch.spec
# --onedir, not --onefile: onefile unpacks to %TEMP% on every launch, starts
# slowly and trips antivirus heuristics far more often. No console window.
# -*- mode: python -*-
import os
import re

# SPECPATH is the folder this spec is in (windows\packaging).
WIN = os.path.abspath(os.path.join(SPECPATH, ".."))
REPO = os.path.dirname(WIN)
CORE = os.path.join(REPO, "linux")

with open(os.path.join(CORE, "claudenotch", "__init__.py"), encoding="utf-8") as f:
    VERSION = re.search(r'__version__\s*=\s*"([^"]+)"', f.read()).group(1)

# Qt modules we never use: keeps the install around 60 to 80 MB.
EXCLUDES = [
    "PySide6.QtWebEngineCore", "PySide6.QtWebEngineWidgets", "PySide6.QtWebEngineQuick",
    "PySide6.QtQml", "PySide6.QtQuick", "PySide6.QtQuickWidgets", "PySide6.Qt3DCore",
    "PySide6.QtMultimedia", "PySide6.QtMultimediaWidgets", "PySide6.QtCharts",
    "PySide6.QtDataVisualization", "PySide6.QtPdf", "PySide6.QtPdfWidgets", "PySide6.QtSql",
    "PySide6.QtTest", "PySide6.QtDesigner", "PySide6.QtBluetooth", "PySide6.QtPositioning",
    "PySide6.QtSerialPort", "PySide6.QtSensors", "PySide6.QtNfc", "PySide6.QtOpenGL",
    "PySide6.QtOpenGLWidgets", "PySide6.QtSvgWidgets", "PySide6.QtNetwork",
    "tkinter", "unittest", "pydoc", "gi",
]

a = Analysis(
    [os.path.join(WIN, "packaging", "entry.py")],
    pathex=[CORE, WIN],
    datas=[(os.path.join(WIN, "resources"), "resources")],
    hiddenimports=["claudenotch_win.qtapp", "claudenotch_win.overlay", "claudenotch_win.tray",
                   "claudenotch_win.notify", "claudenotch_win.settings_window"],
    excludes=EXCLUDES,
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="ClaudeNotch",
    icon=os.path.join(WIN, "resources", "ClaudeNotch.ico"),
    version=os.path.join(WIN, "build", "version_info.txt"),
    console=False,
    disable_windowed_traceback=False,
    upx=False,
)
coll = COLLECT(exe, a.binaries, a.datas, name="ClaudeNotch", upx=False)
