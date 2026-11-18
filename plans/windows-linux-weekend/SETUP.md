# Setting up the borrowed machines (and leaving them clean)

These are friends' computers. Everything we sign in to, we sign out of on
Sunday night. Checklist at the bottom.

## Windows machine

Windows 10 22H2 or Windows 11. In PowerShell (not as admin unless noted):

```powershell
winget install --id Git.Git -e
winget install --id Python.Python.3.12 -e
winget install --id GitHub.cli -e
winget install --id JRSoftware.InnoSetup -e
winget install --id Microsoft.WindowsTerminal -e   # if not already there
```

Close and reopen the terminal so PATH updates, then:

```powershell
# Claude Code, native installer (from the official docs)
irm https://claude.ai/install.ps1 | iex
claude --version

gh auth login                 # sign in as rawsun007, HTTPS, browser
git clone https://github.com/rawsun007/claude-notch.git
cd claude-notch

# Commit as rawsun007 in THIS repo only, never globally on someone else's machine
git config user.name "rawsun007"
git config user.email "154859727+rawsun007@users.noreply.github.com"

py -3.12 -m venv .venv-win
.venv-win\Scripts\Activate.ps1   # if blocked: Set-ExecutionPolicy -Scope Process Bypass
pip install pyside6 pyinstaller pytest
```

Then start `claude` in the repo and sign in to our own Claude account. It
reads `CLAUDE.md` and this plan folder.

Optional, for testing scaling: Settings > System > Display > Scale (125 %,
150 %). For the Windows 10 check, a free Microsoft evaluation VM works if
the machine is Windows 11.

## Ubuntu machine

```sh
sudo apt update
sudo apt install -y git gh python3-gi gir1.2-gtk-3.0 libnotify-bin xdotool
curl -fsSL https://claude.ai/install.sh | bash
gh auth login
git clone https://github.com/rawsun007/claude-notch.git
cd claude-notch
git config user.name "rawsun007"
git config user.email "154859727+rawsun007@users.noreply.github.com"
```

Install the released `.deb` for the test pass (see LINUX.md), not the
checkout. For Sunday's fixes, run from the checkout with
`./linux/bin/claudenotch` (it finds the source tree beside it); launching it
takes over from the installed copy.

## Mac (us)

Website repo (`../claude mac app website`) for the Windows changelog page and
the homepage, release notes, and reviewing what the other two push.

## Sunday night: leave the machines clean

On each borrowed machine:

- [ ] `claude` then `/logout`.
- [ ] `gh auth logout`.
- [ ] Windows: Credential Manager > Windows Credentials, remove anything
      `git:https://github.com`. Ubuntu: `git credential reject` or remove
      `~/.git-credentials` if it was created.
- [ ] Uninstall ClaudeNotch test builds (this also takes our hooks out of
      their `~/.claude/settings.json`; check the file afterwards).
- [ ] Remove the clone and the venv.
- [ ] If our hooks were added to their own Claude Code settings and they
      do not want ClaudeNotch, confirm the file has no `53127` left in it.
