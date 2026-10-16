"""config.py: writes config.json for film.html.

Music: Mixkit "Cat Walk" (#371), 130 bpm, measured from its kick drum. It
builds from 15 s and drops at 29.615 s; starting it at 22.231 s puts the drop
exactly on beat 16 of the film. Every scene after it is two bars, and every
cut lands on a beat."""
import json
BPM, DROP, DROP_BEAT = 130.0, 29.615, 16
cfg = {"width": 1920, "height": 1080, "shoot_fps": 120, "sub": 4, "bpm": BPM,
       "song_start": round(DROP - DROP_BEAT * 60 / BPM, 3), "drop_beat": DROP_BEAT, "beats": 80, "tail": 1.2}
json.dump(cfg, open("config.json", "w"), indent=1)
print("config.json")
