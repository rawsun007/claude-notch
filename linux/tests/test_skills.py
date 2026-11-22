import json
import os
import tempfile
import time
import unittest
from unittest import mock

from claudenotch import skills


def make(root, rel, fm, body="x"):
    d = os.path.join(root, rel)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "SKILL.md"), "w", encoding="utf-8") as f:
        f.write(fm + "\n" + body)
    return d


class FrontmatterTests(unittest.TestCase):
    def test_flat_keys_blocks_quotes_bom(self):
        fm = skills.frontmatter("﻿---\r\nname: \"deploy\"\r\ndescription: >\r\n  Ship it\r\n  carefully\r\n"
                                "tags:\r\n  - a\r\ndisable-model-invocation: true\r\n---\r\nbody")
        self.assertEqual(fm["name"], "deploy")
        self.assertEqual(fm["description"], "Ship it carefully")
        self.assertEqual(fm["disable-model-invocation"], "true")
        self.assertEqual(skills.frontmatter("no frontmatter"), {})
        self.assertEqual(skills.overrides('{"skillOverrides": [1, 2]}'), {})
        self.assertEqual(skills.overrides('{"skillOverrides": {"a": "off", "b": "weird"}}'), {"a": "off"})

    def test_refused_and_reserved(self):
        self.assertTrue(skills.is_refused_name("a​b"))
        self.assertTrue(skills.is_refused_name("<x>"))
        self.assertFalse(skills.is_refused_name("my skill"))
        self.assertTrue(skills.is_reserved("synced"))
        self.assertTrue(skills.is_reserved(".trash"))
        self.assertFalse(skills.is_reserved("deploy"))


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.claude = os.path.join(self.tmp.name, ".claude")
        self.env = mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": self.claude})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_all_sources(self):
        make(self.claude, "skills/deploy", "---\nname: deploy\ndescription: Ship it\n---")
        make(self.claude, "skills/synced/acct1/pdf", "---\nname: pdf\ndescription: old\n---")
        time.sleep(0.02)
        make(self.claude, "skills/synced/acct2/pdf", "---\nname: pdf\ndescription: new\n---")
        proj = os.path.join(self.tmp.name, "proj")
        make(proj, ".claude/skills/lint", "---\ndescription: Lint\n---")
        plugin_root = os.path.join(self.tmp.name, "plug")
        make(plugin_root, "skills/review", "---\nname: review\n---")
        os.makedirs(os.path.join(self.claude, "plugins"))
        with open(os.path.join(self.claude, "plugins", "installed_plugins.json"), "w") as f:
            json.dump({"plugins": {"tools@market": [{"installPath": plugin_root}]}}, f)
        found = {s.name: s for s in skills.scan([proj, self.tmp.name])}
        self.assertEqual(set(found), {"deploy", "anthropic-skills:pdf", "lint", "tools:review"})
        self.assertEqual(found["anthropic-skills:pdf"].description, "new")
        self.assertEqual(found["lint"].source, "project")
        self.assertTrue(found["deploy"].can_trash and not found["tools:review"].can_trash)
        self.assertEqual(found["deploy"].listing_chars, len("deploy") + 4 + len("Ship it"))

    def test_visibility_merge_keeps_other_keys_and_refuses_bad_json(self):
        path = os.path.join(self.claude, "settings.json")
        os.makedirs(self.claude, exist_ok=True)
        with open(path, "w") as f:
            json.dump({"hooks": {"Stop": []}, "theme": "dark"}, f)
        skills.set_visibility("deploy", "name-only")
        skills.set_plugin_enabled("tools@market", False)
        data = open(path).read()
        self.assertEqual(skills.overrides(data), {"deploy": "name-only"})
        self.assertEqual(skills.enabled_plugins(data), {"tools@market": False})
        self.assertEqual(json.loads(data)["theme"], "dark")
        skills.set_visibility("deploy", "on")
        self.assertNotIn("skillOverrides", json.loads(open(path).read()))
        with open(path, "w") as f:
            f.write("{ broken")
        with self.assertRaises(skills.Unreadable):
            skills.set_visibility("deploy", "off")
        self.assertEqual(open(path).read(), "{ broken")

    def test_trash_and_restore_round_trip(self):
        make(self.claude, "skills/deploy", "---\nname: deploy\n---")
        proj = os.path.join(self.tmp.name, "proj")
        make(proj, ".claude/skills/lint", "---\nname: lint\n---")
        found = {s.name: s for s in skills.scan([proj])}
        skills.trash(found["deploy"])
        skills.trash(found["lint"])
        self.assertEqual({s.name for s in skills.scan([proj])}, set())
        entries = {e.name: e for e in skills.trash_list()}
        self.assertEqual(entries["deploy"].days_left, 30)
        self.assertEqual(os.path.normcase(entries["lint"].origin),
                         os.path.normcase(os.path.join(proj, ".claude", "skills")))
        skills.restore(entries["lint"])
        skills.restore(entries["deploy"])
        self.assertEqual({s.name for s in skills.scan([proj])}, {"deploy", "lint"})
        self.assertEqual(skills.trash_list(), [])


if __name__ == "__main__":
    unittest.main()
