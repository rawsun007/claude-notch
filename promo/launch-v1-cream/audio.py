"""Score + sound effects for the ClaudeNotch brag video, written as one piece.

Everything is in C major at 120 bpm, so the effects land on notes the music is
already playing instead of fighting it. Timings come from timeline.json, which
the page also reads, so picture and sound cannot drift apart.
"""
import json, wave
import numpy as np

SR = 48000
T = json.load(open("timeline.json"))
DUR = T["duration"]
N = int(SR * DUR) + SR  # one second of tail, trimmed at the end
L = np.zeros(N); R = np.zeros(N)
rng = np.random.default_rng(7)

def midi(m): return 440.0 * 2 ** ((m - 69) / 12)
def t_of(n): return np.arange(n) / SR

def add(sig, at, gain=1.0, pan=0.0):
    i = int(at * SR)
    if i >= N: return
    sig = sig[: N - i]
    l = np.cos((pan + 1) * np.pi / 4); r = np.sin((pan + 1) * np.pi / 4)
    L[i:i + len(sig)] += sig * gain * l
    R[i:i + len(sig)] += sig * gain * r

def env(n, a, d_curve):
    e = np.ones(n)
    ai = max(1, int(a * SR))
    e[:ai] = np.linspace(0, 1, ai)
    return e * d_curve

def lowpass(x, cutoff):
    # one-pole, run twice for a gentler 12 dB slope
    a = np.exp(-2 * np.pi * cutoff / SR)
    for _ in range(2):
        y = np.empty_like(x); acc = 0.0
        for k in range(len(x)):
            acc = (1 - a) * x[k] + a * acc; y[k] = acc
        x = y
    return x

# ---- music ---------------------------------------------------------------
BPM = 120; BEAT = 60 / BPM; BAR = BEAT * 4
CHORDS = [  # two bars each: Cmaj7, Am7, Fmaj7, G6
    [48, 55, 59, 64, 67], [45, 52, 55, 60, 64],
    [41, 48, 52, 57, 60], [43, 50, 55, 59, 64],
]
S = {s["id"]: s for s in T["scenes"]}
drums_in = S["reveal"]["start"]
hats_in = S["allow"]["start"]
outro = S["outro"]["start"]
drums_out = DUR - 1.6

def pad_note(freq, n):
    t = t_of(n)
    x = sum(np.sin(2 * np.pi * freq * d * t + p) for d, p in [(1, 0), (1.004, 1.3), (0.996, 2.1)])
    x += 0.25 * np.sin(2 * np.pi * freq * 2.001 * t)
    return x / 3.5

def pluck(freq, n=int(0.45 * SR)):
    t = t_of(n)
    x = np.sin(2 * np.pi * freq * t) + 0.3 * np.sin(2 * np.pi * freq * 2 * t) * np.exp(-t * 18)
    return x * np.exp(-t * 7) * np.minimum(1, t * 400)

chord_len = BAR * 2
k = 0; at = 0.0
while at < DUR:
    ch = CHORDS[k % 4]
    if at >= outro - 0.01 and at < outro + chord_len:  # land the outro on home
        ch = CHORDS[0]
    n = int(chord_len * SR) + int(0.6 * SR)
    t = t_of(n)
    e = np.minimum(1, t / 0.5) * np.minimum(1, np.maximum(0, (chord_len + 0.6 - t) / 0.6))
    for j, m in enumerate(ch[1:]):
        add(pad_note(midi(m + 12), n) * e, at, 0.050, pan=(-0.5 + j * 0.33))
    # bass on 1 and 3 once the drums are in
    for b in range(4):
        bt = at + b * BEAT * 2
        if bt < drums_in or bt > drums_out: continue
        bn = int(0.7 * SR); tb = t_of(bn)
        bs = np.sin(2 * np.pi * midi(ch[0] - 12) * tb) + 0.2 * np.sin(2 * np.pi * midi(ch[0]) * tb)
        add(bs * np.exp(-tb * 3.2) * np.minimum(1, tb * 300), bt, 0.16)
    # eighth-note arpeggio, soft, from the first highlight
    arp = [ch[1] + 24, ch[2] + 24, ch[3] + 24, ch[2] + 24]
    for e8 in range(16):
        et = at + e8 * BEAT / 2
        if et < S["reveal"]["start"] or et > drums_out: continue
        g = 0.045 if et >= hats_in else 0.03
        add(pluck(midi(arp[e8 % 4])), et, g, pan=0.35 if e8 % 2 else -0.35)
        add(pluck(midi(arp[e8 % 4])), et + BEAT * 0.75, g * 0.35, pan=-0.5 if e8 % 2 else 0.5)  # delay tap
    at += chord_len; k += 1

