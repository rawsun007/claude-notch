import datetime as dt
import json
import os
import tempfile
import unittest

from claudenotch import usage


def turn(mid, ts, model="claude-opus-5-5", inp=1000, out=500, cr=0, cw=0, sid="s1", cwd="C:/w/p"):
    return json.dumps({"timestamp": ts, "sessionId": sid, "cwd": cwd,
                       "message": {"id": mid, "role": "assistant", "model": model,
                                   "usage": {"input_tokens": inp, "output_tokens": out,
                                             "cache_read_input_tokens": cr,
                                             "cache_creation_input_tokens": cw}}})


class PriceTests(unittest.TestCase):
    def test_prices_match_modelpricing(self):
        self.assertEqual(usage.price_for("claude-opus-5-5").input, 4)
        self.assertEqual(usage.price_for("claude-opus-4-6").output, 25)
        self.assertEqual(usage.price_for("claude-opus-4-1").input, 15)
        self.assertEqual(usage.price_for("claude-haiku-5-5").input, 0.1)
        self.assertEqual(usage.price_for("claude-haiku-5-5", prompt_tokens=200_000).input, 0.5)
        self.assertEqual(usage.price_for("claude-haiku-3-5").input, 0.8)
        self.assertEqual(usage.price_for("claude-sonnet-4-6").input, 3)
        self.assertEqual(usage.price_for("claude-sonnet-5-5").cache_read, 0.1)
        self.assertEqual(usage.price_for("claude-fable-5-2").cache_read, 0.25)

    def test_model_version_ignores_dates(self):
        self.assertEqual(usage.model_version("claude-haiku-4-5-20251001"), 4.5)
        self.assertEqual(usage.model_version("claude-opus-5"), 5.0)
        self.assertIsNone(usage.model_version("gpt"))

    def test_cost_and_cache_split(self):
        self.assertAlmostEqual(usage.cost(1_000_000, 0, 0, 0, 0, "claude-opus-5-5"), 4.0)
        self.assertEqual(usage.cache_writes({"cache_creation_input_tokens": 100,
                                             "cache_creation": {"ephemeral_1h_input_tokens": 30}}), (70, 30))
        self.assertAlmostEqual(usage.cache_savings(1_000_000, "claude-opus-5-5"), 3.8)


class ParseTests(unittest.TestCase):
    def test_each_message_billed_once_and_junk_skipped(self):
        lines = [turn("m1", "2026-11-22T10:00:00Z"), turn("m1", "2026-11-22T10:00:01Z"),
                 "not json", json.dumps({"message": {"role": "user"}}), turn("m2", "2026-11-22T10:01:00Z")]
        recs = usage.parse_lines(lines)
        self.assertEqual(len(recs), 2)
        self.assertEqual(recs[0].tokens.total, 1500)


class ComputeTests(unittest.TestCase):
    def test_windows_and_mix(self):
        now = dt.datetime(2026, 11, 22, 15, 0).astimezone()
        def iso(d):
            return d.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")
        with tempfile.TemporaryDirectory() as root:
            proj = os.path.join(root, "C--w-p")
            os.makedirs(proj)
            with open(os.path.join(proj, "a.jsonl"), "w") as f:
                f.write("\n".join([
                    turn("t1", iso(now - dt.timedelta(hours=1))),                      # today, 5 h
                    turn("t2", iso(now - dt.timedelta(hours=10)), model="claude-haiku-5-5", sid="s2"),
                    turn("t3", iso(now - dt.timedelta(days=3)), cwd="C:/w/q"),         # this week
                    turn("t4", iso(now - dt.timedelta(days=20))),                      # trend only
                ]))
            u = usage.compute(root, now)
        self.assertEqual(u.five_hour.total, 1500)
        self.assertEqual(u.today.total, 3000)
        self.assertEqual(u.week.total, 4500)
        self.assertEqual(sum(u.daily_tokens.values()), 6000)
        self.assertEqual(set(u.week_by_model), {"opus 5.5", "haiku 5.5"})
        self.assertEqual(set(u.week_by_project), {"C:/w/p", "C:/w/q"})
        self.assertEqual((u.sessions_today, u.sessions_week), (2, 2))

    def test_series_and_buckets(self):
        today = dt.date(2026, 11, 22)
        daily = {"2026-11-22": 1.0, "2026-11-20": 2.0, "2026-11-10": 5.0}
        series = usage.daily_series(daily, 7, today)
        self.assertEqual(len(series), 7)
        self.assertEqual(series[-1][1], 1.0)
        weeks = usage.weekly_cost_buckets(daily, 4, today)
        self.assertEqual([round(c, 1) for _, c in weeks], [0.0, 0.0, 5.0, 3.0])
        self.assertEqual(weeks[-1][0], "Nov 16")
        self.assertEqual(usage.fmt_tokens(950), "950")
        self.assertEqual(usage.fmt_tokens(12_300), "12.3k")
        self.assertEqual(usage.fmt_tokens(4_500_000), "4.5M")


if __name__ == "__main__":
    unittest.main()
