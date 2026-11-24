import unittest

from claudenotch import worktree as w
from claudenotch.state import AppState


class WorktreeAdviceTests(unittest.TestCase):
    def test_collisions(self):
        got = w.colliding_directories([("C:\\p\\api", ""), ("c:\\P\\API\\", ""), ("C:\\p\\web", ""),
                                       ("C:\\p\\web", "feature-x"), ("", ""), ("", "")])
        self.assertEqual(len(got), 1)
        self.assertTrue(got[0].lower().startswith("c:\\p\\api"))
        self.assertEqual(w.colliding_directories([("/p", ""), ("/q", "")]), [])

    def test_said_once_per_folder(self):
        st = AppState(persist=False)
        for sid in ("a", "b", "c"):
            st.handle_event({"hook_event_name": "UserPromptSubmit", "session_id": sid, "cwd": "/p/api",
                             "prompt": "go"})
        advice = [t for t in st.toasts if t.kind == "advice"]
        self.assertEqual(len(advice), 1)
        self.assertEqual(advice[0].title, "Two sessions are working in api at once")
        self.assertIn("claude --worktree", advice[0].body)

    def test_lines_changed_from_the_status_line(self):
        from claudenotch import statusline
        st = AppState(persist=False)
        st.note_status(statusline.parse(statusline.flatten({
            "session_id": "a", "model": {"id": "claude-opus-5-5"},
            "cost": {"total_cost_usd": 1.0, "total_lines_added": 120, "total_lines_removed": 34}})))
        s = st.sessions["a"]
        self.assertEqual((s.lines_added, s.lines_removed), (120, 34))


if __name__ == "__main__":
    unittest.main()
