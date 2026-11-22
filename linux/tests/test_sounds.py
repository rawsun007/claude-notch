import unittest

from claudenotch import sounds as s


def play(event, tool=None, **kw):
    args = dict(muted=False, per_tool=False, alert="A", per_event={}, per_category={})
    args.update(kw)
    return s.sound_for(event, tool, **args)


class SoundTests(unittest.TestCase):
    def test_prompts_follow_the_alert_sound(self):
        self.assertEqual(play("permission"), "A")
        self.assertEqual(play("question"), "A")

    def test_per_tool_sounds(self):
        self.assertEqual(play("permission", "PowerShell", per_tool=True), s.category_default("bash"))
        self.assertEqual(play("permission", "Edit", per_tool=True, per_category={"edit": "X"}), "X")
        self.assertEqual(s.category("mcp__x"), "other")

    def test_events_have_their_own_and_can_be_silenced(self):
        self.assertEqual(play("completed"), s.event_default("completed"))
        self.assertEqual(play("completed", per_event={"completed": "Y"}), "Y")
        self.assertIsNone(play("completed", per_event={"completed": s.SILENT}))
        self.assertIsNone(play("permission", muted=True))

    def test_choosing_the_default_drops_the_override(self):
        d = s.set_override({}, "completed", "Y", s.event_default("completed"))
        self.assertEqual(d, {"completed": "Y"})
        self.assertEqual(s.set_override(d, "completed", s.event_default("completed"),
                                        s.event_default("completed")), {})
        self.assertEqual(s.set_override({}, "permission", "Z", None), {"permission": "Z"})


if __name__ == "__main__":
    unittest.main()
