import os
import sys
import tempfile
import unittest
from unittest import mock

from claudenotch import autostart


@unittest.skipIf(sys.platform == "win32", "XDG autostart is the Linux edition's; Windows has its own")
class AutostartTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg = os.path.join(self.tmp.name, "config")
        self.sys = os.path.join(self.tmp.name, "xdg")
        self.env = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": self.cfg})
        self.env.start()
        self.dirs = mock.patch.object(autostart, "SYSTEM_DIRS", [self.sys])
        self.dirs.start()

    def tearDown(self):
        self.dirs.stop()
        self.env.stop()
        self.tmp.cleanup()

    def _system_entry(self):
        os.makedirs(os.path.join(self.sys, "autostart"))
        with open(os.path.join(self.sys, "autostart", autostart.NAME), "w") as f:
            f.write("[Desktop Entry]\nType=Application\nExec=claudenotch\n")

    def test_deb_install_turned_off_and_on_again(self):
        self._system_entry()
        self.assertTrue(autostart.enabled())
        autostart.set_enabled(False)
        self.assertFalse(autostart.enabled())
        autostart.set_enabled(True)
        self.assertTrue(autostart.enabled())
        self.assertFalse(os.path.exists(os.path.join(autostart.user_dir(), autostart.NAME)),
                         "back on means the override is simply gone")

    def test_user_install(self):
        self.assertFalse(autostart.enabled())
        autostart.set_enabled(True, "/home/a/.local/bin/claudenotch")
        self.assertTrue(autostart.enabled())
        with open(os.path.join(autostart.user_dir(), autostart.NAME)) as f:
            self.assertIn("Exec=/home/a/.local/bin/claudenotch", f.read())
        autostart.set_enabled(False)
        self.assertFalse(autostart.enabled())


if __name__ == "__main__":
    unittest.main()
