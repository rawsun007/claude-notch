import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from claudenotch import protocol  # noqa: E402
from claudenotch.state import AppState, PermissionCard, QuestionCard  # noqa: E402
from claudenotch_win.qtapp import release_open_cards  # noqa: E402


class QuitTests(unittest.TestCase):
    def test_quitting_sends_every_open_card_back_to_the_terminal(self):
        st, got = AppState(persist=False), []
        st.enqueue_permission(PermissionCard("Bash", {"command": "ls"}, "C:\\p", protocol.PERMISSION, "s",
                                             resolve=lambda d, r: got.append(d)))
        q = protocol.Question("h", "Which?", False, [("a", ""), ("b", "")])
        st.enqueue_question(QuestionCard([q], "C:\\p", "s", resolve=lambda a: got.append(a)))
        release_open_cards(st)
        self.assertEqual(got, ["ask", None])
        perms, questions, _, _ = st.snapshot()
        self.assertEqual((perms, questions), ([], []))


if __name__ == "__main__":
    unittest.main()
