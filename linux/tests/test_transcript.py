import json
import os
import tempfile
import unittest

from claudenotch import transcript as t


def write(path, entries):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for e in entries:
            f.write(json.dumps(e) + "\n")


class TranscriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name
        self.claude = os.path.join(self.home, ".claude")
        self.roots = t.roots(self.home, env={})

    def tearDown(self):
        self.tmp.cleanup()

    def test_newest_assistant_text_in_either_shape(self):
        p = os.path.join(self.claude, "projects", "p", "s.jsonl")
        write(p, [{"type": "user", "message": {"role": "user", "content": "hi"}},
                  {"type": "assistant", "message": {"role": "assistant", "content": [
                      {"type": "text", "text": "First part."}, {"type": "tool_use", "name": "Bash"},
                      {"type": "text", "text": "Second part."}]}},
                  {"type": "user", "message": {"role": "user", "content": "tool result"}},
                  "not json at all"])
        self.assertEqual(t.last_assistant_text(p, self.roots), "First part.\n\nSecond part.")
        write(p, [{"role": "assistant", "content": "Plain shape"}])
        self.assertEqual(t.last_assistant_text(p, self.roots), "Plain shape")

    def test_refuses_paths_outside_claudes_folders(self):
        outside = os.path.join(self.home, "secrets.jsonl")
        write(outside, [{"role": "assistant", "content": "nope"}])
        self.assertIsNone(t.last_assistant_text(outside, self.roots))
        sneaky = os.path.join(self.claude, "..", "secrets.jsonl")
        self.assertIsNone(t.last_assistant_text(sneaky, self.roots))
        sibling = os.path.join(self.home, ".claudeXYZ", "x.jsonl")
        write(sibling, [{"role": "assistant", "content": "nope"}])
        self.assertIsNone(t.last_assistant_text(sibling, self.roots))
        self.assertFalse(t.is_allowed("", self.roots))

    def test_payload_reply_wins_and_secrets_are_redacted(self):
        got = t.reply_from({"last_assistant_message": "Done. Key was sk-ant-api03-" + "A" * 40})
        self.assertTrue(got.startswith("Done."))
        self.assertNotIn("A" * 40, got)
        self.assertEqual(len(t.clean("x" * 9000)), t.MAX_REPLY)
        self.assertIsNone(t.reply_from({"transcript_path": 5}))


if __name__ == "__main__":
    unittest.main()
