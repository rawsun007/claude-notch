#!/bin/bash
# Rebuild the v1 launch video from source: out/brag.mp4 and out/brag.jpg.
#
# Needs: Node 22+, Python 3 with numpy, ffmpeg, Google Chrome (or CHROME=...).
# The footage comes from docs/demo.mp4, the same file the website serves.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..

[ -d node_modules ] || npm install --silent

# The three highlights, cut from the site's demo recording at 30fps and cropped
# to the strip around the notch. Start times are where each card drops open.
rm -rf clips && mkdir -p clips/a clips/b clips/c
cut() { ffmpeg -v error -y -ss "$2" -i "$ROOT/docs/demo.mp4" -t "$3" \
          -vf "fps=30,crop=1280:600:0:0" -q:v 2 "clips/$1/%04d.jpg"; }
cut a 1.0 4.0      # npm install card, Allow clicked
cut b 7.8 4.25     # destructive card, press-and-hold
cut c 26.0 3.2     # done card
cp "$ROOT/docs/icon-512.png" icon.png

python3 audio.py
rm -rf frames && mkdir -p frames out
node render.mjs full

# Poster: the settled outro frame, baked in as frame 0 so every platform's
# thumbnail shows it. Replacing rather than inserting keeps audio in sync.
cp frames/00654.jpg out/brag.jpg
cp frames/00654.jpg frames/00000.jpg

ffmpeg -v error -y -framerate 30 -i frames/%05d.jpg -i score.wav \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11" \
  -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -profile:v high -movflags +faststart \
  -c:a aac -b:a 192k -ar 48000 -shortest out/brag.mp4
echo "✓ out/brag.mp4"
