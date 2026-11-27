# ClaudeNotch for Windows: changelog

Windows releases are tagged `windows-v<version>` on the
[releases page](https://github.com/rawsun007/claude-notch/releases). The
version line is shared with the Linux edition; the Mac app has its own.

## 0.45.6: every auto-approved command shows

### Fixed

- **Commands allowed by an Always Allow rule show in the notch.** With
  Auto-Approve on, a rule such as "Always allow Bash" answered every
  command silently, so none of them showed. They now get the same
  Auto-allowed card. With Auto-Approve off, rule matches stay silent.
- **"Claude is waiting for your input" clears on your next prompt** in
  that session, like the done card, so it no longer hides the command
  cards behind it.

## 0.45.5: see what auto mode blocks

### Added

- **An Auto-denied card.** When Claude Code's auto mode blocks a command,
  the notch says so: an orange card with the command and the reason it
  was blocked, for eight seconds, with the deny sound. Before, a session
  that kept being blocked looked like a session thinking. Restart Claude
  Code sessions that were already open so they pick up the new hook.

## 0.45.4: a paw for Pet Mode

### Fixed

- **The Pet page in Settings shows a paw print.** It showed a slice of
  pizza: Windows' icon font has no paw, and the symbol it used is its
  pizza. The paw is now drawn by the app, as on the Mac.

## 0.45.3: every command shows in the notch

### Fixed

- **Auto-allowed commands show again after a finished turn.** The "Claude
  is done" card stayed up into the next turn and hid every "Auto-allowed"
  card behind it, so a whole turn of commands ran with only the old card
  on screen. Sending that session a new prompt now clears its done card.

## 0.45.2: the Mac's sounds, built in

### Changed

- **The Mac's sounds come with the app.** Funk, Glass, Pop, Tink,
  Submarine and the rest are in the installer, so every install sounds like
  the Mac from the first card, with nothing to download. The download, its
  switch in the first-run window and its button in Settings are gone.

## 0.45.1: a first-run window, the macOS sounds, no Windows toasts

### Added

- **A first-run window**: Connect Claude Code, Launch at login,
  Auto-approve everything, Destructive commands too, and Use the macOS
  sounds, each with a switch that starts on, then Start using ClaudeNotch.
  It shows once; every switch is in Settings later.
- **The real macOS sounds**: the first-run window, or Settings > Sounds >
  Download, fetches Apple's own Funk, Glass, Pop, Tink and the rest onto
  your PC, and the notch plays those instead of its own.

### Changed

- **No Windows toasts unless you turn them on.** The start-up tip, the
  update notice and error messages show as cards in the notch instead.

## 0.45.0: the first Windows release

ClaudeNotch puts the Mac app's notch at the top centre of your Windows
screen: Claude Code's permission prompts, questions and status, without
switching back to the terminal.

### Approve and answer from the notch

- **Permission cards** for every tool call, with the command or the diff:
  Allow, Deny, Always Allow (this exact command, or every call of the
  tool), and Allow All when several are waiting. Enter allows, Esc denies.
- **Destructive commands** (`Remove-Item -Recurse`, `rd /s`, `iwr | iex`,
  `git push --force` and more, for PowerShell, cmd and Bash) get a red
  card and need Windows Hello or a press-and-hold to allow.
- **Deny with a reason**: tell Claude what to do instead.
- **Questions** (AskUserQuestion), several at once, with your own answer;
  put one away and it waits in a small tab beside the notch.
- **Auto-Approve**, with a scope, a choice for destructive commands, and
  "for 15 minutes / 30 minutes / an hour".
- **"Allowed 3 times"** next to Always Allow for commands you keep approving.
- **Too late to answer here**: a card Claude Code stopped waiting for says
  so instead of vanishing.
- **Ask before switching to a pricier model** (opt in).

### See what Claude is doing

- The open notch: model, effort, branch, context and cost meter, the
  running command with its clock, the task list's progress, permission mode
  and edited files; every session when you run several.
- **Claude's last reply** in full, with headings, lists and code, and Copy.
- **History drawer** (Ctrl+Alt+H): past sessions with Resume, spend per
  project, and every card you answered, with search and filters.
- **Plan limits** at 80 % and 95 %, budgets with a hard stop, and cards when
  a session finishes, fails, changes model, or shares a folder with another.

### Talk to Claude

- **Send to Claude** (Ctrl+Alt+N): type a message into the terminal you
  were in, or start Claude in a project with it.
- **Reply** to a finished session from its card.
- **Drop a folder or file on the notch** to start Claude there.
- Start Claude in Folder, Resume Last Session and Copy Today's Standup in
  the tray.

### A Windows app

- Per-user installer: no administrator rights, no UAC prompt.
- Start menu (ClaudeNotch and ClaudeNotch Settings), tray menu, a jump list,
  `claudenotch://` links, and launch at login.
- **Ctrl+Alt+,** opens Settings from anywhere; all shortcuts can be changed.
- Settings like the Mac's: usage and cost charts, history, sounds, skills,
  budgets, rules, privacy.
- Pet Mode, the Mac's sounds, hidden from screen capture by default,
  follows you to the display you use, checks for updates, keeps local crash
  reports.

### Requirements

- Windows 10 (1809 or later) or Windows 11, x64. Windows on Arm runs it
  under emulation.
- Claude Code (the CLI, or the VS Code extension).

### Known limits

- **The installer is not code-signed yet**, so Windows SmartScreen may warn
  when you open it. Signing is coming in a later release.
- Not yet on winget.
- English only. No Codex CLI support yet. No copy of the notch on other
  displays (it moves to the one you use instead).
