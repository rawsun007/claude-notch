# ClaudeNotch for Linux

Claude Code's permission prompts and questions, answered from a card at the
top of your screen instead of the terminal. The same hooks, the same danger
warnings and the same secret redaction as the macOS app.

Linux laptops have no notch, so the app draws a small black pill hanging from
the top centre of your main display. It grows into a card when Claude needs
you and into your session list when you point at it.

## Install

Download from the [Linux changelog](https://rawsun007.github.io/claude-notch/changelog/linux/) (every Linux release, with its .deb and tarball) or the [releases page](https://github.com/rawsun007/claude-notch/releases); Linux-only releases are tagged `linux-v...`.

**Ubuntu, Debian, Mint, Pop!_OS** (`.deb`):

```sh
sudo apt install ./claudenotch_0.44.0_all.deb
claudenotch &
```

**Fedora, Arch, openSUSE and the rest** (tarball, no root needed):

```sh
tar xzf claudenotch-0.44.0-linux.tar.gz
./claudenotch-0.44.0-linux/install.sh
```

`install.sh` tells you what to install first if PyGObject or GTK 3 is missing.

Either way the app starts at every login and wires itself into
`~/.claude/settings.json` on first run (your own hooks are kept, and a backup
is written first). Start a new `claude` session and its prompts come to the
card.

## Use

| On the card | |
|---|---|
| **Allow** / Enter | let the tool call run |
| **Deny** / Esc | refuse it; Claude is told you said no |
| **Always allow** | allow this exact command or file from now on |
| **Answer in terminal** | hand a question back to Claude Code's own prompt |

A dangerous call (`rm -rf`, `sudo`, `git push --force`, writes to `~/.ssh`,
autostart or systemd user units, ...) shows why it is dangerous, needs two
clicks, and never offers Always allow. A card nobody answers within 285
seconds goes back to the terminal, exactly as if the app were not running.

`claudenotch --status` shows whether the hooks are installed and the app is up.

## Desktops

- **X11** (any desktop): full support.
- **GNOME on Wayland**: runs through XWayland, which every GNOME install has.
- **KDE Plasma, Sway, Hyprland on Wayland**: uses layer-shell when
  `gir1.2-gtklayershell-0.1` is installed, otherwise XWayland.

## Settings

Right-click the notch and choose **Settings…**, right-click ClaudeNotch in the
dock or app grid, launch it again while it runs, or run `claudenotch
--settings`. From there:

- **General**: start at login, the start-up greeting, the session list on
  hover, session updates in the notch.
- **Notifications**: desktop notifications for cards. Off by default, since
  the card is already on screen and GNOME puts its banner right over it; turn
  them on for every card or for dangerous calls only.
- **Claude Code**: whether the hooks are installed; install or remove them.
- **Always allow**: every rule you added, each with Remove.
- **About**: version, log, Quit.

## Updating

Install the new version over the old one, no uninstall needed:
`sudo apt install ./claudenotch_<new>_all.deb`, or run the new tarball's
`install.sh`. The running copy is replaced by the new version within a few
seconds (after any card you are answering) and says it was updated.

## If you don't see it

- Look just below the top bar, in the middle. On Ubuntu the pill hangs from
  GNOME's black bar like a notch, and says "ClaudeNotch is running" for a few
  seconds after it starts.
- Launching it again while it runs opens its Settings, instead of starting a
  second copy.
- `claudenotch --status` says whether it is running and whether the hooks
  are installed, and where its log is (`~/.cache/claudenotch/claudenotch.log`).
- Claude Code reads its hooks when a session starts: a `claude` session that
  was already open before you installed will not reach the card until you
  start a new one.

## Uninstall

```sh
sudo apt purge claudenotch                          # .deb: stops it, removes its hooks and data
./claudenotch-0.44.0-linux/install.sh --uninstall   # tarball
```

**Removed an older version (0.43.x) and it still shows notifications?** Those
versions kept running after `apt purge` and left their hooks in Claude Code's
settings. Run this as yourself (not with sudo) to clean up:

```sh
curl -fsSLO https://raw.githubusercontent.com/rawsun007/claude-notch/main/linux/packaging/remove-leftovers.sh
less remove-leftovers.sh     # read it first
bash remove-leftovers.sh
```

It stops the running copy, removes only ClaudeNotch's hooks from
`~/.claude/settings.json` (your own hooks stay, a backup is written) and
deletes its folders. Then restart any open `claude` sessions.

## Develop

```
claudenotch/     the app: protocol, server, state, danger, redact, hooks, ui, app
tests/           unit and integration tests (python3 -m unittest discover -s tests)
test-env/        a Linux desktop in Docker for testing from any OS
packaging/       .deb and tarball builders, install.sh, desktop entry, icon
```

`test-env/run.sh` runs every test plus a desktop end-to-end test in Docker:
Xvfb and a real window manager, hook payloads sent with curl the way Claude
Code sends them, the card clicked with xdotool, and screenshots of each step
in `test-env/out/`. `test-env/install-test.sh` and `test-env/tarball-test.sh`
install the built packages on clean Ubuntu, Debian and Fedora images and run
the same test against the installed app. CI (`.github/workflows/linux.yml`)
runs all of it and attaches the packages to every release.
