import unittest

from claudenotch import statusline as sl

RAW = {
    "session_id": "abc",
    "session_name": "fix the build",
    "workspace": {"current_dir": "C:\\work\\proj", "git_worktree": "wt-1"},
    "model": {"id": "claude-opus-4-6-20251001", "display_name": "Opus 4.6"},
    "effort": {"level": "high"},
    "cost": {"total_cost_usd": 1.234, "total_lines_added": 10, "total_lines_removed": 2},
    "context_window": {"used_percentage": 42.5, "context_window_size": 200000, "total_input_tokens": 85000},
    "rate_limits": {"five_hour": {"used_percentage": 30, "resets_at": 1764000000},
                    "seven_day": {"used_percentage": "12.5"}},
    "prompt_cache": {"warm": False, "ttl": "5m", "last_miss_cause": {"causes": ["ttl", "edit"]}},
    "pr": {"number": 7, "url": "https://github.com/o/r/pull/7", "review_state": "approved"},
}


class FlattenTests(unittest.TestCase):
    def test_matches_the_mac_forwarder(self):
        f = sl.flatten(RAW)
        self.assertEqual(f["cwd"], "C:\\work\\proj")
        self.assertEqual(f["model"], "claude-opus-4-6-20251001")
        self.assertEqual(f["worktree"], "wt-1")
        self.assertEqual(f["effort"], "high")
        self.assertEqual(f["context_pct"], 42.5)
        self.assertEqual(f["context_window"], 200000)
        self.assertEqual(f["five_hour_resets_at"], 1764000000)
        self.assertEqual(f["pr_number"], 7)
        self.assertEqual(f["cache_miss_causes"], "ttl,edit")

    def test_a_cold_cache_stays_false(self):
        self.assertIs(sl.flatten(RAW)["cache_warm"], False)
        self.assertIsNone(sl.flatten({})["cache_warm"])

    def test_fallbacks(self):
        f = sl.flatten({"cwd": "/p", "model": {"display_name": "Sonnet"}, "worktree": {"name": "w"}})
        self.assertEqual((f["cwd"], f["model"], f["worktree"]), ("/p", "Sonnet", "w"))
        self.assertEqual(sl.flatten("junk")["session_id"], "")


class ParseTests(unittest.TestCase):
    def test_reading(self):
        r = sl.parse(sl.flatten(RAW))
        self.assertEqual(r.session_id, "abc")
        self.assertAlmostEqual(r.context_pct, 0.425)
        self.assertEqual((r.context_window, r.context_tokens), (200000, 85000))
        self.assertAlmostEqual(r.cost_usd, 1.234)
        self.assertAlmostEqual(r.five_hour_pct, 0.30)
        self.assertAlmostEqual(r.seven_day_pct, 0.125)       # a string number
        self.assertIs(r.cache_warm, False)
        self.assertEqual(r.pr_number, 7)

    def test_nothing_usable_is_ignored(self):
        self.assertIsNone(sl.parse({"session_id": "a", "model": "opus"}))
        self.assertIsNone(sl.parse("nope"))

    def test_percentages_are_clamped_and_junk_is_dropped(self):
        r = sl.parse({"context_pct": 250, "cost_usd": True, "five_hour_pct": "x"})
        self.assertEqual(r.context_pct, 1.0)
        self.assertIsNone(r.cost_usd)
        self.assertIsNone(r.five_hour_pct)

    def test_long_text_is_capped(self):
        r = sl.parse({"session_name": "x" * 5000, "effort": "high"})
        self.assertEqual(len(r.session_name), sl.MAX_TEXT)


class ShowTests(unittest.TestCase):
    def test_model_names(self):
        self.assertEqual(sl.model_name_version("claude-opus-4-6-20251001"), ("Opus", "4.6"))
        self.assertEqual(sl.model_name_version("claude-sonnet-5-5"), ("Sonnet", "5.5"))
        self.assertEqual(sl.model_name_version("claude-fable-5-2"), ("Fable", "5.2"))
        self.assertEqual(sl.model_name_version("gpt-5"), ("gpt-5", "5"))
        self.assertEqual(sl.model_name_version(""), ("", ""))
        self.assertEqual(sl.short_model("claude-haiku-5-5"), "haiku 5.5")

    def test_money_and_effort(self):
        self.assertEqual(sl.fmt_money(1.234), "$1.23")
        self.assertEqual(sl.fmt_money(123.4), "$123")
        self.assertEqual(sl.capitalized("high"), "High")


if __name__ == "__main__":
    unittest.main()
