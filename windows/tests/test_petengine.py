import random
import unittest

from claudenotch_win import petengine as pe


class PetEngineTests(unittest.TestCase):
    def test_moods_in_the_macs_order(self):
        self.assertEqual(pe.mood(True, True, True, False, 0), "startled")
        self.assertEqual(pe.mood(False, True, True, False, 0), "celebrating")
        self.assertEqual(pe.mood(False, False, True, False, 0), "working")
        self.assertEqual(pe.mood(False, False, False, True, 0), "thinking")
        self.assertEqual(pe.mood(False, False, False, False, 400), "sleepy")
        self.assertEqual(pe.mood(False, False, False, False, 60), "calm")
        self.assertEqual(pe.mood(False, False, False, False, 5), "curious")

    def test_picks_only_from_the_moods_table(self):
        rng = random.Random(1)
        for m, table in pe.WEIGHTS.items():
            allowed = {a for a, _ in table}
            self.assertTrue(all(pe.pick_activity(m, rng) in allowed for _ in range(50)))

    def test_duty_cycle_keeps_it_ambient(self):
        rng = random.Random(2)
        self.assertGreaterEqual(pe.next_delay("curious", "sleep", 12, rng), 12 * pe.DUTY_CYCLE)
        self.assertLess(pe.next_delay("working", "watch", 5, rng), 3)
        self.assertLess(pe.next_delay("curious", "boop", 1, rng), 101)

    def test_spring_settles_and_pose_enters_and_leaves(self):
        v, _ = pe.spring_step(3.0)
        self.assertAlmostEqual(v, 1.0, places=2)
        inset = 28
        start = pe.pose("peek", 0.0, inset, 100)
        middle = pe.pose("peek", 0.5, inset, 100)
        end = pe.pose("peek", 1.0, inset, 100)
        self.assertAlmostEqual(start.y, pe.hidden_centre_y("peek", inset))
        self.assertGreater(middle.y, start.y)                 # dropped out of the notch
        self.assertAlmostEqual(end.y, pe.hidden_centre_y("peek", inset), places=3)
        self.assertEqual(pe.pose("sleep", 0.5, inset, 100).emote, "zzz")
        self.assertEqual(pe.pose("sleep", 0.5, inset, 100, petting=True).emote, "heart")
        self.assertEqual(pe.pose("tucked", 0.5, inset, 100).opacity, 0)

    def test_stroll_stays_on_the_stage(self):
        for i in range(101):
            p = pe.pose("stroll", i / 100, 28, 120)
            self.assertLessEqual(abs(p.x), pe.max_centre_offset("stroll", 120))

    def test_stage_sizes(self):
        self.assertEqual(pe.stage_drop("tucked"), 0)
        self.assertEqual(pe.stage_width_pad("stroll"), 96)
        self.assertGreater(pe.stage_drop("celebrate"), pe.stage_drop("peek"))

    def test_scheduler_boops_and_reacts(self):
        s = pe.Scheduler(random.Random(3))
        self.assertEqual(s.tick(0, "curious"), "tucked")
        self.assertNotEqual(s.tick(5, "curious"), "tucked")   # first appearance after 3 s
        s.boop(10)
        self.assertEqual(s.activity, "boop")
        s.boop(10.5)
        s.boop(11)
        self.assertEqual(s.activity, "spin")
        s.react("celebrating", 20)
        self.assertEqual(s.activity, "celebrate")
        self.assertEqual(s.tick(20 + 2.5, "calm"), "tucked")   # performance over, resting


class RigAndRopeTests(unittest.TestCase):
    def test_rope_falls_then_swings_and_settles(self):
        anchor, l0, y0 = 28.0, pe.ROPE_LENGTH + 21, 5.0
        early = pe.rope_state(0.05, anchor, l0, y0)
        self.assertFalse(early.taut)
        later = pe.rope_state(1.0, anchor, l0, y0)
        self.assertTrue(later.taut)
        settled = pe.rope_state(20.0, anchor, l0, y0)
        self.assertAlmostEqual(settled.angle, 0.0, places=2)
        self.assertAlmostEqual(settled.radius, l0, places=2)
        mid = pe.pose("rope", 0.5, 28, 100)
        self.assertGreater(mid.y, 28)                         # hanging below the notch

    def test_rig_matches_the_mac(self):
        r = pe.rig("sleep", 0.5, 10.0)
        self.assertEqual((r.eye_open, r.leg_tuck), (pe.SLEEPING_EYES, [1.4] * 4))
        r = pe.rig("celebrate", 1 / 6, 0.0)                   # top of the first hop
        self.assertAlmostEqual(r.arm_left, 70, places=3)
        r = pe.rig("stroll", 0.5, 0.42 * 0.25)
        self.assertGreater(r.leg_lift[0], 0.6)               # stepping
        self.assertEqual(pe.blink(1.0), 1.0)
        self.assertLess(pe.blink(3.4 + 0.07), 0.1)            # mid-blink

    def test_dance_phases(self):
        _, _, _, rot = pe.dance(0.79, 0)
        self.assertGreater(rot, 300)                          # the spin
        rig_, _, oy, _ = pe.dance(0.9, 0)
        self.assertGreater(oy, 0.3)                           # the jump


if __name__ == "__main__":
    unittest.main()
