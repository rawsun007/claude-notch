import json
import os
import tempfile
import unittest

from claudenotch.archive import MAX_RECORDS, Archive, export_csv, export_json


class ArchiveTests(unittest.TestCase):
    def test_one_record_per_session_updated_each_turn(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "sessions.json")
            a = Archive(p)
            a.note_turn("s1", "C:/w/proj", "proj", prompt="fix   the\nbuild", model="claude-opus-5-5", now=100)
            a.note_turn("s1", "C:/w/proj", "proj", prompt="something else", cost_usd=1.5, branch="main", now=200)
            a.note_turn("s2", "C:/w/other", "other", prompt="add tests", now=150)
            again = Archive(p)
            recs = again.newest_first()
            self.assertEqual([r.id for r in recs], ["s1", "s2"])
            s1 = recs[0]
            self.assertEqual((s1.summary, s1.turns, s1.started, s1.last), ("fix the build", 2, 100, 200))
            self.assertEqual((s1.model, s1.branch, s1.cost_usd), ("claude-opus-5-5", "main", 1.5))

    def test_search_and_clear(self):
        a = Archive(None)
        a.note_turn("s1", "C:/w/api", "api", prompt="fix login", branch="auth-fix")
        a.note_turn("s2", "C:/w/web", "web", prompt="new page")
        self.assertEqual([r.id for r in a.newest_first("auth")], ["s1"])
        self.assertEqual([r.id for r in a.newest_first("web page")], ["s2"])
        a.clear()
        self.assertEqual(a.newest_first(), [])

    def test_secrets_are_redacted_and_the_list_is_capped(self):
        a = Archive(None)
        secret = "sk-ant-api03-" + "B" * 40
        a.note_turn("s0", "/p", "p", prompt=f"use key {secret}")
        self.assertNotIn(secret, a.records[0].summary)
        for i in range(MAX_RECORDS + 5):
            a.note_turn(f"x{i}", "/p", "p")
        self.assertEqual(len(a.records), MAX_RECORDS)

    def test_bad_file_and_exports(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "sessions.json")
            with open(p, "w") as f:
                json.dump([{"id": 3}, {"id": "ok", "turns": "x"}, {"id": "fine", "project": "p"}], f)
            a = Archive(p)
            self.assertEqual([r.id for r in a.records], ["fine"])
            self.assertTrue(export_csv(a.records).startswith("session_id,project"))
            self.assertEqual(json.loads(export_json(a.records))[0]["id"], "fine")


if __name__ == "__main__":
    unittest.main()
