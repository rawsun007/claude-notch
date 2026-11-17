import unittest
from unittest import mock

from claudenotch import protocol, settings
from claudenotch.notify import DesktopNotifier, wanted
from claudenotch.state import AppState, PermissionCard


class WantedTests(unittest.TestCase):
    def test_rules(self):
        self.assertFalse(wanted(False, False, True))
        self.assertTrue(wanted(True, False, False))
        self.assertTrue(wanted(False, True, True))
        self.assertFalse(wanted(False, True, False))


class NotifierTests(unittest.TestCase):
    def _run(self, **cfg):
        state, store = AppState(persist=False), settings.Store(persist=False)
        store.update(**cfg) if cfg else None
        with mock.patch("shutil.which", return_value="/usr/bin/notify-send"), \
             mock.patch("subprocess.Popen") as popen:
            DesktopNotifier(state, store)
            state.enqueue_permission(PermissionCard("Bash", {"command": "npm test"}, "/p", protocol.PERMISSION))
            state.enqueue_permission(PermissionCard("Bash", {"command": "sudo ls"}, "/p", protocol.PERMISSION))
            return [c.args[0][-2] for c in popen.call_args_list]

    def test_off_by_default(self):
        self.assertEqual(self._run(), [])

    def test_on(self):
        self.assertEqual(len(self._run(desktop_notifications=True)), 2)

    def test_dangerous_only(self):
        self.assertEqual(len(self._run(notify_dangerous_only=True)), 1)


if __name__ == "__main__":
    unittest.main()
