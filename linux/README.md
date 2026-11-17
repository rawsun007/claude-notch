# ClaudeNotch for Linux

Claude Code's permission prompts and questions, answered from a card at the
top of your screen instead of the terminal. The same hooks, the same danger
warnings and the same secret redaction as the macOS app.

Linux laptops have no notch, so the app draws a small black pill hanging from
the top centre of your main display. It grows into a card when Claude needs
you and into your session list when you point at it.

## Install

Download from the [latest release](https://github.com/rawsun007/claude-notch/releases/latest).

**Ubuntu, Debian, Mint, Pop!_OS** (`.deb`):

```sh
sudo apt install ./claudenotch_0.43.0_all.deb
claudenotch &
```

**Fedora, Arch, openSUSE and the rest** (tarball, no root needed):

```sh
tar xzf claudenotch-0.43.0-linux.tar.gz
./claudenotch-0.43.0-linux/install.sh
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

## Uninstall

```sh
claudenotch --uninstall-hooks        # take the hooks out of Claude Code first
sudo apt remove claudenotch          # .deb
./claudenotch-0.43.0-linux/install.sh --uninstall   # tarball (does both steps)
```

Always-allow rules live in `~/.config/claudenotch/`; delete it to forget them.

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
