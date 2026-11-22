import datetime as dt
import json
import os
import tempfile
import unittest

from claudenotch.stats import MAX_TOOLS, StatsStore


class StatsTests(unittest.TestCase):
    def test_counts_persist_and_days_are_unique(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "stats.json")
            s = StatsStore(p)
            day = dt.date(2026, 11, 22)
            for what in ("allowed", "denied", "auto_approved", "dangerous", "question"):
                s.record(what, today=day)
            s.record("tool", "Bash", today=day)
            s.record("tool", "Bash", today=day + dt.timedelta(days=1))
            again = StatsStore(p).value
            self.assertEqual((again.allowed, again.denied, again.auto_approved), (2, 1, 1))
            self.assertEqual((again.dangerous_flagged, again.questions_answered), (1, 1))
            self.assertEqual(again.active_days, ["2026-11-22", "2026-11-23"])
            self.assertEqual(again.top_tools(), [("Bash", 2)])

    def test_tool_names_are_capped(self):
        s = StatsStore(None)
        for i in range(MAX_TOOLS + 10):
            s.record("tool", f"mcp__t{i}")
        s.record("tool", "x" * 500)
        self.assertEqual(len(s.value.tool_counts), MAX_TOOLS)

    def test_a_bad_file_is_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "stats.json")
            with open(p, "w") as f:
                json.dump({"allowed": "lots", "tool_counts": {"Bash": -3, "Edit": 2}}, f)
            v = StatsStore(p).value
            self.assertEqual(v.allowed, 0)
            self.assertEqual(v.tool_counts, {"Edit": 2})


if __name__ == "__main__":
    unittest.main()
