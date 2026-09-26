"""Score and sound design for the ClaudeNotch motion piece, as one mix.

D minor at 120 bpm, so every cut in timeline.json lands on a beat. Music and
effects share one reverb (the same room), the pads and bass duck under the
kick, and every tonal effect is pitched to a note of the chord under it.
"""
import json, wave
import numpy as np

SR = 48000
T = json.load(open("timeline.json"))
DUR = T["duration"]
N = int(SR * (DUR + 2.5))
BEAT = 60 / T["bpm"]; BAR = 4 * BEAT
rng = np.random.default_rng(11)
SC = {s["id"]: s for s in T["scenes"]}

def buses():
    return np.zeros((N, 2))
dry, wet, duck = buses(), buses(), buses()   # duck: goes through the sidechain

def midi(m): return 440.0 * 2 ** ((m - 69) / 12)
def tt(d): return np.arange(int(d * SR)) / SR

def put(bus, sig, at, g=1.0, pan=0.0, send=0.0, into=None):
    i = int(at * SR)
    if i >= N or i + len(sig) <= 0: return
    if i < 0: sig = sig[-i:]; i = 0
    sig = sig[: N - i]
    l, r = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    bus[i:i + len(sig), 0] += sig * g * l; bus[i:i + len(sig), 1] += sig * g * r
    if send:
        wet[i:i + len(sig), 0] += sig * g * send * l; wet[i:i + len(sig), 1] += sig * g * send * r

def onepole(x, fc):
    a = np.exp(-2 * np.pi * fc / SR)
    # vectorised one-pole via lfilter-equivalent recursion in chunks
    y = np.empty_like(x); acc = 0.0
    for k in range(len(x)):
        acc = (1 - a) * x[k] + a * acc; y[k] = acc
    return y

def lp(x, fc, passes=2):
    for _ in range(passes): x = onepole(x, fc)
    return x

def saw(f, t):
    # band-limited-ish saw from a handful of partials
    return sum(np.sin(2 * np.pi * f * k * t) / k for k in range(1, 9)) * 0.55

# ---------- chords ----------
# i  VI  III  VII in D minor: Dm9, Bbmaj7, Fmaj9, C(add9); outro lands on Fadd9 (the relative major lift)
PROG = [[38, 50, 53, 57, 60, 64], [34, 50, 53, 57, 58, 62], [41, 53, 57, 60, 64, 67], [36, 52, 55, 60, 62, 67]]
OUTRO_CH = [41, 53, 57, 60, 65, 67, 72]
drop = SC["allow"]["start"]; petS = SC["pet"]["start"]; outro = SC["outro"]["start"]; look = SC["lookup"]["start"]

