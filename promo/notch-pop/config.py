"""config.py: writes config.json for film.html.

The music is Mixkit's "Gimme That Groove!" (#872, free for commercial use),
112 bpm, measured: the groove starts on the bar at 2.16 s, and the track
drops out for a beat at 21.0 s and slams back on the bar at 21.45 s, which is
where the Skills reveal lands. Every scene starts on a bar."""
import json
cfg = {"width": 1920, "height": 1080, "shoot_fps": 120, "sub": 4,
       "bpm": 112.0, "downbeat": 2.16, "drop": 21.45, "duration": 33.6}
json.dump(cfg, open("config.json", "w"), indent=1)
print("config.json")
