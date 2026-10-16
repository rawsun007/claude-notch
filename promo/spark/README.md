# SPARK

A 38.1 s ClaudeNotch promo cut to Mixkit "Cat Walk" (#371, 130 bpm). It uses
Claude's two moods, ink and ivory, and they trade places on the bar. Stock
footage is graded to one ink, clay and ivory duotone in WebGL, so ten
unrelated clips read as one film. The energy comes from cuts on the beat, not
from springs: every move is an ease-out that settles without overshoot.

```bash
PASSES=6 ./master.sh     # spark.mp4
node rig.mjs proof 7.5 15.5 26.3   # stills into proofs/
```

## The beat map (130 bpm, one beat = 0.4615 s)

| Beats | Scene |
|---|---|
| 0-4 | Ink. The Claude spark, a ring on every beat: "You gave Claude the keys." |
| 4-12 | Duotone montage, a cut on every beat: "It writes. It tests. It ships. It asks." |
| 12-15 | Ivory. Permission prompts pile up: "And then it waits for you." |
| 15-16 | A clean screen and the notch, alone, inhaling |
| 16 | **The drop.** The notch floods the frame: "Never miss a beat." |
| 24-32 | The card drops, Allow, Allowed, Done |
| 32-40 | Eight cards, one per beat: questions, Touch ID, done, sessions, spend, context, skills, agents |
| 40-48 | Footage with big numbers: 3 sessions, $4.12, 62%, 0 prompts missed |
| 48-56 | Reply to a background agent without switching windows |
| 56-64 | Sixteen features, one per half beat |
| 64-72 | Skills: one plugin off, 2,945 tokens back |
| 72-80 | Icon, name, brew command |

`config.py` starts the song at 22.23 s, so its drop (29.615 s, measured from
the kick drum) lands on beat 16. The UI is rebuilt for the film and is
illustrative, drawn from the real cards.
