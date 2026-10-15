"""mix.py: Mixkit "Gimme That Groove!" (#872, free for commercial use) from its
first note, so its groove starts on the bar at 2.16 s; faded over the last 1.2 s; two-pass
loudnorm to -14 LUFS. Writes mix.wav."""
import json, subprocess, sys
import numpy as np
SR = 48000; T = float(sys.argv[1]); N = int(T * SR); START = 0
raw = subprocess.run(["ffmpeg", "-v", "quiet", "-ss", str(START), "-i", "song.mp3", "-ac", "2", "-ar", str(SR), "-f", "f32le", "-"], capture_output=True, check=True).stdout
x = np.frombuffer(raw, np.float32).reshape(-1, 2)[:N].copy()
if len(x) < N: x = np.vstack([x, np.zeros((N - len(x), 2), np.float32)])
fi = int(0.05 * SR); x[:fi] *= np.linspace(0, 1, fi)[:, None]
f0 = int((T - 1.2) * SR); x[f0:] *= (np.linspace(1, 0, N - f0) ** 1.4)[:, None]
subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", "-", "raw.wav"], input=x.tobytes(), check=True)
m = subprocess.run(["ffmpeg", "-hide_banner", "-i", "raw.wav", "-af", "loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"], capture_output=True, text=True).stderr
j = json.loads(m[m.rindex("{"):m.rindex("}") + 1])
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", "raw.wav", "-af", f"loudnorm=I=-14:TP=-1.5:LRA=11:measured_I={j['input_i']}:measured_TP={j['input_tp']}:measured_LRA={j['input_lra']}:measured_thresh={j['input_thresh']}:offset={j['target_offset']}:linear=true", "-ar", str(SR), "mix.wav"], check=True)
print(f"mix.wav {T:.2f} s")
