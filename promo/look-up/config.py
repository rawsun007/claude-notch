"""config.py: writes config.json for film.html.

Music: Mixkit "Digital Clouds" (#175), 129 bpm, measured. It drops away at
27.5 s and lifts on the bar at 28.0 s; starting it at 18.8 s (a bar line)
puts the lift at 9.2 s in the film, where the green-screen laptop comes in.
Every shot after that is two bars."""
import json
cfg = {"width": 1920, "height": 1080, "shoot_fps": 120, "sub": 4,
       "bpm": 129.0, "song_start": 18.8, "lift": 9.2, "duration": 36.4}
json.dump(cfg, open("config.json", "w"), indent=1)
print("config.json")
