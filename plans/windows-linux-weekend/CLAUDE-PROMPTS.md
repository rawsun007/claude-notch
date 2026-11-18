# Prompts for Claude Code on each machine

Paste these into `claude` started in the repo root. Claude Code reads
`CLAUDE.md` on its own; these point it at the plan and keep it on the
ticket order. One ticket per prompt works better than "do everything".

## Windows machine: first prompt (Saturday)

```
Read plans/windows-linux-weekend/README.md, DECISIONS.md, WINDOWS.md and
SUNDAY-TASKS.md. We are on the Windows machine. Decisions are locked as
recommended unless I say otherwise.

Do ticket W0: run the Linux core tests on Windows (PYTHONPATH=linux,
pytest linux/tests) and fix whatever fails in the core itself, behind
sys.platform checks, without changing Linux behaviour. Commit each fix
separately as rawsun007 with the Co-Authored-By line, no em dashes, and
push. Tell me what failed and why before fixing anything non-obvious.
```

## Windows: the risky spikes

```
Do ticket W1 from plans/windows-linux-weekend/SUNDAY-TASKS.md. Write the
throwaway script under windows/spikes/. Install our HTTP hooks into my
~/.claude/settings.json (back it up first, show me the diff), then tell me
exactly what to run in a second terminal to test allow and deny.
```

```
Do ticket W2: the pill spike, windows/spikes/spike_pill.py, with the
WS_EX_NOACTIVATE approach in WINDOWS.md section 3. Then give me a test I
can do by hand to prove it never steals focus from Windows Terminal.
```

## Windows: Sunday, one ticket at a time

```
Next ticket: W<n> from plans/windows-linux-weekend/SUNDAY-TASKS.md.
Follow WINDOWS.md for how. Reuse the shared core in linux/claudenotch;
mirror the wording and behaviour of the Linux UI (linux/claudenotch/ui.py,
settings_window.py) unless WINDOWS.md says otherwise. Run the tests, run
the app, show me it working, then commit and push.
```

## Ubuntu machine: Saturday

```
Read plans/windows-linux-weekend/README.md and LINUX.md. We are on a real
Ubuntu machine. Help me run the test pass in LINUX.md: go section by
section, tell me what to do, and when something fails, collect the log
(~/.cache/claudenotch/claudenotch.log), the session type and versions,
and open a GitHub issue with gh, label linux. Do not fix anything yet.
```

## Ubuntu: Sunday

```
Fix GitHub issue #<n> (label linux). Reproduce it first, fix it in
linux/claudenotch, add a test in linux/tests if the bug is testable without
a display, run the Docker tests in linux/test-env if the fix touches
packaging. One commit, push, then close the issue with the commit hash.
```

## Mac: website

```
In ../claude mac app website: the Windows changelog page is "Coming soon".
Prepare it for the Windows launch per plans/windows-linux-weekend/LAUNCH.md
but do not publish to docs/ until I say the release is live.
```
