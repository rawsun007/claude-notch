# Ubuntu: real-hardware test pass and backlog

The Linux edition (0.44.0) has only been tested in Docker (Xvfb, a headless
GNOME session) and on a friend's install that found the purge bug. This
weekend is its first proper run on a real Ubuntu laptop. Saturday is
testing; Sunday fixes whatever Saturday found, in between Windows builds.

## Saturday: the test pass

Install the released `.deb` from the Linux changelog page first (that is what
users get), not a dev checkout. Write every failure into a GitHub issue with
the `linux` label as it is found: what was done, what happened, a
screenshot, and `~/.cache/claudenotch/claudenotch.log`.

Record the machine first: Ubuntu version (`lsb_release -a`), GNOME version,
`echo $XDG_SESSION_TYPE` (wayland or x11), screen scale, monitor count.

### Install and first run
- [ ] `sudo apt install ./claudenotch_0.44.0_all.deb` on a clean machine:
      any missing dependency?
- [ ] App starts from the app grid and from the terminal.
- [ ] Hooks land in `~/.claude/settings.json`; an existing hook of the user's
      is kept; a backup exists.
- [ ] Greeting appears once.

### Cards (in a real `claude` session)
- [ ] Permission card: Allow, Deny, Always allow; Enter and Esc work.
- [ ] Typing in the terminal while a card pops up: focus not stolen, no
      characters lost. (Most likely real-hardware failure on GNOME Wayland.)
- [ ] Dangerous command (`rm -rf ./x`, `sudo ls`): reasons shown, two clicks,
      no Always allow.
- [ ] AskUserQuestion with multiple choice and multi-select.
- [ ] ExitPlanMode (plan mode, then approve).
- [ ] Two sessions at once: queue shows "+1", right session named.
- [ ] Leave a card for 285 s: it goes back to the terminal.

### Desktop
- [ ] GNOME Wayland (Ubuntu default): pill placement, above other windows,
      over a fullscreen terminal?
- [ ] Log out, choose "Ubuntu on Xorg", repeat the card checks.
- [ ] Fractional scaling (125 %, 150 %) and 200 %: text sharp, pill sized right.
- [ ] Two monitors, external as primary, unplug while running.
- [ ] Dark and light style.
- [ ] Notifications on: banner does not sit on top of the card (known GNOME
      behaviour, check it is still acceptable).
- [ ] Suspend and resume: app still answers hooks.

### Lifecycle
- [ ] Settings window: every toggle sticks across a restart.
- [ ] Start at login: reboot, app is up.
- [ ] Upgrade: build a 0.44.1 `.deb` locally, install over the running app,
      it restarts on the new version.
- [ ] `sudo apt remove claudenotch`: app stops, hooks removed.
- [ ] `sudo apt purge claudenotch && sudo apt autoremove`: nothing left (the
      bug that was fixed in 0.44.0, confirm on real hardware).
- [ ] Tarball install on the same machine as a second check (after removing
      the .deb).

### If there is time
- [ ] Fedora or another distro in a VM: tarball install.
- [ ] KDE Plasma (Kubuntu live USB): layer-shell path.

## Backlog (parity with the Mac, after the test fixes)

Ordered by value to users. Only the first two are candidates for Sunday;
the rest are after launch.

1. **Fixes from the test pass.** Always first.
2. **Shared-core changes made for Windows** (paths, danger rules for the
   `PowerShell` tool, `os.replace` retry): they land in `linux/claudenotch`, so
   Linux CI and a quick run on the Ubuntu machine must confirm nothing broke.
   Ship as `linux-v0.45.0` alongside Windows.
3. **Auto-approve** (Mac 0.44.0): scope everything / commands / files, and
   what to do with dangerous calls. On Linux there is no Touch ID; "confirm
   with password" via polkit (`pkcheck`) or fprintd is a later question, so v1
   offers "show the card" and "allow too".
4. **Session registry** (`~/.claude/sessions/<pid>.json`): see sessions that
   never fired a hook, and know when one exits. The Mac's `SessionRegistry`
   is the reference; `/proc/<pid>/stat` gives the start time for the same
   pid-reuse check.
5. **Status line** (cost and context meter) through a `statusLine` command
   pointing at `claudenotch --statusline`.
6. **Snap or a PPA** so `apt upgrade` updates it. A PPA needs a Launchpad
   account and signed source packages; an apt repo on GitHub Pages is simpler.
   Decide after launch.
7. **Codex CLI** support (Mac has it).
