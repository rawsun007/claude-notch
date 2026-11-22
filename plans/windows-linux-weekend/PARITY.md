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
| Hide from screen capture setting | NotchWindowController (`sharingType`) | todo | `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`, Windows 10 2004+. |
| Multi-monitor: notch follows the cursor's screen, mirrors | NotchWindowController, MouseTracker | todo | Primary screen only today. |
| Minimized question stub left of the notch | MinimizedQuestionTab | todo | |
| Drop a folder on the notch to open Claude there | NotchDrop | todo | |
| Pet mode (stage, rope, costumes, moods) | NotchPetViews, PetEngine, PetRig | partial | The 15 pt mascot with mood bob and blink is drawn from PetBody's grid; the stage and activities are todo. |

## Cards

| Mac feature | Source | Windows | Notes |
|---|---|---|---|
| Permission card layout and wording | NotchPermissionCard | done | Header (accent icon, CLAUDE CODE, tool, waiting time, project), title from humanTitle, command box, buttons 18 below. |
| Destructive banner | DangerBanner | done | Red 14 % fill, 35 % stroke, bullets from the shared danger rules. |
| Hold to Allow for destructive commands | HoldToConfirmButton | done | 0.9 s; Return never allows a destructive call. |
| Confirm with Touch ID instead of holding | BiometricAuth, DestructiveGate | todo | Windows Hello via `UserConsentVerifier`. |
| Diff preview (red/green, cut at 10 a side, multi-edit header) | DiffPreviewView, ToolPreviewParser | done | |
| Write / plan / todo preview (12 lines, "…and N more lines") | WritePreviewView | done | |
| Always Allow menu (exact command / whole tool) | PermissionCard | done | Core gained the whole-tool scope. |
| Allow All (n) for a queue | PermissionCard | done | Never sweeps up a destructive card. |
| Deny with a reason | onDenyReason, compose card | todo | Needs the compose card. |
| "allowed N times" nudge | priorApprovals | todo | |
| Sandbox badge | SandboxReader | todo | |
| Too late to answer here (expired card) | PermissionCard.expiredBanner | todo | The core drops the card at 285 s instead; the Mac keeps it with a Dismiss. |
| Budget block banner, Allow once, Raise to $X | BudgetBanner, AppState+Budget | todo | Needs spending caps. |
| Question card (AskUserQuestion), multi-question, Other text | QuestionCard | partial | Works (pick, Submit, Cancel); layout is not yet the Mac's option rows; no Other field, no minimize. |
| Plan approval (ExitPlanMode) | PermissionCard + WritePreview | done | Rendered as the plan preview card. |
| Notification card (bell, Dismiss, Open IDE) | NotificationCard | partial | Shown as a plain title and body card; Mac buttons todo. |
| Completed card (done, reply, Open IDE, audit) | CompletedCard | todo | Shown as the plain card today. |
| Auto-approved info card | AutoInfoCard | todo | Needs auto-approve. |
| Thinking pill | ThinkingPill | todo | |
| Compose / reply card | NotchComposeCards | todo | |
| Response detail (full reply, markdown) | ResponseDetailCard, NotchMarkdown | todo | |
| History drawer (search, filters) | NotchHistoryCard | todo | |

## The open (hover) card

| Mac feature | Source | Windows | Notes |
|---|---|---|---|
| Mascot, name, status dot (pulse) and word (shimmer) | IdlePill | done | |
| Agent and file badges | IdlePill | partial | Agents done; edited-file count needs PostToolUse paths. |
| Model, effort, branch, /add-dir chip | IdlePill row 2 | todo | Needs the status line feed. |
| Context and cost meter | ContextCostBar | partial | Drawn ("no usage yet"); numbers need the status line endpoint. |
| Running command strip with timer | CommandLineBlock | todo | Needs the last tool from PreToolUse. |
| Task-list progress bar | AppState+TaskMeter | todo | |
| Session list (2+ sessions) | NotchSessionList | todo | |
| Status bar | NotchStatusBar | todo | |
| Permission-mode and sandbox badges | IdlePill | todo | |

## Behind the cards

| Mac feature | Source | Windows | Notes |
|---|---|---|---|
| Hook protocol, loopback server, token, Origin/Host checks | EventServer, HookSocket, HookToken | done | Shared core, HTTP hooks. |
| Danger rules | ToolPreviewParser | done | Shared core plus PowerShell/cmd rules. Two core tests fail on this PC before and after this work (see below). |
| Secret redaction | SecretRedactor | done | Shared core. |
| Hook installer merge / uninstall | HookInstaller | done | Shared core. |
| Status line (context, cost, model, prompt cache) | HookInstaller + EventServer status endpoint | todo | Most-used missing feature after the cards. |
| Spending caps (daily, session) and enforcement | AppState+Budget | todo | |
| Usage breakdown, burn rate, forecast | AppState+Usage, BurnRate, CostForecast | todo | |
| Usage limit window and pause | AppState+UsageLimit, UsageLimitPause, AppState+LimitWindow | todo | |
| Activity history, export CSV/JSON, standup | AppState+History, AppState+Export | partial | Core keeps a history log; no UI or export yet. |
| Always-allow rules page | AppState+Rules, SettingsPage+Rules | done | Settings > Always allow. |
| Auto-approve policy | AutoApprovePolicy, AppState+AutoModeReview | todo | |
| Sessions: registry, staleness, background agents | SessionRegistry, BackgroundAgents, AppState+Sessions | partial | Sessions from hooks only. |
| Git branch, diff stat, worktrees | Git, AppState+Git, Worktree | todo | |
| Codex CLI | CodexReader, AgentAdapter | todo | |
| Model switch gate, model drift | AppState+ModelSwitch, ModelDrift | todo | |
| Skills page | SkillsReader, SkillSettings, SkillTrash | todo | |
| Sounds | AppState+Sound | todo | |
| Notifications mirrored to the OS | NotificationBridge | done | Windows toasts. |
| URL scheme `claudenotch://` | URLScheme | todo | HKCU\Software\Classes, per user. |
| Global hotkey for Settings | GlobalHotkey | todo | `RegisterHotKey`. |
| Start at login | (LaunchAgent) | done | HKCU Run. |
| Single instance, take over an older copy | SingleInstance | done | |
| Update check | UpdateChecker | todo | |
| Translations (9 languages) | Resources/*.lproj | todo | English only. |
| Onboarding | Onboarding* | partial | First-run toast and tray tip, no onboarding window. |
| Crash reports (local) | CrashReporter | todo | |
| AppleScript | AppleScriptSupport | n/a | No AppleScript on Windows; the URL scheme and the control endpoint cover automation. |
| Terminal automation (resume in Terminal/iTerm) | TerminalAutomator | todo | Windows Terminal (`wt.exe`) and PowerShell instead. |
| Claude Desktop integration | ClaudeDesktop | todo | |

## Known gaps carried from before this work

- `linux/tests/test_danger.py::DispatchTests::test_tools` and
  `linux/tests/test_danger_windows.py::NestedTests::test_bash_on_windows_also_gets_windows_rules`
  fail on this Windows PC, with and without the UI changes (the danger
  code is untouched). Danger rules must stay identical to the Mac, so the
  fix belongs in its own change against the Mac's ToolPreviewParser.
