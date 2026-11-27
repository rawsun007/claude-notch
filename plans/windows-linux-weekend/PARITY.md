# Mac to Windows parity

Every feature of the macOS app (`Sources/ClaudeNotch/`, as of `main` at
a1ede08), and where the Windows edition stands on it. The Mac source is the
specification: numbers, wording and behaviour are ported, not redesigned.

Status: **done** (matches the Mac, checked on a real Windows PC),
**partial** (works, not yet identical; the gap is named), **todo**,
**n/a** (cannot exist on Windows, with why).

Order within each section is roughly by how often a user meets it.

## The notch itself

| Mac feature | Source | Windows | Notes |
|---|---|---|---|
| Notch outline: concave top ears, round bottom corners | NotchShape | done | Same path and control points (`notchgeom.notch_path`), radii 9/10 closed, 12/18 open, 22 for drawers. |
| Closed notch, no content | NotchView (collapsed idle) | done | 200 x 28, the Mac's no-hardware-notch size. Top centre of the primary work area. |
| Grow-out-of-notch motion | CardSizeAnimator | done | Ease-out-back 0.42 s open, cubic 0.34 s close, mid-flight retarget, content revealed by the growing clip. |
| Card height = measured content, formula as floor | NotchView.size(for:) | done | Permission card budget ported row by row. |
| 0.5 pt white 5 % outline on open cards | NotchView | done | |
| No window shadow | NotchWindowController (`hasShadow = false`) | done | |
| Hover opens the card (trigger zone 340 x 44, keep region +140 x +90, 0.2 s poll) | MouseTracker | done | |
| Click-through outside the black shape | PassThroughHostingView | done | Layered window, per-pixel alpha; verified with WindowFromPoint. |
| Never steals keyboard focus | NotchPanel (non-activating) | done | WS_EX_NOACTIVATE; foreground unchanged until the user clicks. |
| Enter / Esc answer the card without focus | KeyboardMonitor (CGEventTap) | partial | Windows needs one click on the card first; a global hook that reads Enter while the terminal has focus would also eat the terminal's Enter. |
| Hide from screen capture setting | NotchWindowController (`sharingType`) | done | `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`, on by default, Settings > Privacy. |
| Multi-monitor: notch follows the cursor's screen, mirrors | NotchWindowController, MouseTracker | partial | The notch moves to the display whose top centre the pointer reaches (never while a card is up), back to the main display if its screen goes. The Mac's mirror copies on the other displays are todo. |
| Minimized question stub left of the notch | MinimizedQuestionTab | done | The shrink button on the question card puts it away (still waiting); the notch grows a stub on its left with a purple bubble and the count; a click brings them all back. Enter / Esc and the card skip minimized questions. |
| Drop a folder on the notch to open Claude there | NotchDrop | done | A folder starts Claude there, a file in its folder with "@file" first (PowerShell single-quoted, curly quotes doubled too); a drop delivered twice opens one terminal. |
| Pet mode (stage, rope, costumes, moods) | NotchPetViews, PetEngine, PetRig | done | PetEngine ported (moods, weights, durations, duty cycle, entry spring, poses for peek, look around, hang either corner, stroll, sleep, celebrate, boop, backflip, watch, flinch, fret, rope); the rope with its physics (fall, catch, damped swing, springy stretch) and the line that sags while slack; PetRig's limbs (arms about the shoulders, legs stepping, lifting and tucking, blinks, eyes on the pointer); PetCardBadge on the danger banner, the done card (the dance) and the plan-limit card (fret, teardrop); boop on click; Settings > Pet with a Play button per activity. Not ported, on purpose: the guest costumes, which recreate third-party characters. |

## Cards

