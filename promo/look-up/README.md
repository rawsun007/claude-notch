# LOOK UP

A 36.4 s ClaudeNotch promo in Claude's own palette: ivory paper, ink, clay,
and a sage green for good news. Real stock footage of someone who stepped
away, a terminal left waiting, then the notch on a real laptop asking the
question. No springs and no bounce: long eases, masked text rises, and a clay
band that wipes between paper scenes.

```bash
PASSES=6 ./master.sh     # look-up.mp4
node rig.mjs proof 12 18.5 25.9   # stills into proofs/
```

## Pieces

- `prep.py`: downloads the Mixkit clips (free for commercial use), re-encodes
  them all-intra so every frame seeks exactly, and tracks the four corners of
  the green screen in clip 14601, frame by frame, into `track.json`.
- `film.html`: `paint(t)` draws frame `t`. Footage is seeked to the exact
  frame and awaited. The laptop shot keys the green in WebGL (with spill
  suppression on the bezel) and samples the app UI through the inverse
  homography of that frame's tracked corners, so the UI sits on the screen as
  the camera drifts. Then the camera pushes into the screen and hands over to
  the same UI drawn crisp.
- `rig.mjs`: headless Chrome, 120 fps, four frames blended to one at 30 fps.
- `mix.py`: Mixkit "Digital Clouds" (#175) from 18.8 s, so its lift lands on
  the laptop shot at 9.2 s; two-pass loudnorm to -14 LUFS.

## Shots

| Film s | Shot |
|---|---|
| 0.0 | Hands on a laptop: "Claude is working." |
| 1.9 | Latte art: "You step away for a minute." |
| 3.7 | On the sofa: "Meanwhile, it has a question." |
| 5.6 | A terminal on paper, waiting, the clock running |
| 7.4 | "Look up." with a clay underline |
| 9.2 | The lift: the green-screen laptop, the card drops in its notch, Allow, push in, Done |
| 16.6 | Touch ID on `rm -rf` |
| 20.3 | Every session, its spend, its context |
| 24.0 | Skills: one plugin off, 2,945 tokens back |
| 27.7 | Everything else, beside coffee b-roll |
| 31.4 | Icon, name, brew command |

The UI is rebuilt for the film; it is illustrative, drawn from the real cards.