# the hook: a lone, patient pluck, the terminal waiting
for i, m in enumerate([76, 79, 76, 79, 76, 79]):
    add(pluck(midi(m)), 0.25 + i * 0.5, 0.035, pan=0.2)

def kick():
    n = int(0.35 * SR); t = t_of(n)
    f = 45 + 75 * np.exp(-t * 30)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 9)

def hat():
    n = int(0.06 * SR); x = rng.standard_normal(n)
    x = x - lowpass(x.copy(), 6000)
    return x * np.exp(-t_of(n) * 70)

def clap():
    n = int(0.18 * SR); x = rng.standard_normal(n)
    x = lowpass(x - lowpass(x.copy(), 900), 5000)
    return x * np.exp(-t_of(n) * 22)

HAT = hat(); CLAP = clap(); KICK = kick()
b = 0; bt = 0.0
while bt < drums_out:
    if bt >= drums_in - 0.01:
        add(KICK, bt, 0.34)
        if bt >= hats_in and b % 2 == 1: add(CLAP, bt, 0.05, pan=0.1)
    if bt + BEAT / 2 >= hats_in and bt + BEAT / 2 < drums_out:
        add(HAT, bt + BEAT / 2, 0.035, pan=-0.25)
    b += 1; bt += BEAT

# ---- effects, same key ---------------------------------------------------
def whoosh(d=0.5):
    n = int(d * SR); x = rng.standard_normal(n)
    x = lowpass(x, 2500) - lowpass(x.copy(), 300)
    t = t_of(n); e = np.sin(np.pi * t / d) ** 2
    return x * e

def blip(m, d=0.22, drop=0.0):
    n = int(d * SR); t = t_of(n)
    f = midi(m) * (1 + drop * np.exp(-t * 40))
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) + 0.2 * np.sin(2 * np.pi * 2 * np.cumsum(f) / SR)
    return x * np.exp(-t * 16) * np.minimum(1, t * 800)

def bell(m, d=1.2):
    n = int(d * SR); t = t_of(n); f = midi(m)
    x = sum(a * np.sin(2 * np.pi * f * r * t) * np.exp(-t * dcy) for a, r, dcy in
            [(1, 1, 3.0), (0.4, 2.0, 5), (0.2, 3.01, 8), (0.1, 4.2, 12)])
    return x * np.minimum(1, t * 600)

for s in T["scenes"][1:]:
    add(whoosh(0.55), s["start"] - 0.35, 0.05, pan=0.0)

for cue in T["cues"]:
    c, at = cue["type"], cue["t"]
    if c == "card": add(blip(79, drop=0.5), at, 0.10, pan=0.15)
    elif c == "click":
        add(blip(88, d=0.08), at, 0.06); add(blip(76, d=0.3), at + 0.02, 0.05)
    elif c == "hold":
        d = cue["d"]; n = int(d * SR); t = t_of(n)
        f = midi(72) * 2 ** ((7 / 12) * (t / d))  # C5 up a fifth to G5 across the hold
        x = np.sin(2 * np.pi * np.cumsum(f) / SR) * (0.7 + 0.3 * np.sin(2 * np.pi * 9 * t))
        add(x * np.minimum(1, t / 0.1) * np.minimum(1, (d - t) / 0.05 + 0.001), at, 0.05)
        add(bell(84, 0.9), at + d, 0.07)
    elif c == "done":
        for i, m in enumerate([72, 76, 79, 84]): add(bell(m), at + i * 0.07, 0.06, pan=-0.3 + i * 0.2)
    elif c == "boop":
        n = int(0.28 * SR); t = t_of(n)
        f = midi(72) * 2 ** (np.minimum(1, t / 0.12))
        add(np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 10), at, 0.09, pan=0.1)
    elif c == "land":
        add(KICK, at, 0.12); add(blip(67, d=0.2), at, 0.05)

# outro resolve: a bell chord under the last title
for i, m in enumerate([60, 64, 67, 71, 74]):
    add(bell(m + 12, 3.0), outro + 0.05 + i * 0.03, 0.035, pan=-0.4 + i * 0.2)

# ---- master --------------------------------------------------------------
n_out = int(DUR * SR)
L, R = L[:n_out], R[:n_out]
fade = int(1.2 * SR)
L[-fade:] *= np.linspace(1, 0, fade) ** 2; R[-fade:] *= np.linspace(1, 0, fade) ** 2
L[: int(0.02 * SR)] *= np.linspace(0, 1, int(0.02 * SR)); R[: int(0.02 * SR)] *= np.linspace(0, 1, int(0.02 * SR))
st = np.stack([L, R], 1)
st = np.tanh(st * 1.4) / np.tanh(1.4)  # gentle glue, nothing spiky gets through
st /= np.max(np.abs(st)) / 0.89
with wave.open("score.wav", "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((st * 32767).astype("<i2").tobytes())
print("score.wav", round(DUR, 2), "s")
