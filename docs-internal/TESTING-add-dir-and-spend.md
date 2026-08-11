# How to test the two new features

Both are already installed on your machine (`./build.sh && ./install.sh` ran, and
the app was relaunched). Nothing below needs a rebuild.

---

## Feature 1: credit spend cap and severity in Settings

**What changed.** Claude Code writes your paid-usage spend into `~/.claude.json`.
The cap is not a plain money object, it is a container: `cap: {money: null,
credits: {amount_minor: 8000}}`. The old code only looked at `cap.money`, so it
always read nil and the bar had no ceiling to draw against. It now reads the
credits cap, and it shows the severity Claude Code itself assigns instead of
guessing one from the percentage.

**Steps.**

1. Open ClaudeNotch Settings (menu bar icon, or your settings hotkey).
2. Go to the **Plan** section, and find the **Credit budget** bar.
3. Check the numbers against your real config. Right now yours reads:

   | Field | Your current value |
   |---|---|
   | Spent | $26.04 |
   | Cap | $80.00 |
   | Percent | 33% |
   | Severity | normal |

**Pass:** the bar shows roughly a third full, says $26.04 of $80.00, and is not
flagged as a warning.

**Fail:** the cap shows as blank, `$0`, or "no limit". If so, run this and send
me the output:

```
python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/.claude.json')));print(json.dumps(d['cachedUsageUtilization']['utilization']['spend'],indent=2))"
```

**To see the severity change colour**, you would need to actually cross ~80% of
your cap, so do not chase this one. The value is read straight from the field, and
there is a unit test covering each severity string.

---

## Feature 2: `/add-dir` directories recorded in the notch

**What changed.** A session's cwd is what you agreed it may touch. `/add-dir`
widens that afterwards, and the notch previously kept showing only the cwd, so
the row understated the session's reach for the rest of its life. It now listens
to Claude Code's `DirectoryAdded` hook.

**Before you start:** the hook is registered when the app launches. You already
relaunched it, so it is in place. Confirm if you want:

```
grep -c DirectoryAdded ~/.claude/settings.json
```

Expect `1` or more. If it is `0`, quit ClaudeNotch fully and reopen it.

**Steps.**

1. Start a Claude Code session in any project (or use one you already have open).
2. In that session run, for example:

   ```
   /add-dir /tmp
   ```

3. Look at the notch. If that session is in the session list, its row now carries
   a small folder-with-a-plus chip showing how many directories were added. Hover
   it to see the paths.
4. Open Settings and go to **History**. There should be a row reading
   **Directory added to the session** with the path as its detail.

**Pass:** the history row appears with the correct path.

**Fail (no row at all):** turn on the debug log in Settings, run `/add-dir /tmp`
again, and send me:

```
grep DirectoryAdded ~/Library/Application\ Support/ClaudeNotch/debug.log | tail -3
```

It logs the payload's keys when it cannot find a path.

**Note on the chip:** it only appears on rows in the multi-session list, so if
this is your only running session the row is the header instead and you will not
see a chip. The History entry appears either way, so that is the reliable check.

---

## What is already verified

- Both features build, and the full test suite runs on CI.
- Task 2 was exercised against the running app, using the example payload from
  the hooks reference copied verbatim. The field is `directory_path`, and
  `how_added` distinguishes `/add-dir` from the SDK's `register_repo_root`; both
  are read. A few test rows are sitting in your history pointing at
  `/tmp/added-via-*` and `/home/user/another-project`; harmless, they scroll off.
- Task 1's parsing is covered by four new unit tests, including the exact
  container-shaped `cap` that your real config has.