def chord_at(t):
    if t >= outro: return OUTRO_CH
    return PROG[int(t // (2 * BAR)) % 4]

# ---------- pads (through the sidechain) ----------
step = 2 * BAR
at = 0.0
while at < outro:
    ch = chord_at(at + 0.01); d = min(step, outro - at) + 0.8; t = tt(d)
    e = np.minimum(1, t / 0.6) * np.minimum(1, np.maximum(0, (d - t) / 0.8))
    for j, m in enumerate(ch[1:]):
        f = midi(m)
        v = (saw(f, t) + saw(f * 1.006, t) + saw(f * 0.994, t)) / 3
        cutoff = 900 if at < drop else 2200
        v = lp(v, cutoff, 1)
        g = 0.030 if at < look else 0.045
        put(duck, v * e, at, g, pan=-0.6 + j * 0.3, send=0.5)
    at += step

# outro pad: wide, bright, no sidechain, long tail
t = tt(DUR - outro + 2.0)
e = np.minimum(1, t / 0.08) * (0.55 + 0.45 * np.exp(-t * 1.2))  # hit, then sustain under the titles
for j, m in enumerate(OUTRO_CH[1:]):
    f = midi(m)
    v = lp((saw(f, t) + saw(f * 1.005, t)) / 2, 2600, 1)
    put(dry, v * e, outro, 0.10, pan=-0.7 + j * 0.23, send=0.7)

# ---------- bass: 8ths from the drop, sidechained ----------
def bass_note(f, d=BEAT / 2):
    t = tt(d); x = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(2 * np.pi * 2 * f * t) + 0.12 * saw(f, t)
    return x * np.exp(-t * 6) * np.minimum(1, t * 500)
bt = drop
while bt < outro - 0.01:
    if petS <= bt < outro:  # half-time for the pet
        if round((bt - drop) / BEAT) % 2 == 0:
            put(duck, bass_note(midi(chord_at(bt)[0]), BEAT), bt, 0.22)
    else:
        put(duck, bass_note(midi(chord_at(bt)[0])), bt, 0.24)
    bt += BEAT / 2

# ---------- arp lead: from the guard scene ----------
def pluck(f, d=0.5):
    t = tt(d); x = np.sin(2 * np.pi * f * t) + 0.4 * np.sin(2 * np.pi * 2 * f * t) * np.exp(-t * 20) + 0.15 * np.sin(2 * np.pi * 3 * f * t) * np.exp(-t * 30)
    return x * np.exp(-t * 8) * np.minimum(1, t * 800)
at = SC["guard"]["start"]; k = 0
while at < petS:
    ch = chord_at(at); pat = [ch[2] + 12, ch[3] + 12, ch[4] + 12, ch[5] + 12, ch[4] + 12, ch[3] + 12]
    put(dry, pluck(midi(pat[k % 6])), at, 0.05, pan=0.4 if k % 2 else -0.4, send=0.45)
    at += BEAT / 4 if at >= SC["sessions"]["start"] else BEAT / 2; k += 1
# pet: a playful marimba-ish figure
for i, m in enumerate([74, 77, 81, 77, 72, 74, 77, 84]):
    tp = petS + i * BEAT / 2
    t = tt(0.4); x = (np.sin(2 * np.pi * midi(m) * t) + 0.3 * np.sin(2 * np.pi * midi(m) * 4 * t) * np.exp(-t * 40)) * np.exp(-t * 11)
    put(dry, x, tp, 0.06, pan=-0.3 + 0.08 * i, send=0.3)

# ---------- drums ----------
def kick():
    t = tt(0.45); f = 42 + 110 * np.exp(-t * 28)
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 7)
    click = rng.standard_normal(len(t)) * np.exp(-t * 300) * 0.3
    return np.tanh((x + click) * 1.6)
def snare():
    t = tt(0.3); n = rng.standard_normal(len(t))
    n = lp(n - lp(n.copy(), 700, 1), 7000, 1)
    tone = np.sin(2 * np.pi * 190 * t) * np.exp(-t * 25)
    return (n * np.exp(-t * 16) * 0.8 + tone * 0.5)
def hat(open_=False):
    d = 0.22 if open_ else 0.05; t = tt(d); n = rng.standard_normal(len(t))
    n = n - lp(n.copy(), 7000, 1)
    return n * np.exp(-t * (14 if open_ else 80))
K, SN, H, HO = kick(), snare(), hat(), hat(True)
kicks = []
b = drop
while b < outro - 0.01:
    beat_i = round((b - drop) / BEAT)
    half = petS <= b
    if not half or beat_i % 2 == 0:
        put(dry, K, b, 0.55); kicks.append(b)
    if (beat_i % 4 == 2 if half else beat_i % 2 == 1): put(dry, SN, b, 0.16, pan=0.05, send=0.35)
    for s16 in range(4):
        ht = b + s16 * BEAT / 4
        if half and s16 % 2: continue
        vel = [0.05, 0.022, 0.035, 0.022][s16]
        put(dry, H, ht, vel * (0.5 if half else 1), pan=-0.3)
    if not half: put(dry, HO, b + BEAT / 2, 0.02, pan=0.3, send=0.2)
    b += BEAT
# the hook: a heartbeat, low and filtered, plus a clock tick: something is waiting
for i in range(6):
    hb = 0.0 + i * BEAT
    put(dry, lp(K.copy(), 180), hb, 0.35)
    put(dry, lp(K.copy(), 180), hb + 0.16, 0.18)
    put(dry, H, hb + BEAT / 2, 0.025, pan=0.4, send=0.3)
kicks += [i * BEAT for i in range(6)]

# ---------- effects, pitched into the chord ----------
def whoosh(d, up=True):
    t = tt(d); n = rng.standard_normal(len(t))
    lo = lp(n.copy(), 400, 1); hi = lp(n.copy(), 3500, 1)
    sweep = (t / d) if up else (1 - t / d)
    x = lo * (1 - sweep) + (hi - lo) * sweep
    return x * np.sin(np.pi * t / d) ** 2
def boom(d=2.5):
    t = tt(d); f = 32 + 40 * np.exp(-t * 6)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 1.6) * np.minimum(1, t * 300)
