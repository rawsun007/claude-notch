"""Where the shared core keeps its files, on each platform."""

import os
import unittest
from unittest import mock

from claudenotch import hooks, state


class WindowsPathTests(unittest.TestCase):
    def test_config_dir_is_under_appdata_on_windows(self):
        with mock.patch.object(state.sys, "platform", "win32"), \
                mock.patch.dict(os.environ, {"APPDATA": "C:/Users/a/AppData/Roaming"}):
            self.assertEqual(state.config_dir(), os.path.join("C:/Users/a/AppData/Roaming", "ClaudeNotch"))

    def test_token_lives_beside_the_settings_on_windows(self):
        with mock.patch.object(state.sys, "platform", "win32"), \
                mock.patch.dict(os.environ, {"APPDATA": "C:/Users/a/AppData/Roaming"}):
            self.assertEqual(hooks.token_path(),
                             os.path.join("C:/Users/a/AppData/Roaming", "ClaudeNotch", "hook-token"))

    def test_appdata_missing_falls_back_to_the_profile(self):
        env = {k: v for k, v in os.environ.items() if k != "APPDATA"}
        with mock.patch.object(state.sys, "platform", "win32"), mock.patch.dict(os.environ, env, clear=True):
            self.assertTrue(state.config_dir().endswith(os.path.join("AppData", "Roaming", "ClaudeNotch")))


class ProjectNameTests(unittest.TestCase):
    def test_windows_and_posix_working_directories(self):
        self.assertEqual(state.project_name("C:\\Users\\a\\proj"), "proj")
        self.assertEqual(state.project_name("C:\\Users\\a\\proj\\"), "proj")
        self.assertEqual(state.project_name("C:/Users/a/proj"), "proj")
        self.assertEqual(state.project_name("/home/a/proj/"), "proj")
        self.assertEqual(state.project_name(""), "")


class LinuxPathTests(unittest.TestCase):
    def test_linux_paths_are_unchanged(self):
        with mock.patch.object(state.sys, "platform", "linux"), \
                mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": "/x/cfg"}):
            self.assertEqual(state.config_dir(), os.path.join("/x/cfg", "claudenotch"))
            self.assertEqual(hooks.token_path(), os.path.expanduser("~/.claudenotch/hook-token"))


if __name__ == "__main__":
    unittest.main()
