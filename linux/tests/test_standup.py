import datetime as dt
import os
import subprocess
import tempfile
import unittest

from claudenotch import standup
from claudenotch.archive import SessionRecord


class StandupTests(unittest.TestCase):
    def test_groups_by_project_with_summaries_commits_and_cost(self):
        now = dt.datetime(2026, 11, 24, 18, 0)
        today = dt.datetime(2026, 11, 24, 9, 0).timestamp()
        old = dt.datetime(2026, 11, 20, 9, 0).timestamp()
        recs = [SessionRecord("a", r"C:\p\api", "api", "Fix the login bug", today, today, 3, cost_usd=1.25),
                SessionRecord("b", r"C:\p\api", "api", "fix the login bug", today + 60, today + 60, 1, cost_usd=0.5),
                SessionRecord("c", r"C:\p\web", "web", "Old work", old, old, 1)]
        commits = {r"C:\p\api": ["feat: login"], r"C:\p\tools": ["chore: bump"]}
        out = standup.text(recs, lambda d, since: commits.get(d, []), extra_dirs=[r"C:\p\tools"], now=now)
        self.assertTrue(out.startswith("Standup, Tue Nov 24\n\n"))
        self.assertIn("api\n  • Fix the login bug\n  · feat: login\n  (2 sessions, ~$1.75)", out)
        self.assertIn("tools\n  · chore: bump", out)
        self.assertNotIn("Old work", out)

    def test_nothing_to_say(self):
        out = standup.text([], lambda d, s: [], days=7, now=dt.datetime(2026, 11, 24))
        self.assertEqual(out, "What I shipped, last 7 days\n\nNo sessions or commits in this window.")

    def test_commits_from_a_real_repository(self):
        with tempfile.TemporaryDirectory() as d:
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
            try:
                subprocess.run(["git", "init", "-q", d], check=True, env=env)
                subprocess.run(["git", "-C", d, "commit", "-q", "--allow-empty", "-m", "first thing"], check=True,
                               env=env)
            except (OSError, subprocess.CalledProcessError):
                self.skipTest("git is not available")
            self.assertEqual(standup.commits(d, dt.datetime.now() - dt.timedelta(days=1)), ["first thing"])
            self.assertEqual(standup.commits(os.path.join(d, "nope"), dt.datetime.now()), [])


if __name__ == "__main__":
    unittest.main()
