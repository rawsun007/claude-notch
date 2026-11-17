#!/usr/bin/env bash
# Remove everything ClaudeNotch left behind for the current user, even when
# the app itself is already uninstalled: stop any copy still running, take its
# hooks out of Claude Code's settings (your own hooks are kept, and a backup
# is written first), and delete its folders. Run as yourself, not with sudo.
set -u
if [ "$(id -u)" = "0" ]; then echo "Run this as yourself, without sudo: it cleans your own settings." >&2; exit 1; fi

pkill -u "$(id -u)" -f 'python3[.0-9]* .*claudenotch( |$)' 2>/dev/null && echo "Stopped the running ClaudeNotch." || true

python3 - <<'PY'
import json, os, shutil, time
path = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "settings.json")
try:
    with open(path, encoding="utf-8") as f:
        settings = json.load(f)
except FileNotFoundError:
    print("No Claude Code settings file, nothing to clean there."); raise SystemExit
except ValueError:
    print(f"{path} is not valid JSON; left it alone. Remove the entries mentioning 53127 by hand."); raise SystemExit

def ours(h):
    return isinstance(h, dict) and ("53127" in str(h.get("url") or "") or "claudenotch" in str(h.get("command") or ""))

hooks = settings.get("hooks") if isinstance(settings.get("hooks"), dict) else {}
removed = 0
for event in list(hooks):
    rules = hooks[event] if isinstance(hooks[event], list) else []
    kept = [r for r in rules if not (isinstance(r, dict) and any(ours(h) for h in r.get("hooks") or []))]
    removed += len(rules) - len(kept)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
if not removed:
    print("No ClaudeNotch hooks in", path); raise SystemExit
if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)
backup = f"{path}.before-removing-claudenotch.{int(time.time())}"
shutil.copy2(path, backup)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2); f.write("\n")
os.replace(tmp, path)
print(f"Removed {removed} ClaudeNotch hooks from {path} (backup: {backup}).")
PY

for d in ~/.claudenotch "${XDG_CONFIG_HOME:-$HOME/.config}/claudenotch" "${XDG_CACHE_HOME:-$HOME/.cache}/claudenotch" \
         ~/.local/lib/claudenotch; do
  [ -e "$d" ] && rm -rf "$d" && echo "Deleted $d"
done
for f in ~/.local/bin/claudenotch "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/claudenotch.desktop" \
         "${XDG_DATA_HOME:-$HOME/.local/share}/applications/claudenotch.desktop"; do
  [ -e "$f" ] || [ -L "$f" ] && rm -f "$f" && echo "Deleted $f"
done
echo "Done. Restart any open claude sessions so they stop calling ClaudeNotch."