def impact():
    t = tt(0.7); f = 55 + 80 * np.exp(-t * 20)
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 6)
    n = lp(rng.standard_normal(len(t)), 2500, 1) * np.exp(-t * 18)
    return x + n * 0.6
def bell(m, d=1.4, bright=1.0):
    t = tt(d); f = midi(m)
    return sum(a * np.sin(2 * np.pi * f * r * t) * np.exp(-t * dc) for a, r, dc in
               [(1, 1, 2.6), (0.5 * bright, 2.0, 4.5), (0.25 * bright, 3.0, 7), (0.12 * bright, 4.16, 11)]) * np.minimum(1, t * 900)
def tick(m, d=0.12):
    t = tt(d); return np.sin(2 * np.pi * midi(m) * t) * np.exp(-t * 45) * np.minimum(1, t * 2000)
def uiclick():
    t = tt(0.05); n = rng.standard_normal(len(t)); n = n - lp(n.copy(), 2500, 1)
    return n * np.exp(-t * 160)

for c in T["cues"]:
    ty, at = c["type"], c["t"]
    if ty == "whip": put(dry, whoosh(0.5), at - 0.2, 0.35, send=0.4); put(dry, impact(), at + 0.15, 0.18, send=0.4)
    elif ty == "boom": put(dry, boom(), at, 0.55, send=0.3); put(dry, bell(74, 2.5, 0.6), at, 0.04, send=0.8); put(dry, bell(62, 2.5, 0.4), at, 0.05, send=0.8)
    elif ty == "riser":
        d = c["d"]; t = tt(d); f = midi(50) * 2 ** (2 * (t / d) ** 2)
        x = saw(1, np.cumsum(f) / SR) * (t / d) ** 2
        put(dry, lp(x, 3000, 1), at, 0.05, send=0.5); put(dry, whoosh(d), at, 0.18 * 1.0, send=0.5)
    elif ty == "morph": put(dry, impact(), at, 0.16, send=0.35); put(dry, whoosh(0.4, False), at - 0.05, 0.12, send=0.3); put(dry, tick(chord_at(at)[3] + 24), at + 0.02, 0.04, send=0.5)
    elif ty == "whoosh": put(dry, whoosh(0.45), at - 0.1, 0.16, pan=0.2, send=0.4)
    elif ty == "click": put(dry, uiclick(), at, 0.3); put(dry, tick(86, 0.06), at, 0.035)
    elif ty == "confirm":
        for i, m in enumerate([69, 74, 77]): put(dry, bell(m + 12, 0.9), at + i * 0.05, 0.05, pan=-0.2 + i * 0.2, send=0.5)
    elif ty == "warn":
        for i in range(3): put(dry, tick(62 + (i == 2) * 3, 0.1), at + 0.1 + i * 0.14, 0.05, pan=-0.3 + 0.3 * i, send=0.3)
    elif ty == "press": put(dry, uiclick(), at, 0.3)
    elif ty == "hold":
        d = c["d"]; t = tt(d)
        f = midi(62) * 2 ** ((7 / 12) * (t / d))     # D up to A across the hold
        x = np.sin(2 * np.pi * np.cumsum(f) / SR) * (0.7 + 0.3 * np.sin(2 * np.pi * 11 * t))
        x += 0.5 * np.sin(2 * np.pi * np.cumsum(f * 2) / SR)
        put(dry, x * np.minimum(1, t / 0.08) * (t / d * 0.7 + 0.3), at, 0.04, send=0.4)
        put(dry, rng.standard_normal(len(t)) * (t / d) ** 2 * 0.3, at, 0.03, send=0.4)
        put(dry, bell(81, 1.2), at + d, 0.07, send=0.6); put(dry, impact(), at + d, 0.1, send=0.3)
    elif ty == "diff":
        notes = [69, 72, 74, 76, 77, 81]
        for i in range(c["n"]): put(dry, tick(notes[i] + 12, 0.09), at + i * c["step"], 0.035, pan=-0.5 + i * 0.2, send=0.35)
    elif ty == "rows":
        for i, m in enumerate([62, 65, 69, 72]): put(dry, bell(m + 12, 0.6, 0.5), at + i * c["step"], 0.04, pan=-0.4 + i * 0.25, send=0.4)
    elif ty == "pop":
        t = tt(0.3); f = midi(62) * 2 ** (np.minimum(1, t / 0.1) * 1.0)
        put(dry, np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 12), at, 0.08, send=0.3)
    elif ty == "flip":
        t = tt(0.62); f = midi(69) * 2 ** (np.sin(np.pi * t / 0.62) * 1.0)
        put(dry, np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 2.5) * 0.7, at, 0.05, send=0.4)
        put(dry, whoosh(0.6), at, 0.1, send=0.3)
    elif ty == "land":
        put(dry, lp(K.copy(), 400), at, 0.25)
        for i, m in enumerate([81, 84, 86, 89]): put(dry, tick(m, 0.2), at + 0.03 + i * 0.04, 0.03, pan=-0.4 + 0.27 * i, send=0.7)
    elif ty == "shimmer":
        # a slow, soft arpeggio carries the titles to the end
        for i, m in enumerate([65, 69, 72, 77, 76, 72, 69, 72]):
            put(dry, pluck(midi(m + 12), 0.9), at + 0.6 + i * BEAT / 2, 0.06, pan=-0.4 + 0.1 * i, send=0.6)
        for i, m in enumerate([77, 81, 84, 88, 91, 96]): put(dry, bell(m, 2.0, 0.4), at + i * 0.06, 0.018, pan=-0.6 + i * 0.24, send=0.9)

