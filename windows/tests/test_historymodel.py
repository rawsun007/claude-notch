import datetime as dt
import os
import tempfile
import unittest

from claudenotch.archive import SessionRecord

from claudenotch_win import historymodel as h


def entry(what, title="Run shell command", detail="npm test", project="api", at=1.0):
    return {"at": at, "what": what, "title": title, "detail": detail, "project": project}


class HistoryModelTests(unittest.TestCase):
    def test_outcomes_match_the_macs(self):
        self.assertEqual(h.outcome("allowed"), ("allowed", "allowed"))
        self.assertEqual(h.outcome("auto-approved"), ("allowed", "auto-approved"))
        self.assertEqual(h.outcome("allowed, destructive"), ("dangerous", "allowed (destructive)"))
        self.assertEqual(h.outcome("auto-approved, destructive")[0], "dangerous")
        self.assertEqual(h.outcome("denied")[0], "denied")
        self.assertEqual(h.outcome("answered")[0], "answered")
        self.assertEqual(h.outcome("sent to terminal")[0], "dismissed")
        self.assertEqual(h.outcome("notice"), ("info", "notification"))
        self.assertEqual(set(h.OUTCOME_STYLE), {"allowed", "denied", "dismissed", "answered", "info", "dangerous"})

    def test_filters_and_search_newest_first(self):
        log = [entry("allowed", at=1), entry("denied", detail="rm -rf x", at=2),
               entry("allowed, destructive", project="web", at=3), entry("answered", title="Question", at=4)]
        self.assertEqual([e["at"] for e in h.events(log)], [4, 3, 2, 1])
        self.assertEqual([e["at"] for e in h.events(log, "allowed")], [1])
        self.assertEqual([e["at"] for e in h.events(log, "dangerous")], [3])
        self.assertEqual([e["at"] for e in h.events(log, "questions")], [4])
        self.assertEqual([e["at"] for e in h.events(log, "all", "RM -RF")], [2])
        self.assertEqual([e["at"] for e in h.events(log, "all", " web ")], [3])
        self.assertEqual(h.count_label("events", 1, 4), "1 of 4")
        self.assertEqual(h.count_label("events", 4, 4), "4 events")
        self.assertEqual(h.count_label("sessions", 1, 1), "1 session")

    def test_projects_group_sessions_and_skip_temp_folders(self):
        tmp = os.path.join(tempfile.gettempdir(), "scratch")
        recs = [SessionRecord("a", r"C:\p\api", "api", "Fix login", 10, 20, 3, cost_usd=1.0),
                SessionRecord("b", r"C:\p\api", "api", "Add tests", 30, 40, 2, cost_usd=0.5),
                SessionRecord("c", r"C:\p\web", "web", "", 5, 6, 1),
                SessionRecord("d", tmp, "scratch", "", 50, 60, 1)]
        stats = h.project_stats(recs, {r"C:\p\api": 4.2})
        self.assertEqual([(p.project, p.sessions, p.cost_usd, p.turns) for p in stats],
                         [("api", 2, 4.2, 5), ("web", 1, 0.0, 1)])
        self.assertEqual([p.project for p in h.project_stats(recs, query="WE")], ["web"])
        self.assertEqual([r.id for r in h.sessions(recs, "login")], ["a"])
        self.assertFalse(h.is_real_project(""))

    def test_week_spend(self):
        today = dt.date(2026, 11, 24)
        days, total = h.week_spend({"2026-11-24": 2.0, "2026-11-18": 1.0, "2026-11-17": 9.0}, today)
        self.assertEqual((days[0], days[-1], total), (1.0, 2.0, 3.0))

    def test_csv(self):
        out = h.events_csv([entry("denied", detail='say "hi", now')])
        self.assertIn('"say ""hi"", now"', out)


if __name__ == "__main__":
    unittest.main()
