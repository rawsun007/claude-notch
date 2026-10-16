#!/bin/bash
# Build SPARK: spark.mp4. PASSES=n browsers at once (default 4).
set -euo pipefail
cd "$(dirname "$0")"
python3 prep.py
python3 config.py
[ -f song.mp3 ] || curl -sL -A "Mozilla/5.0" https://assets.mixkit.co/music/371/371.mp3 -o song.mp3
cp ../../docs/icon-512.png icon.png
D=$(node rig.mjs duration); python3 mix.py "$D"
read N S < <(python3 -c "import json; c = json.load(open('config.json')); print(round($D * c['shoot_fps']) // c['sub'] * c['sub'], c['sub'])"); PASSES=${PASSES:-4}
# Each pass streams its frames into its own segment; nothing is kept on disk.
mkdir -p segs; T=$(( (N / PASSES + S - 1) / S * S )); PIDS=()
for ((i = 0; i < PASSES; i++)); do A=$((i * T)); B=$(( (i + 1) * T < N ? (i + 1) * T : N )); node rig.mjs pipe $A $B segs/s$i.mp4 & PIDS+=($!); done
for p in "${PIDS[@]}"; do wait "$p"; done
: > segs/list.txt; for ((i = 0; i < PASSES; i++)); do echo "file 's$i.mp4'" >> segs/list.txt; done
ffmpeg -v error -y -f concat -safe 0 -i segs/list.txt -i mix.wav \
  -vf "scale=in_range=pc:out_range=tv:out_color_matrix=bt709,format=yuv420p" \
  -map 0:v -map 1:a -map_metadata -1 -c:v libx264 -preset slow -crf 18 -profile:v high -level 4.2 -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
  -af "volume=-1dB,alimiter=limit=0.7:level=false" -movflags +faststart -c:a aac -b:a 192k -ar 48000 -shortest spark.mp4
echo "done: spark.mp4"
