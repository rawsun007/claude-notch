import json
import os
import stat
import tempfile
import unittest
from unittest import mock

from claudenotch import settings


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": self.tmp.name})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_desktop_notifications_are_off_by_default(self):
        self.assertFalse(settings.load().desktop_notifications)

    def test_round_trip_and_permissions(self):
        store = settings.Store()
        store.update(desktop_notifications=True, greeting=False)
        again = settings.load()
        self.assertTrue(again.desktop_notifications)
        self.assertFalse(again.greeting)
        self.assertEqual(stat.S_IMODE(os.stat(settings.path()).st_mode), 0o600)

    def test_a_bad_file_never_stops_the_app(self):
        os.makedirs(os.path.dirname(settings.path()), exist_ok=True)
        for content in ("{ not json", "[]", json.dumps({"greeting": "yes", "unknown": 1})):
            with open(settings.path(), "w") as f:
                f.write(content)
            s = settings.load()
            self.assertTrue(s.greeting)
            self.assertFalse(s.desktop_notifications)

    def test_listeners_hear_changes(self):
        store, heard = settings.Store(persist=False), []
        store.subscribe(lambda s: heard.append(s.toasts))
        store.update(toasts=False)
        self.assertEqual(heard, [False])
        with self.assertRaises(KeyError):
            store.update(no_such_setting=True)


if __name__ == "__main__":
    unittest.main()
