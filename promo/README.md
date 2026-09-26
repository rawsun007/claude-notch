# Promo videos

Source for ClaudeNotch's launch videos, made with the
[`/brag`](https://github.com/latent-spaces/brag) skill (`brag-slim`). Each folder
rebuilds one finished video with a single command.

| Folder | Video | Length | Style |
|---|---|---|---|
| `launch-v1-cream/` | v1 | 22.6s | The site's cream editorial look, real `demo.mp4` footage |
| `motion-v2/` | v2 | 25.0s | Dark keynote-style motion piece, app UI rebuilt and animated, 120fps motion blur |
| `motion-v3-egg/` | v3 | 30.0s | v2 plus a post-credits Spider-Pet scene |

## Rebuild

```bash
promo/launch-v1-cream/build.sh     # about a minute
promo/motion-v2/build.sh           # 3000 frames; a few minutes on an awake Mac
promo/motion-v3-egg/build.sh       # 3600 frames
```

Output lands in each folder's `out/` (`brag.mp4`, plus `brag.jpg`, the
thumbnail, which is also baked in as the video's first frame).

Needs Node 22+, Python 3 with numpy, ffmpeg and Google Chrome (set `CHROME` to
use another Chromium). v2 and v3 need macOS, because the rebuilt app UI loads
the system font from `/System/Library/Fonts`. Keep the Mac awake while it
renders: a headless Chrome in the background gets throttled, and one v2 rebuild
took 42 minutes instead of a few for exactly that reason.

## How a video is made

- `timeline.json`: every scene's start and length, and every sound cue. The
  picture and the score both read it, so they cannot drift apart.
- `index.html`: a frame renderer, not a web page. `render(t)` draws the frame
  at time `t` and nothing depends on the clock, so any frame renders on its
  own and the result is reproducible.
- `render.mjs`: loads the page in headless Chrome and screenshots each frame.
  `node render.mjs stills 3.2 7.5` renders single frames for review.
- `audio.py`: the whole score and every sound effect, synthesized in numpy.
  No samples and no downloaded audio, so nothing needs a licence.
- `build.sh`: runs all of the above and encodes the MP4.
- `brag-plan.md`: the storyboard; `share-copy.txt`: the caption.

## Why the MP4s are not in git

A finished cut is 49 to 56 MB. Git keeps every version of a binary forever, so
each render would add that permanently to every clone, CI run and Homebrew tap
fetch (the repo was 104 MB before any of this), and GitHub warns on files over
50 MB. The source here is about 100 KB per video and rebuilds the same video:
v1 rebuilds byte-identical, and v2 and v3 match the shipped cuts frame for
frame apart from a few frames that differ at 62 to 88 dB PSNR, well past
visible, from Chrome rasterising heavy blur filters very slightly differently
between browser sessions.

To host a finished video, attach it to a GitHub Release or put a compressed
copy on the website, rather than committing it here.

## Content notes

- Headlines are the site's own copy, except "Look up.", "It backflips.
  Obviously." and "Some days, a guest drops in."
- In v2 and v3 the session names, branches and dollar amounts are
  illustrative UI, not claims about real usage.
- The Spider-Pet in v3 is the app's own guest appearance, drawn as the app
  draws it. The music under it is original and the character is never named
  on screen: the film theme and the meme song the app bundles are both
  copyrighted.
- No em dashes in anything written for the videos, including the rebuilt UI,
  where the real cards' dashes became colons. The one exception is v1's real
  footage, which shows the demo card exactly as it appeared.