| Mac feature | Source | Windows | Notes |
|---|---|---|---|
| Permission card layout and wording | NotchPermissionCard | done | Header (accent icon, CLAUDE CODE, tool, waiting time, project), title from humanTitle, command box, buttons 18 below. |
| Destructive banner | DangerBanner | done | Red 14 % fill, 35 % stroke, bullets from the shared danger rules. |
| Hold to Allow for destructive commands | HoldToConfirmButton | done | 0.9 s; Return never allows a destructive call. |
| Confirm with Touch ID instead of holding | BiometricAuth, DestructiveGate | done | Windows Hello through WinRT `UserConsentVerifier` (ctypes, prompt parented to the notch), Require Windows Hello on by default; Hold to Allow where Hello is not set up (this PC). The live Hello prompt is not yet seen on a PC with Hello. |
| Diff preview (red/green, cut at 10 a side, multi-edit header) | DiffPreviewView, ToolPreviewParser | done | |
| Write / plan / todo preview (12 lines, "…and N more lines") | WritePreviewView | done | |
| Always Allow menu (exact command / whole tool) | PermissionCard | done | Core gained the whole-tool scope. |
| Allow All (n) for a queue | PermissionCard | done | Never sweeps up a destructive card. |
| Deny with a reason | onDenyReason, compose card | done | The bubble beside Deny opens the compose card in red; the note goes back to Claude as the deny reason (folded to one line). |
| "allowed N times" nudge | priorApprovals | done | From the third hand approval of the same exact command, never for a dangerous one or one a rule covers; making the rule spends the tally. Kept in approvals.json as hashes, capped at 64. |
| Sandbox badge | SandboxReader | n/a | Claude Code's sandbox (bubblewrap / Seatbelt) is macOS and Linux only; on native Windows it would be a false promise. |
| Too late to answer here (expired card) | PermissionCard.expiredBanner | done | The card stays with the Mac's orange banner and only Dismiss (questions too); pressing anything only dismisses it, Allow All passes over it, a live card always shows first. Opt-in in the core (keep_expired), so Linux is unchanged. |
| Budget block banner, Allow once, Raise to $X | BudgetBanner, AppState+Budget | done | Orange banner, Allow once, Raise to the Mac's next cap, Turn off. "Turn off" is a small button where the Mac draws plain text. |
| Question card (AskUserQuestion), multi-question, Other text | QuestionCard | partial | Header, header pills, option rows (nothing picked at start), "Something else" field, Cancel / Send, the Mac's height budget and answer rules. Not yet: minimize and the stub beside the notch, the expired banner, the MCP sign-in link row. The Mac makes this card key at once; Windows waits for a click, so typing in the terminal is never caught. |
| Plan approval (ExitPlanMode) | PermissionCard + WritePreview | done | Rendered as the plan preview card. |
| Notification card (bell, Dismiss, Open IDE) | NotificationCard | done | Waits until Dismiss or Open IDE. Open IDE brings back the window that was in front when it arrived. StopFailure is this card with the Mac's "⚠️ Rate limited, session stopped" wording. With Pet Mode on, a plan-limit warning has the fretting pet. The Update button is todo. |
| Completed card (done, reply, Open IDE, audit) | CompletedCard | partial | Green seal, "Claude finished", project, Open IDE and Done; waits until answered. With Pet Mode on, the pet dances on it. Reply (needs compose) and the audit banner are todo. |
| Auto-approved and auto-denied card | AutoInfoCard, AppState.noteAutoDenied | done | Button-less, click to dismiss. Approved: green, four seconds. Denied (PermissionDenied hook): orange bolt with an x, AUTO-DENIED, the reason on up to two lines, eight seconds, the deny sound; logged in history as auto-denied. The card grows for the reason instead of cutting it. |
| Thinking pill | ThinkingPill | n/a | On the Mac only the Demos menu and a Settings button ever show it (pingThinking); no hook raises it, so there is nothing user-facing to port. The running command strip covers "what is it doing". |
| Compose / reply card | NotchComposeCards | done | Ctrl+Alt+N, the tray, the jump list or claudenotch://compose; Reply on a done card. Typed into the terminal you were in (or the session's) with SendInput, only into a terminal program, only when it is really in front and no modifier is held, as one line; or a fresh terminal in a chosen project with the message as the first prompt. Checked live: a typed message ran in a PowerShell window. Background agents (claude --bg) are todo. |
| Response detail (full reply, markdown) | ResponseDetailCard, NotchMarkdown | done | The expand button on the open notch, or a session row, shows that session's last reply: from the Stop payload's last_assistant_message, else the transcript (read only inside ~/.claude or ~/.codex after resolving symlinks and "..", last 512 KB, redacted, 8000 characters). Headings, paragraphs, bullets, numbered steps and code blocks; inline markup is taken off rather than rendered, since transcript text is only ever plain text. Copy / Ctrl+C, Close / Esc. Checked against this PC's real transcripts. |
| History drawer (search, filters) | NotchHistoryCard | done | Sessions (Resume under the pointer), Projects (7-day spend sparkline, money from the transcripts), Activity (the Mac's outcome colours and labels); search, All / Allowed / Denied / Risky / Q&A, Export, Clear, plan limits, Close. Opens from the clock on the open notch, Ctrl+Alt+H (the Mac's Option-Command-Space; the Claude desktop app holds Ctrl+Alt+Space), the tray, the jump list and claudenotch://history; takes the keyboard for its search. |