# silence the bar before the drop so the drop lands: cut music 150 ms before it
gap0, gap1 = int((drop - 0.16) * SR), int(drop * SR)
duck[gap0:gap1] *= np.linspace(1, 0, gap1 - gap0)[:, None] * 0.0

# ---------- sidechain ----------
g = np.ones(N)
for kt in kicks:
    i = int(kt * SR); n = int(0.35 * SR)
    seg = 1 - 0.65 * np.exp(-np.arange(n) / (0.09 * SR))
    j = min(N, i + n); g[i:j] = np.minimum(g[i:j], seg[: j - i])
duck *= g[:, None]
dry += duck
wet[:, 0] += duck[:, 0] * 0.25; wet[:, 1] += duck[:, 1] * 0.25

# ---------- one room: FFT convolution with a synthetic stereo IR ----------
def ir(seed, d=2.4):
    r = np.random.default_rng(seed); t = tt(d)
    x = r.standard_normal(len(t)) * np.exp(-t * 3.0)
    x = lp(x, 6000, 1); x[: int(0.012 * SR)] = 0
    return x / np.sqrt((x ** 2).sum())
def conv(x, h):
    n = 1 << int(np.ceil(np.log2(len(x) + len(h))))
    return np.fft.irfft(np.fft.rfft(x, n) * np.fft.rfft(h, n), n)[: len(x)]
rev = np.stack([conv(wet[:, 0], ir(1)), conv(wet[:, 1], ir(2))], 1)
mix = dry + rev * 0.9

# ---------- master ----------
mix = mix[: int(DUR * SR)]
f = int(1.5 * SR); mix[-f:] *= (np.linspace(1, 0, f) ** 2)[:, None]
mix -= mix.mean(0)
mix = np.tanh(mix * 1.8) / np.tanh(1.8)
mix /= np.abs(mix).max() / 0.9
with wave.open("score.wav", "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((mix * 32767).astype("<i2").tobytes())
print("score.wav", DUR, "s")
