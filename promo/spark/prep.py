"""prep.py: downloads the Mixkit stock clips (free for commercial use) and
re-encodes them all-intra at 24 fps, so film.html can seek any frame exactly
and fast. Clips land in clips/<id>.mp4; rerunning skips what is there."""
import os, subprocess
CLIPS = {  # id: size Mixkit serves
    "1728": 1080, "43527": 1080, "1781": 1080, "41656": 1080, "41655": 1080,
    "42343": 1080, "40746": 1080, "41161": 1080, "23215": 720, "47050": 720,
}
os.makedirs("clips", exist_ok=True)
for cid, size in CLIPS.items():
    out = f"clips/{cid}.mp4"
    if os.path.exists(out): continue
    src = f"clips/{cid}-src.mp4"
    subprocess.run(["curl", "-sfL", "-A", "Mozilla/5.0", f"https://assets.mixkit.co/videos/{cid}/{cid}-{size}.mp4", "-o", src], check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-an", "-t", "12", "-vf", "fps=24,scale=-2:1080:flags=lanczos",
                    "-c:v", "libx264", "-g", "1", "-crf", "16", "-pix_fmt", "yuv420p", out], check=True)
    print(out)
