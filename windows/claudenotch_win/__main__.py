"""`python -m claudenotch_win` and the PyInstaller entry point."""

import sys

from claudenotch_win.app import main

if __name__ == "__main__":
    sys.exit(main())
