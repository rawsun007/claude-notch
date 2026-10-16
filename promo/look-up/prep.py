"""prep.py: the stock footage for LOOK UP, ready to film.

Downloads the Mixkit clips (free licence) into clips/ and re-encodes each one
all-intra (every frame a keyframe), so the page can seek to any frame
exactly. For the green-screen laptop (14601) it also tracks the screen: the
four corners of the green area on every frame, written to track.json, so the
ClaudeNotch UI is warped onto the screen and follows the camera's slow push.
Nothing here is committed: clips/ and track.json are rebuilt."""
import json, os, subprocess
import numpy as np

CLIPS = {  # id: (Mixkit size to fetch, what it shows)
    "1746": ("1080", "laptop and a water glass on a bright desk"),
    "41859": ("1080", "latte art being poured"),
    "50766": ("1080", "man resting on a sofa"),
    "4907": ("1080", "hands typing, close"),
    "43263": ("1080", "latte beside a laptop"),
    "14601": ("720", "laptop with a green screen on a wooden desk"),
}
os.makedirs("clips", exist_ok=True)
for cid, (size, _) in CLIPS.items():
    src, out = f"clips/{cid}-src.mp4", f"clips/{cid}.mp4"
    if not os.path.exists(src):
        subprocess.run(["curl", "-sL", "-A", "Mozilla/5.0", f"https://assets.mixkit.co/videos/{cid}/{cid}-{size}.mp4", "-o", src], check=True)
    if not os.path.exists(out):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-an", "-vf", "fps=24", "-c:v", "libx264", "-g", "1", "-crf", "16",
                        "-pix_fmt", "yuv420p", "-movflags", "+faststart", out], check=True)

# track the green screen of 14601, frame by frame at 24 fps
W, H = 1280, 720
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", "clips/14601.mp4", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
frames = np.frombuffer(raw, np.uint8).reshape(-1, H, W, 3).astype(np.int16)
track = []
for f in frames:
    r, g, b = f[..., 0], f[..., 1], f[..., 2]
    ys, xs = np.nonzero((g > 90) & (g > r + 35) & (g > b + 35))
    s, d = xs + ys, xs - ys
    track.append([[int(xs[s.argmin()]), int(ys[s.argmin()])], [int(xs[d.argmax()]), int(ys[d.argmax()])],
                  [int(xs[s.argmax()]), int(ys[s.argmax()])], [int(xs[d.argmin()]), int(ys[d.argmin()])]])
json.dump({"fps": 24, "size": [W, H], "corners": track}, open("track.json", "w"))
print(len(track), "frames tracked; first", track[0], "last", track[-1])