## The open (hover) card

| Mac feature | Source | Windows | Notes |
|---|---|---|---|
| Mascot, name, status dot (pulse) and word (shimmer) | IdlePill | done | |
| Agent and file badges | IdlePill | done | Agents, and the files Claude edited this session (Edit, MultiEdit, Write, NotebookEdit). |
| Model, effort, branch, /add-dir chip | IdlePill row 2 | partial | Model and version, effort and the branch chip (from .git/HEAD, worktrees followed) are done, from the top session only. The /add-dir chip is todo. |
| Context and cost meter | ContextCostBar | done | From the status line: capsule warming blue, orange, red, "84k/200k", Claude Code's own cost. The cost-cap tint waits on spending caps; the window guess for sessions without a status line is todo. |
| Running command strip with timer | CommandLineBlock | done | From every PreToolUse (card, rule or Auto-Approve): icon, command cut in the middle, shimmering hairline, clock that turns orange past a minute. |
| Task-list progress bar | AppState+TaskMeter | done | TodoWrite's checklist, else TaskUpdate ids; shown for more than one task, green with a check when done. |
| Session list (2+ sessions) | NotchSessionList | partial | Rows for every session after the top one: dot, CODEX/GROK chip, folder, branch and worktree chips, hourglass while a card waits, agents, status, own meter; title names the agent or says ClaudeNotch for a mix. Not yet: clicking a row (opens the reply card), task meter, fork, sandbox, cache, permission-mode and PR chips, background-agent Attach/Reply, the live reply line, stale sessions dropping off. |
| Status bar | NotchStatusBar | done | In the history drawer, as on the Mac: 5H and WK with bar, percentage, reset countdown and the reading's age once it is over five minutes old; "—" once a window has reset. Redraws every 30 s. Credits are todo (no plan reader yet). |
| Permission-mode and sandbox badges | IdlePill | partial | BYPASS / PLAN / AUTO / DON'T ASK from the permission_mode every hook reports. No sandbox badge: Claude Code's sandboxing does not run on native Windows, so a SANDBOXED badge would promise a protection that is not there. |

## Behind the cards

