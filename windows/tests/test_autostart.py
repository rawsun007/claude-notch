import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from claudenotch_win import autostart  # noqa: E402


class FakeRegistry(autostart.Registry):
    def __init__(self):
        self.values = {}

    def get(self, key, name):
        return self.values.get((key, name))

    def set_string(self, key, name, value):
        self.values[(key, name)] = value

    def set_binary(self, key, name, value):
        self.values[(key, name)] = value

    def delete(self, key, name):
        self.values.pop((key, name), None)


class AutostartTests(unittest.TestCase):
    def test_turning_it_on_and_off(self):
        reg = FakeRegistry()
        self.assertFalse(autostart.enabled(reg))
        autostart.set_enabled(True, reg)
        self.assertTrue(autostart.enabled(reg))
        self.assertTrue(reg.get(autostart.RUN_KEY, "ClaudeNotch").endswith("--background"))
        autostart.set_enabled(False, reg)
        self.assertFalse(autostart.enabled(reg))

    def test_task_managers_switch_is_respected(self):
        reg = FakeRegistry()
        autostart.set_enabled(True, reg)
        reg.set_binary(autostart.APPROVED_KEY, "ClaudeNotch", bytes([3]) + bytes(11))
        self.assertFalse(autostart.enabled(reg))
        autostart.set_enabled(True, reg)   # turning it on here clears Task Manager's "disabled"
        self.assertTrue(autostart.enabled(reg))

    def test_approved_flag(self):
        self.assertTrue(autostart.approved(None))
        self.assertTrue(autostart.approved(bytes([2]) + bytes(11)))
        self.assertTrue(autostart.approved(bytes([6]) + bytes(11)))
        self.assertFalse(autostart.approved(bytes([3]) + bytes(11)))

    def test_refresh_moves_an_old_path(self):
        reg = FakeRegistry()
        reg.set_string(autostart.RUN_KEY, "ClaudeNotch", '"C:\\old\\ClaudeNotch.exe" --background')
        autostart.refresh(reg)
        self.assertEqual(reg.get(autostart.RUN_KEY, "ClaudeNotch"), autostart.command())

    def test_refresh_leaves_it_off(self):
        reg = FakeRegistry()
        autostart.refresh(reg)
        self.assertIsNone(reg.get(autostart.RUN_KEY, "ClaudeNotch"))


if __name__ == "__main__":
    unittest.main()
