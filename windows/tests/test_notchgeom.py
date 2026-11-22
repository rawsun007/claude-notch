import math

from claudenotch_win import notchgeom as g


def test_notch_path_matches_notchshape_control_points():
    cmds = g.notch_path(0, 0, 200, 28, 9, 10)
    assert cmds[0] == ("move", 0, 0)
    # Concave top-left ear: control at (t, 0), ends at (t, t).
    assert cmds[1] == ("quad", 9, 0, 9, 9)
    assert cmds[2] == ("line", 9, 18)
    assert cmds[3] == ("quad", 9, 28, 19, 28)
    assert cmds[4] == ("line", 181, 28)
    assert cmds[5] == ("quad", 191, 28, 191, 18)
    assert cmds[6] == ("line", 191, 9)
    assert cmds[7] == ("quad", 191, 0, 200, 0)
    assert cmds[-1] == ("close",)


def test_notch_path_clamps_negative_radii():
    cmds = g.notch_path(10, 5, 100, 50, -3, -1)
    assert cmds[1] == ("quad", 10, 5, 10, 5)


def test_radii_follow_the_mac():
    assert g.top_radius(True) == 9 and g.top_radius(False) == 12
    assert g.bottom_radius(True) == 10
    assert g.bottom_radius(False, "permission") == 18
    assert g.bottom_radius(False, "history") == 22


def test_easings_hit_their_ends_and_back_overshoots():
    for f in (g.ease_out_cubic, g.ease_out_back):
        assert abs(f(0)) < 1e-9
        assert abs(f(1) - 1) < 1e-9
    assert max(g.ease_out_back(i / 100) for i in range(101)) > 1.05
    assert all(g.ease_out_cubic(i / 100) <= 1 for i in range(101))


def test_rebased_start_keeps_the_current_value():
    start = g.rebased_start(current=150, target=300, eased=0.5)
    assert start + (300 - start) * 0.5 == 150


def test_animator_expands_with_overshoot_and_lands_exactly():
    a = g.SizeAnimator()
    a.set((200, 28))
    a.animate((620, 200), expanding=True, now=0)
    sizes = [a.tick(i / 120) for i in range(1, 60)]
    assert max(w for w, _ in sizes) > 620          # overshoot
    assert a.tick(1.0) == (620, 200)
    assert not a.running


def test_animator_collapse_never_undershoots():
    a = g.SizeAnimator()
    a.set((620, 200))
    a.animate((200, 28), expanding=False, now=0)
    sizes = [a.tick(i / 120) for i in range(1, 45)]
    assert min(w for w, _ in sizes) >= 200
    assert a.tick(g.COLLAPSE_SECONDS) == (200, 28)


def test_animator_same_direction_retarget_does_not_jump():
    a = g.SizeAnimator()
    a.set((200, 28))
    a.animate((620, 180), expanding=True, now=0)
    before = a.tick(0.05)
    a.animate((620, 220), expanding=True, now=0.05)
    after = a.tick(0.05)
    assert abs(before[1] - after[1]) < 1e-6
    assert a.tick(1.0) == (620, 220)


def test_animator_ignores_the_same_target():
    a = g.SizeAnimator()
    a.set((200, 28))
    a.animate((200.2, 28.1), expanding=True, now=0)
    assert not a.running


def test_is_expanding_by_area():
    assert g.is_expanding((300, 100), (200, 28))
    assert not g.is_expanding((200, 28), (300, 100))


def test_trigger_zone_and_keep_region():
    screen = (0, 0, 1920, 1080)
    assert g.trigger_zone(screen) == (790.0, 0.0, 340.0, 44.0)
    assert g.keep_region(screen, 100, 30) == (730.0, 0.0, 460.0, 160.0)
    assert g.keep_region(screen, 620, 200) == (580.0, 0.0, 760.0, 290.0)
    # A second monitor to the left.
    assert g.trigger_zone((-1280, 0, 1280, 1024))[0] == -810.0


def test_should_hover_matches_mousetracker():
    assert not g.should_hover(False, False, True, False, True)    # suppressed
    assert g.should_hover(True, True, False, True, False)        # held over open card
    assert not g.should_hover(True, False, False, False, True)
    assert not g.should_hover(False, True, False, False, True)    # mid-drag
    assert g.should_hover(False, False, False, False, True)


def test_contains_is_half_open():
    assert g.contains((0, 0, 10, 10), 0, 0)
    assert not g.contains((0, 0, 10, 10), 10, 5)


def test_sizes():
    assert g.collapsed_size() == (200, 28)
    assert g.idle_open_size(10) == (230, g.INSET + 64)
    assert g.idle_open_size(1000)[0] == 520
    assert g.permission_size() == (620, g.INSET + 152)
    w, h = g.permission_size(dangers=3)
    assert h == g.INSET + 152 + max(28 + 42, 44) + 8
    assert g.permission_size(dangers=1)[1] == g.INSET + 152 + 44 + 8
    assert g.permission_size(diff_rows=6)[1] == g.INSET + 152 + 96 + 16
    assert g.permission_size(expired=True)[1] == g.INSET + 152 + 96
    assert g.permission_size(diff_rows=500, screen_h=600)[1] == g.INSET + 600 * 0.85 - g.INSET


def test_elide_keeps_both_ends():
    assert g.elide("main", 12) == "main"
    out = g.elide("feature/really-long-name", 12)
    assert len(out) == 12 and out == "featur…-name"


def test_fmt_k_and_tint():
    assert g.fmt_k(999) == "999"
    assert g.fmt_k(161_000) == "161k"
    assert g.fmt_k(1_000_000) == "1M"
    assert g.fmt_k(1_500_000) == "1.5M"
    assert [g.context_tint(p) for p in (0.1, 0.7, 0.9)] == ["blue", "orange", "red"]


def test_wait_elapsed_matches_mac():
    assert g.wait_elapsed(45) == "45s"
    assert g.wait_elapsed(185) == "3m"
    assert g.wait_elapsed(3900) == "1h 5m"
    assert g.wait_elapsed(7200) == "2h"


def test_shimmer_stops_sorted_and_bounded():
    for phase in (0, 0.3, 0.5, 1):
        stops = g.shimmer_stops(phase)
        locs = [s[0] for s in stops]
        assert locs == sorted(locs) and locs[0] == 0 and locs[-1] == 1
    assert max(o for _, o in g.shimmer_stops(0.5)) == 0.72
    assert max(o for _, o in g.shimmer_stops(0.0)) == 0.32   # spot off the left


def test_pulse_and_bob():
    assert abs(g.pulse_opacity(math.pi / 2) - 1.0) < 1e-9
    assert abs(g.pulse_opacity(-math.pi / 2) - 0.4) < 1e-9
    assert all(g.bob_offset("celebrating", t / 10) <= 0 for t in range(20))
    assert abs(g.bob_offset("calm", 0.45)) <= 0.9 + 1e-9