| Mac feature | Source | Windows | Notes |
|---|---|---|---|
| Hook protocol, loopback server, token, Origin/Host checks | EventServer, HookSocket, HookToken | done | Shared core, HTTP hooks. |
| Card order: question, permission and notification, done, then hover | AppState.recompute | done | Oldest card first in each queue. |
| Danger rules | ToolPreviewParser | done | Shared core plus PowerShell/cmd rules. Two core tests fail on this PC before and after this work (see below). |
| Secret redaction | SecretRedactor | done | Shared core. |
| Hook installer merge / uninstall | HookInstaller | done | Shared core. |
| Status line (context, cost, model, prompt cache) | HookInstaller + EventServer status endpoint | done | `/statusline` in the shared core with the Mac's body; a PowerShell 5.1 forwarder (no jq or curl) checked key for key against the Python port of the Mac's jq program; your own status line kept and restored on uninstall. Prompt-cache warnings, PR badge and the limit forecasts are todo. Each redraw costs about 1 s of Windows PowerShell start-up, outside Claude Code's own work. |
| Spending caps (daily, session) and enforcement | AppState+Budget | done | Settings > Budget; today's spend from the transcripts every minute. Approaching-budget notices are todo. |
| Usage breakdown, burn rate, forecast | AppState+Usage, BurnRate, CostForecast | partial | Settings > Usage: 7-day and 4-week cost, heatmap, all-time counters, top tools, top projects, today / 5 h / week tokens and cost, cache hit rate and savings, model mix, CSV export (core usage.py with the Mac's prices). Burn rate and forecasts are todo. |
| Usage limit window and pause | AppState+UsageLimit, UsageLimitPause, AppState+LimitWindow | partial | Settings > Plan shows the 5-hour and weekly limits with reset countdowns; warnings at 80 % and 95 %. The usage-limit pause card is todo. |
| Activity history, export CSV/JSON, standup | AppState+History, AppState+Export | partial | Settings > History: one record per session (summary, turns, model, branch, cost), search, Export CSV or JSON, Clear. The notch's own history drawer and the standup are todo. |
| Always-allow rules page | AppState+Rules, SettingsPage+Rules | done | Settings > Rules. Adding a rule by hand and exporting rules to Claude Code are todo. |
| Auto-approve policy | AutoApprovePolicy, AppState+AutoModeReview | done | Scope (everything, commands incl. PowerShell, files) and destructive choice (show the card, confirm with Windows Hello, approve them too). Approve them too needs Windows Hello or the Windows password (CredUI + LogonUser). Auto-approve for a while on Settings > Session. Strict mode and the auto-mode review are todo. |
| Sessions: registry, staleness, background agents | SessionRegistry, BackgroundAgents, AppState+Sessions | partial | Sessions from hooks only. |
| Git branch, diff stat, worktrees | Git, AppState+Git, Worktree, WorktreeAdvice | done | Branch from .git/HEAD (worktrees followed), worktree chips; Settings > Session shows the latest session's lines added / removed / net (from the CLI's status line) and up to ten files touched, each with Show (selects it in File Explorer, never opens it). WorktreeAdvice: once per folder, a ClaudeNotch card when two live sessions share a folder outside a worktree. Checked live: a real Write showed up on the Session page. |
| Codex CLI | CodexReader, AgentAdapter | todo | |
| Model switch gate, model drift | AppState+ModelSwitch, ModelDrift | done | PostModelSwitch updates the session's model and shows "Model switched" (once when reported twice). With "Ask before switching to a pricier model" on (Settings > Rules, off by default), a PreModelSwitch moving UP a family waits on a card no rule or Auto-Approve may answer; everything else and a card nobody answers is a plain OK. A status line showing a lower tier than the session started on says so once, without claiming a cause. |
| Skills page | SkillsReader, SkillSettings, SkillTrash | partial | Personal, claude.ai, project and plugin skills; listing cost; On, Name only, Only when I type it, Off (skillOverrides); trash and restore. Per-project overrides (settings.local.json), plugin on/off switches, usage counts and Free up context are todo. |
| Sounds | AppState+Sound | done | The Mac's events, per-tool sounds (PowerShell counts as shell), per-event overrides and None, mute; the 13 sounds ship in the app (from extratone/macOSsystemsounds, The Unlicense, with its owner's permission; see windows/resources/sounds/SOURCE.md); a user's own .aiff or .wav in %APPDATA%\ClaudeNotch\Sounds wins. Settings > Sounds. |
| Notifications mirrored to the OS | NotificationBridge | done | Windows toasts. |
| URL scheme `claudenotch://` | URLScheme | partial | open, settings, settings/<page>, history, standup; registered per user by the installer. compose and resume are todo. |
| Global hotkey for Settings | GlobalHotkey | done | Ctrl+Alt+, opens Settings, Ctrl+Alt+N the compose card and Ctrl+Alt+H history from any app (the Mac's Option-Command-Comma, Option-Command-N and Option-Command-Space), `RegisterHotKey`; both changeable in Settings > General, which says when another program holds one. Plus the Windows places a Mac app lives: tray menu with the shortcuts shown, Start entries (ClaudeNotch, ClaudeNotch Settings), a taskbar/Start jump list (Open the Notch, Settings, Usage, History), relaunch opens Settings. |
| Start at login | (LaunchAgent) | done | HKCU Run. |
| Single instance, take over an older copy | SingleInstance | done | |
| Update check | UpdateChecker | done | GitHub releases tagged windows-v*, 20 s after start and daily; "Update available: x" in the tray opens the release page; Settings > About has Check for Updates. |
| Translations (9 languages) | Resources/*.lproj | todo | English only. |
| Onboarding | Onboarding* | partial | First-run toast and tray tip, no onboarding window. |
| Crash reports (local) | CrashReporter | done | Uncaught errors in any thread to Crashes\crash-*.txt, hard crashes to fatal.txt (faulthandler), newest ten kept, never sent; Settings > About opens the folder. |
| AppleScript | AppleScriptSupport | n/a | No AppleScript on Windows; the URL scheme and the control endpoint cover automation. |
| Terminal automation (resume in Terminal/iTerm) | TerminalAutomator | partial | Start Claude in Folder, Resume Last Session (claude --resume <id>) in Windows Terminal or PowerShell; the folder is only the working directory and ids must be plain. Copy Today's Standup in the tray. Keystroke injection into a running terminal is todo. |
| Claude Desktop integration | ClaudeDesktop | todo | |

## Known gaps carried from before this work

- `linux/tests/test_danger.py::DispatchTests::test_tools` and
  `linux/tests/test_danger_windows.py::NestedTests::test_bash_on_windows_also_gets_windows_rules`
  fail on this Windows PC, with and without the UI changes (the danger
  code is untouched). Danger rules must stay identical to the Mac, so the
  fix belongs in its own change against the Mac's ToolPreviewParser.

## Checked with a real Claude Code session (22 Nov 2026)

Claude Code 2.1.330 (npm, per user), ClaudeNotch from the checkout,
hooks from `%USERPROFILE%\.claude\settings.json`, `claude -p` with
`--debug` so the hook traffic is in the log.

| Shell | What Claude did | Card | Answer | Result |
|---|---|---|---|---|
| Git Bash | Read, then Edit `hello.js` | Read card, then Edit card with diff | Allow (clicked on the card) | Hook returned `allow` after 9.5 s and 5 s; file edited |
| PowerShell | Edit `hello.js` | Edit card with diff | Allow | File edited |
| PowerShell | PowerShell tool: `Remove-Item -Recurse -Force old-cache` | Red destructive card, "Remove-Item -Recurse -Force, deletes a directory tree", Hold to Allow | 1.3 s press and hold | Hook returned `allow`; folder deleted |

| (real server, Claude Code's AskUserQuestion payload) | One question, three described options | Question card | Real clicks: Blue, then Send | Hook answered in 2.3 s with "[ClaudeNotch, user replied via the notch] - Colour: Blue", the Mac's exact text |

The terminal kept keyboard focus until the card was pressed, every time.

Status line, live: an interactive `claude` (2.1.330) with ClaudeNotch
running. The hover card showed "Claude · 2 sessions", Haiku 5.5, Medium
effort and the `windows` branch, all from the status line and .git/HEAD,
and the terminal's own status line still drew the default
"Haiku 5.5  E:\claude notch\claude-notch".

`claude -p` does not use AskUserQuestion (with nobody to ask, it asks in
plain text), so the question card was driven with the payload Claude Code
sends from an interactive session. The notification, done and question
cards were also checked on screen at 150 %.

Seen along the way, not changed (both editions do it, the wire must stay
identical): Grep, Glob, LS, BashOutput and KillShell are answered `ask`
at once, as `EventServer.handleUnifiedHook` does on the Mac. In an
interactive session that is "ask in the terminal"; in `claude -p`, where
nobody can be asked, Claude Code reads it as a denial.

Also seen: a Claude Code session on the same PC, including the one used
to build this, routes its own permission prompts to the notch while the
app runs. That is by design (the hooks are user-wide), but worth knowing
when testing on a machine you are also working on.


## Settings window (22 Nov 2026)

Rebuilt on the Mac's SettingsWindow: grouped sidebar with search, pages of
rounded cards, light or dark following Windows. Pages now: General (launch
at login, hello, Auto-Approve with its setup sheet, setup health for hooks
and status line), Notch, Session (Auto-approve for a while, snooze),
Alerts (cards, plan-limit warnings, Windows notifications), Budget, Plan,
Usage, History, Privacy (hide from capture, Windows Hello, skip
confirmation behind owner authentication), About, Rules, Developer (demo
cards), Pet, Sounds and Skills.

## VS Code (22 Nov 2026)

The Claude Code extension for VS Code (2.1.330) runs its own
`resources/native-binary/claude.exe`, which reads the same
`%USERPROFILE%\.claude\settings.json` hooks. Run directly with `--debug`,
its Read and Edit were held on the notch card (9 s and 5.5 s) and went
through on Allow ("Hook approved tool use… bypassing permission prompt").
Driving the extension's chat panel by hand was not finished: VS Code
opened the folder in Restricted Mode (extensions off until the folder is
trusted, which is the user's call) and asked for consent before the
extension could open a link; the PC was then in use.
