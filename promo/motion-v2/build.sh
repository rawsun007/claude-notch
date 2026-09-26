#!/bin/bash
# Rebuild the v2 motion piece from source: out/brag.mp4 and out/brag.jpg.
#
# Needs: Node 22+, Python 3 with numpy, ffmpeg, Google Chrome (or CHROME=...),
# and macOS: the rebuilt app UI loads the system font from /System/Library.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..

[ -d node_modules ] || npm install --silent
cp "$ROOT/docs/icon-512.png" icon.png
python3 audio.py

# 120fps in two halves, one browser each. Waiting on each pid by name makes a
# crash in either half fail the build instead of encoding a video with a hole.
N=$(python3 -c "import json;t=json.load(open('timeline.json'));print(round(t['duration']*t['renderFps']))")
rm -rf frames && mkdir -p frames out
node render.mjs full 0 $((N / 2)) & A=$!
node render.mjs full $((N / 2)) "$N" & B=$!
wait $A; wait $B

# Poster: the settled title card, baked in as frame 0 of the output.
cp frames/02880.jpg out/brag.jpg

# Motion blur: average each run of three 120fps frames, keep every fourth
# (a 270 degree shutter). Loudness to -14 LUFS, then a limiter, because
# loudnorm alone let true peak reach +1.1 dBFS after AAC.
ffmpeg -v error -y -framerate 120 -i frames/%05d.jpg -i out/brag.jpg -i score.wav \
  -filter_complex "[0:v]tmix=frames=3:weights='1 1 1',fps=30[b];[b][1:v]overlay=enable='eq(n\,0)'[v];[2:a]loudnorm=I=-14:TP=-1.5:LRA=11,alimiter=limit=0.82:level=false[a]" \
  -map "[v]" -map "[a]" -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -profile:v high \
  -movflags +faststart -c:a aac -b:a 256k -ar 48000 -shortest out/brag.mp4
echo "✓ out/brag.mp4"
