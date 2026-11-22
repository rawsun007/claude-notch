"""Pet mode's brain, the Mac's PetEngine. Pure: no Qt, so it is tested.

The coral mascot lives in the closed notch. Its mood follows Claude
(startled after a failure or a deny, celebrating a finished task,
working, thinking, curious, calm, sleepy after five quiet minutes); each
mood picks an activity by weight; each activity is a short performance
with its own duration and a pose per instant (position, tilt, squash and
stretch, facing, an emote), entered with the same damped spring and left
with the same ease. Between performances it rests tucked inside the notch,
for at least eleven times as long as it was out, so it stays ambient.

Ported: peek, look around, hang off either corner, stroll, sleep,
celebrate, boop, backflip, watch, flinch, fret, and the rope with its
physics (free fall, catch, damped swing, springy stretch); PetRig's limbs
for each (arms about the shoulders, legs stepping, lifting and tucking,
blinks, eyes following the pointer) and the card badge's dance. Not
ported: the guest costumes, which recreate third-party characters.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass

MOODS = ("startled", "sleepy", "calm", "curious", "working", "thinking", "celebrating")
SLEEP_AFTER = 300.0
DUTY_CYCLE = 11.0
ENTRY_OMEGA, ENTRY_ZETA, ENTRY_WINDOW = 7.0, 0.5, 0.16

SPRITE = {"tucked": 26, "sleep": 38, "celebrate": 44, "spin": 44}
ROPE_LENGTH = 26.0
HEADROOM = {"celebrate": 17, "spin": 18, "peek": 6, "lookAround": 6, "boop": 6, "stroll": 5}
WIDTH_PAD = {"tucked": 0, "stroll": 96, "celebrate": 44, "spin": 44, "hangLeft": 40, "hangRight": 40, "rope": 60}

WEIGHTS = {
    "sleepy": [("sleep", 6), ("peek", 1), ("hangLeft", 1)],
    "calm": [("peek", 4), ("lookAround", 3), ("hangLeft", 2), ("hangRight", 2), ("stroll", 2), ("rope", 2),
             ("sleep", 1)],
    "curious": [("lookAround", 4), ("peek", 3), ("stroll", 3), ("rope", 3), ("hangRight", 2), ("hangLeft", 2)],
    "working": [("watch", 5), ("peek", 1)],
    "thinking": [("watch", 3), ("peek", 2), ("lookAround", 1)],
    "celebrating": [("celebrate", 1)],
    "startled": [("flinch", 1)],
}
DURATIONS = {
    "peek": (2.2, 3.2), "lookAround": (3.0, 4.2), "hangLeft": (3.4, 5.0), "hangRight": (3.4, 5.0),
    "stroll": (4.5, 6.0), "sleep": (8.0, 14.0), "celebrate": (2.4, 2.4), "boop": (0.85, 0.85),
    "spin": (1.5, 1.5), "watch": (3.5, 5.0), "flinch": (2.0, 2.0), "fret": (3.2, 3.2), "rope": (5.0, 5.0),
}


def sprite_size(a: str) -> float:
    return float(SPRITE.get(a, 42))


def lip_clearance(a: str) -> float:
    return 0.0 if a in ("hangLeft", "hangRight") else 5.0


def stage_drop(a: str) -> float:
    """How far the notch grows down to be the stage for `a`."""
    if a == "tucked":
        return 0.0
    if a == "rope":
        return ROPE_LENGTH + sprite_size(a) + 6
    return lip_clearance(a) + sprite_size(a) + HEADROOM.get(a, 2) + 6


def stage_width_pad(a: str) -> float:
    return float(WIDTH_PAD.get(a, 28))


def rest_centre_y(a: str, inset: float) -> float:
    if a == "rope":
        return inset + ROPE_LENGTH + sprite_size(a) / 2
    return inset + lip_clearance(a) + HEADROOM.get(a, 2) + sprite_size(a) / 2


def hidden_centre_y(a: str, inset: float) -> float:
    return inset - sprite_size(a) / 2 - 2


def max_centre_offset(a: str, half_width: float) -> float:
    return max(0.0, half_width - sprite_size(a) / 2 - 2)


# --- mood and scheduling ------------------------------------------------------------------


def mood(just_failed: bool, just_finished: bool, working: bool, thinking: bool, idle_seconds: float) -> str:
    if just_failed:
        return "startled"
    if just_finished:
        return "celebrating"
    if working:
        return "working"
    if thinking:
        return "thinking"
    if idle_seconds >= SLEEP_AFTER:
        return "sleepy"
    if idle_seconds >= 45:
        return "calm"
    return "curious"


def pick_activity(m: str, rng: random.Random) -> str:
    table = WEIGHTS.get(m, [])
    total = sum(w for _, w in table)
    if total <= 0:
        return "tucked"
    roll = rng.uniform(0, total)
    for a, w in table:
        roll -= w
        if roll < 0:
            return a
    return table[-1][0]


def duration(a: str, rng: random.Random) -> float:
    lo, hi = DURATIONS.get(a, (0.0, 0.0))
    return lo if lo == hi else rng.uniform(lo, hi)


def base_delay(m: str, rng: random.Random) -> float:
    ranges = {"curious": (45, 100), "calm": (90, 200), "sleepy": (240, 480), "working": (0.5, 2.0),
              "thinking": (0.5, 2.0)}
    if m == "celebrating":
        return 6.0
    if m == "startled":
        return 5.0
    lo, hi = ranges.get(m, (90, 200))
    return rng.uniform(lo, hi)


def next_delay(m: str, after: str, lasted: float, rng: random.Random) -> float:
    """Never less than DUTY_CYCLE times the last performance, except for
    boops and while Claude works, when the pet is on duty."""
    base = base_delay(m, rng)
    if after in ("boop", "spin") or m in ("working", "thinking"):
        return base
    return max(base, lasted * DUTY_CYCLE)


# --- poses ---------------------------------------------------------------------------------


@dataclass
class Pose:
    x: float = 0.0
    y: float = 0.0
    rotation: float = 0.0
    scale_x: float = 1.0
    scale_y: float = 1.0
    flipped: bool = False
    opacity: float = 1.0
    emote: str | None = None          # "zzz", "heart", "sparkle", "bang", "dots", "teardrop"
    emote_scale: float = 1.0


def spring_step(t: float, omega: float = ENTRY_OMEGA, zeta: float = ENTRY_ZETA) -> tuple[float, float]:
    if t <= 0:
        return 0.0, 0.0
    if zeta >= 1:
        e = math.exp(-omega * t)
        return 1 - e * (1 + omega * t), omega * omega * t * e
    wd = omega * math.sqrt(1 - zeta * zeta)
    e = math.exp(-zeta * omega * t)
    value = 1 - e * (math.cos(wd * t) + (zeta * omega / wd) * math.sin(wd * t))
    velocity = e * (omega * omega / wd) * math.sin(wd * t)
    return value, velocity


def _clamp01(v: float) -> float:
    return min(1.0, max(0.0, v))


def _mag(v: float, m: float) -> float:
    return min(m, max(-m, v))


def pose(a: str, t: float, inset: float, half_width: float, cursor_x: float = 0.0, petting: bool = False) -> Pose:
    """PetEngine.pose(for:progress:stage:), t in 0..1 of the performance."""
    t = _clamp01(t)
    if a == "tucked":
        return Pose(y=hidden_centre_y(a, inset), opacity=0)
    enter, vel = spring_step(t / ENTRY_WINDOW)
    exit_t = 0.0 if petting else _clamp01((t - 0.84) / 0.16)
    retract = exit_t ** 3
    env = enter * (1 - retract)
    rest, hidden = rest_centre_y(a, inset), hidden_centre_y(a, inset)
    p = Pose(y=hidden + (rest - hidden) * env)
    vv = vel / ENTRY_WINDOW * (rest - hidden) * (1 - retract)
    stretch = _mag(vv * 0.0016, 0.18)
    p.scale_y, p.scale_x = 1 + stretch, 1 - stretch * 0.7
    lean = _mag(cursor_x * 0.16, 9)
    tau = 2 * math.pi
    heart = "heart" if petting else None

    if a == "peek":
        p.x = lean
        p.y += math.sin(t * tau * 2.4) * 1.6 * env
        p.rotation = lean * 0.5
        p.flipped = cursor_x < -4
        p.emote = heart or ("dots" if 0.45 < t < 0.7 else None)
    elif a == "lookAround":
        sweep = math.sin(t * tau * 1.6)
        p.x = sweep * 11 * env + lean * 0.4
        p.rotation = -sweep * 7
        p.flipped = sweep < 0
        p.y += math.cos(t * tau * 3.2) * 1.2 * env
        p.emote = heart
    elif a in ("hangLeft", "hangRight"):
        side = -1 if a == "hangLeft" else 1
        wall = max_centre_offset(a, half_width)
        p.x = _mag(side * wall * env, wall)
        p.y = hidden + (inset + sprite_size(a) * 0.42 - hidden) * env
        p.rotation = side * 24 + math.sin(t * tau * 0.9) * 6
        p.flipped = side < 0
        p.scale_y, p.scale_x = 1 + stretch * 0.5, 1 - stretch * 0.35
        p.emote = heart
    elif a == "stroll":
        travel = max_centre_offset(a, half_width) - 4
        path = math.sin(t * tau * 0.5 - math.pi / 2)
        p.x = _mag(path * travel * env, travel)
        right = math.cos(t * tau * 0.5 - math.pi / 2) >= 0
        p.flipped = not right
        step = abs(math.sin(t * tau * 5))
        p.y += -step * 2.6 * env
        p.rotation = (4 if right else -4) * step
        p.scale_y, p.scale_x = 1 + stretch * 0.6 + step * 0.05, 1 - stretch * 0.4 - step * 0.03
        p.emote = heart
    elif a == "sleep":
        breathe = math.sin(t * tau * 0.6)
        p.x, p.rotation = 2, -5
        p.scale_y, p.scale_x = 0.95 + breathe * 0.03, 1.03 - breathe * 0.03
        p.y += breathe * 0.8 * env
        p.emote = heart or "zzz"
        p.emote_scale = 0.85 + breathe * 0.15
    elif a == "celebrate":
        phase = t * 3
        hop = abs(math.sin(phase * math.pi))
        p.y -= hop * 15 * env
        rise = math.cos(phase * math.pi)
        p.scale_y = 1 + hop * 0.18 * (1 if rise >= 0 else 0.4)
        p.scale_x = 1 - hop * 0.12
        p.rotation = math.sin(phase * tau) * 6
        p.emote, p.emote_scale = "sparkle", 0.6 + hop * 0.6
    elif a == "spin":
        air = math.sin(t * math.pi)
        p.y -= air * 16 * env
        p.rotation = -720 * (1 - (1 - t) ** 3)
        land = (t - 0.92) / 0.08 if t > 0.92 else 0
        p.scale_y, p.scale_x = 1 + air * 0.12 - land * 0.24, 1 - air * 0.08 + land * 0.20
        p.emote, p.emote_scale = "sparkle", 0.5 + air * 0.7
    elif a == "boop":
        squash = math.exp(-t * 6) * math.cos(t * tau * 3.2)
        p.y += squash * 4
        p.scale_y, p.scale_x = 1 - squash * 0.22, 1 + squash * 0.18
        p.rotation = squash * 5
        p.emote = "sparkle" if t < 0.6 else heart
        p.emote_scale = 1 - t * 0.4
    elif a == "watch":
        pace = math.sin(t * tau * 0.7)
        p.x = pace * 7 * env + lean * 0.5
        p.flipped = pace < 0
        step = abs(math.sin(t * tau * 2.2))
        p.y -= step * 1.8 * env
        p.rotation = pace * 4
        p.scale_y, p.scale_x = 1 + stretch * 0.6 + step * 0.04, 1 - stretch * 0.4 - step * 0.03
        p.emote = heart or ("dots" if t > 0.25 else None)
        p.emote_scale = 0.8
    elif a == "flinch":
        recoil = math.exp(-t * 5) * math.cos(t * tau * 4)
        p.x = recoil * 6 * env
        p.y -= abs(recoil) * 3 * env
        p.rotation = recoil * 9
        p.scale_y, p.scale_x = 1 + stretch * 0.5 - abs(recoil) * 0.10, 1 - stretch * 0.35 + abs(recoil) * 0.08
        p.emote = heart or ("bang" if t < 0.55 else "dots")
        p.emote_scale = 1.1 - t * 0.5
    elif a == "rope":
        rope = rope_state(t * DURATIONS["rope"][0], inset, ROPE_LENGTH + sprite_size(a) / 2, hidden)
        p.x = rope.x * (1 - retract)
        p.y = hidden + (rope.y - hidden) * (1 - retract)
        p.rotation = math.degrees(rope.angle - ROPE_BOB_LAG * rope.angle_rate)
        p.flipped = rope.angle < 0
        st = _mag(rope.radial_rate * 0.0012, 0.18)
        p.scale_y, p.scale_x = 1 + st, 1 - st * 0.7
        p.emote = heart
    elif a == "fret":
        sob = math.sin(t * tau * 1.6)
        p.x = sob * 2.5 * env
        p.y -= (1 - abs(sob)) * 1.2 * env
        p.rotation = sob * 3
        p.scale_y, p.scale_x = 0.94 + abs(sob) * 0.04, 1.04 - abs(sob) * 0.03
        p.emote = heart or "teardrop"
        p.emote_scale = 0.8 + abs(sob) * 0.3
    return p


class Scheduler:
    """When the pet comes out, what it does, and for how long. The caller
    ticks it with a clock and the current mood, and can boop it."""

    def __init__(self, rng: random.Random | None = None):
        self.rng = rng or random.Random()
        self.activity = "tucked"
        self.started = 0.0
        self.length = 0.0
        self.next_at = 3.0
        self.boops: list[float] = []

    def progress(self, now: float) -> float:
        return _clamp01((now - self.started) / self.length) if self.length else 1.0

    def tick(self, now: float, m: str) -> str:
        if self.activity != "tucked" and now - self.started >= self.length:
            lasted = self.length
            done = self.activity
            self.activity, self.length = "tucked", 0.0
            self.next_at = now + next_delay(m, done, lasted, self.rng)
        if self.activity == "tucked" and now >= self.next_at:
            self._start(pick_activity(m, self.rng), now)
        return self.activity

    def _start(self, a: str, now: float) -> None:
        self.activity, self.started = a, now
        self.length = duration(a, self.rng)
        if a == "tucked":
            self.next_at = now + 5

    def boop(self, now: float) -> None:
        """A click on the notch: a boop, or a backflip after a few in a row."""
        self.boops = [b for b in self.boops if now - b < 2.5] + [now]
        self._start("spin" if len(self.boops) >= 3 else "boop", now)
        if len(self.boops) >= 3:
            self.boops = []

    def react(self, m: str, now: float) -> None:
        """Something happened (a task finished, a turn failed): perform at once."""
        if m in ("celebrating", "startled"):
            self._start(pick_activity(m, self.rng), now)


# --- the rope (PetEngine.ropeState) ----------------------------------------------------------

ROPE_GRAVITY, ROPE_KICK_X = 1200.0, 42.0
ROPE_SPRING_OMEGA, ROPE_SPRING_ZETA = 17.0, 0.20
ROPE_MAX_STRETCH, ROPE_SWING_DAMPING, ROPE_BOB_LAG = 6.0, 0.32, 0.06


@dataclass
class RopeState:
    x: float = 0.0
    y: float = 0.0
    angle: float = 0.0
    angle_rate: float = 0.0
    radius: float = 0.0
    radial_rate: float = 0.0
    taut: bool = False


def rope_state(sec: float, anchor: float, rest_radius: float, drop_start: float) -> RopeState:
    """Free fall with a sideways kick until the rope goes taut, then a damped
    pendulum whose rope stretches like a spring and settles."""
    g, vx, l0, y0 = ROPE_GRAVITY, ROPE_KICK_X, rest_radius, drop_start
    fall = max(0.0001, l0 - (y0 - anchor))
    s_taut = math.sqrt(2 * fall / g)
    if sec < s_taut:
        st = RopeState(x=vx * sec, y=y0 + 0.5 * g * sec * sec)
        st.radius = math.hypot(st.x, st.y - anchor)
        st.radial_rate = g * sec
        return st
    x_t, vy = vx * s_taut, g * s_taut
    theta0 = math.atan2(x_t, l0)
    v_rad = vx * math.sin(theta0) + vy * math.cos(theta0)
    v_tan = vx * math.cos(theta0) - vy * math.sin(theta0)
    omega0 = v_tan / l0
    u = sec - s_taut
    wp = math.sqrt(g / l0)
    lam = ROPE_SWING_DAMPING
    wd = max(0.1, math.sqrt(max(0.0, wp * wp - lam * lam)))
    a, b = theta0, (omega0 + lam * theta0) / wd
    decay = math.exp(-lam * u)
    cw, sw = math.cos(wd * u), math.sin(wd * u)
    angle = decay * (a * cw + b * sw)
    rate = decay * (-lam * (a * cw + b * sw) + wd * (b * cw - a * sw))
    wr, zr = ROPE_SPRING_OMEGA, ROPE_SPRING_ZETA
    wrd = wr * math.sqrt(1 - zr * zr)
    amp = _mag(v_rad / wrd, ROPE_MAX_STRETCH)
    rdecay = math.exp(-zr * wr * u)
    stretch = rdecay * amp * math.sin(wrd * u)
    srate = rdecay * amp * (wrd * math.cos(wrd * u) - zr * wr * math.sin(wrd * u))
    radius = l0 + stretch
    return RopeState(math.sin(angle) * radius, anchor + math.cos(angle) * radius, angle, rate, radius, srate, True)


# --- the limbs (PetRig) ----------------------------------------------------------------------

GAIT = (0.0, 0.5, 0.5, 0.0)
STRIDE, LIFT, SLEEPING_EYES = 0.55, 0.7, 0.28


@dataclass
class Rig:
    leg_lift: list
    leg_swing: list
    leg_tuck: list
    arm_left: float = 0.0
    arm_right: float = 0.0
    eye_open: float = 1.0
    eye_shift: float = 0.0


def blink(time: float) -> float:
    phase = time % 3.4
    return 1.0 if phase >= 0.14 else abs(math.cos(phase / 0.14 * math.pi))


def rig(a: str, t: float, time: float, cursor_x: float = 0.0) -> Rig:
    """PetRigging.rig(for:progress:time:cursorX:)."""
    r = Rig([0.0] * 4, [0.0] * 4, [0.0] * 4, eye_open=blink(time), eye_shift=_mag(cursor_x * 0.008, 0.5))
    tau = 2 * math.pi
    if a == "fret":
        r.eye_open, r.eye_shift = 0.35, 0.0
        wob = math.sin(t * tau * 1.6)
        r.arm_left, r.arm_right = 42 + wob * 6, 42 - wob * 6
        r.leg_swing = [wob * 0.4] * 4
    elif a == "flinch":
        r.eye_open, r.eye_shift = 1.0, 0.0
        shake = math.exp(-t * 5) * math.cos(t * tau * 4)
        r.arm_left, r.arm_right = 58 + shake * 10, 58 - shake * 10
        r.leg_swing = [shake * 1.2] * 4
    elif a == "watch":
        r.eye_shift = _mag(cursor_x * 0.01, 0.6)
        swing = math.sin(t * tau * 0.7)
        r.arm_left, r.arm_right = swing * 14, -swing * 14
        for i in range(4):
            ph = t * 2.2 + GAIT[i]
            r.leg_lift[i] = max(0.0, math.sin(ph * tau)) * 1.4
            r.leg_swing[i] = math.cos(ph * tau) * 1.0
    elif a in ("peek", "boop"):
        sway = math.sin(time * 1.6) * 0.06
        r.leg_swing = [sway, sway, -sway, -sway]
    elif a == "lookAround":
        sway = math.sin(time * 2.2) * 0.08
        r.leg_swing = [sway, sway, -sway, -sway]
    elif a == "stroll":
        cycle = time / 0.42
        for i in range(4):
            ph = (cycle + GAIT[i]) * tau
            r.leg_lift[i] = max(0.0, math.sin(ph)) * LIFT
            r.leg_swing[i] = math.cos(ph) * STRIDE
        arm = math.cos(cycle * tau) * 14
        r.arm_left, r.arm_right = arm, -arm
    elif a in ("hangLeft", "hangRight"):
        r.arm_left = r.arm_right = 55
        dangle = math.sin(t * tau * 0.9 + 0.6) * 0.35
        for i in range(4):
            r.leg_swing[i] = dangle * (1 + (i % 2) * 0.4)
            r.leg_lift[i] = -0.25
    elif a == "rope":
        r.arm_left = r.arm_right = 70
        lag = math.sin(t * tau * 1.4) * 0.4
        for i in range(4):
            r.leg_swing[i] = lag * (1 + (i % 2) * 0.3)
            r.leg_lift[i] = -0.3
    elif a == "sleep":
        r.eye_open = SLEEPING_EYES
        r.leg_tuck = [1.4] * 4
        breath = math.sin(time * 0.9) * 0.05
        r.arm_left = r.arm_right = -8 + breath * 20
    elif a == "celebrate":
        hop = abs(math.sin(t * 3 * math.pi))
        r.leg_swing = [-hop * 0.8, -hop * 0.3, hop * 0.3, hop * 0.8]
        r.leg_lift = [hop * 0.5, hop * 0.35, hop * 0.35, hop * 0.5]
        r.arm_left = r.arm_right = 70 * hop
        r.eye_open = 1.0
    elif a == "spin":
        air = math.sin(_clamp01(t) * math.pi)
        r.leg_tuck = [air * 1.6] * 4
        r.arm_left = r.arm_right = 40 * air
    return r


def dance(t: float, time: float) -> tuple[Rig, float, float, float]:
    """PetRigging.dance: (rig, offset x, offset y, rotation) in sprite
    widths, for the done card's badge: bounce, sway, spin, jump."""
    r = Rig([0.0] * 4, [0.0] * 4, [0.0] * 4, eye_open=blink(time))
    ox = oy = rot = 0.0
    if t < 0.30:
        b = abs(math.sin(t / 0.30 * 2 * math.pi))
        oy = b * 0.30
        r.arm_left = r.arm_right = 40 + 45 * b
        r.leg_swing = [-0.2, -0.1, 0.1, 0.2]
    elif t < 0.55:
        sway = math.sin((t - 0.30) / 0.25 * 2 * math.pi)
        ox, rot = sway * 0.22, -sway * 12
        r.arm_left, r.arm_right = 30 + sway * 55, 30 - sway * 55
        r.leg_swing = [sway * 0.4, sway * 0.2, sway * 0.2, sway * 0.4]
    elif t < 0.80:
        p = (t - 0.55) / 0.25
        rot = 360 * (1 - (1 - p) ** 3)
        oy = math.sin(p * math.pi) * 0.18
        tuck = math.sin(p * math.pi)
        r.arm_left = r.arm_right = 25 * tuck
        r.leg_tuck = [tuck * 0.5] * 4
    else:
        jump = math.sin((t - 0.80) / 0.20 * math.pi)
        oy = jump * 0.42
        r.arm_left = r.arm_right = 85 * jump
        r.leg_swing = [-jump * 0.9, -jump * 0.35, jump * 0.35, jump * 0.9]
        r.leg_lift = [jump * 0.4, jump * 0.3, jump * 0.3, jump * 0.4]
    return r, ox, oy, rot
