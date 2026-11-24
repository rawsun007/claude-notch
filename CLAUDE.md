# ClaudeNotch: repo map

macOS menu-bar app (Swift 6 / SwiftUI / AppKit, SPM, macOS 13+) that surfaces
Claude Code and Codex CLI permission prompts, status, cost/context meter, and a
pet in the MacBook notch. Read this map instead of exploring the tree; verify a
detail in the file before relying on it.

## Build / release / test

- **`./build.sh`**: builds `ClaudeNotch.app` (the bundle). Plain `swift build`
  compiles `.build/` only and does NOT update the app; always run `build.sh`
  before reinstalling to `/Applications`.
- **`tools/run-dev-build.sh [--fast]`**: build, restart the app, and PROVE the
  running process is the one just built (it compares process start time against
  the binary's mtime and fails if not). Use this, never `open ClaudeNotch.app`
  by hand: `open` on an already-running app just fronts it, `osascript quit` has
  returned success without quitting, and `pgrep` answers "something is running"
  rather than "the build I just made is running". A test build once ran for four
  hours while six commits went into the bundle and none reached the screen, and
  bugs already fixed were reported and re-argued against it.
- **`swift build`**: fast compile check of the app target. It does NOT compile
  the test target, so strict-concurrency errors in test code only surface on CI.
- **CI is the test authority** (`.github/workflows/ci.yml`, Swift 6.2). Local
  `swift test` fails (Command Line Tools ship no XCTest). Verify with
  `gh run list`.
- **`tools/release.sh <ver>`**: bumps version, builds DMG, publishes the GitHub
  release, points the Homebrew tap at it, reinstalls locally. After it: add the
  release to the website changelog (separate repo,
  `../claude mac app website/app/changelog/releases.ts`), rebuild, sync `docs/`.
  The cask is NOT checksummed from the local build: the release workflow
  uploads its own DMG with `--clobber`, so **`tools/sync-cask-to-release.sh`**
  takes the checksum from the published asset (after waiting out that workflow,
  and verifying the artifact), and **`tools/check-cask-matches-release.sh`**
  confirms it from outside. A mismatch breaks `brew install` AND every user's
  Update Now, so release.sh exits nonzero on one. Both are safe to run any time.
- **Releases are signed + notarized**, and that is not optional. Every published
  build is Developer ID signed (team `PS8FJ3MQB2`, hardened runtime), notarized
  and stapled; `release.sh` refuses to run without
  `CLAUDENOTCH_NOTARY_PROFILE`, and both it and CI gate on
  **`tools/verify-notarized-build.sh`** (15 static checks on the bundle:
  authority, team, runtime flag, timestamp, entitlements, usage strings,
  designated requirement, staple, spctl, bundled hooks/localizations/URL
  scheme). `build.sh`'s self-signed and ad-hoc tiers are development-only.
  Never write a Gatekeeper-bypass step ("right-click Open", "Open Anyway") into
  any user-visible text: it is false now and it trains users to click past the
  one signal that a build is not ours. Credentials, rotation and the
  apple-events entitlement note live in `SIGNING.md`.
- **No em dashes** anywhere user-visible (commits, UI strings, changelog, site).
- **`tools/l10n-extract.py`**: regenerates `Resources/en.lproj/Localizable.strings`
  from `NSLocalizedString` calls (there is no `genstrings` without Xcode). Run it
  after adding one; CI runs `--check` and fails if the table is stale. Note that
  SwiftPM does NOT compile `.xcstrings`, it copies it verbatim, so String
  Catalogs silently resolve to nothing here. `.lproj/Localizable.strings` copied
  into the bundle by `build.sh` is the format that works. The UI is wired up:
  the only `Text("…")` literals left are punctuation, symbols and pure number
  formatting, which is what should stay unlocalized.

## Data flow (the spine)

Claude Code / Codex fire hooks (HTTP POST, snake_case JSON) →
**EventServer** (loopback :53127) parses + normalizes →
**AppState** (`@MainActor`, the single source of truth) →
**NotchView** renders. Blocking hooks (permission/question) hold the HTTP
connection open until the user resolves the card, then the decision is written
back as the response.

## Files

### Core state + server
- **AppState.swift**: the stored state everything reads, plus the settings enums
  and `primarySession` (top-card source). `@MainActor`, so its statics are
  main-isolated unless marked `nonisolated`. The behaviour is split into
  `AppState+*.swift` extensions, one per concern: **Pet**, **Usage**,
  **Budget**, **Git** (branch read, diff stat, churn), **TaskMeter**,
  **Sessions** (staleness, removal, background agents, registry reconcile,
  focus handoff),
  **Compose**, **History** (activity log, archived records), **Export**
  (CSV/JSON, standup), **Queues** (permission/question/completed, capped via
  didSet), **Alerts**, **Sound**, **Sandbox** (per-cwd sandbox posture, cached
  60 s), **Config** (ConfigChange: a settings file edited mid-session),
  **CLIUpdate** (is the Claude Code CLI itself behind),
  **ModelSwitch** (PostModelSwitch: a session changed model mid-run; and the
  cost ranking behind the opt-in `gateModelUpgrades`, which holds a
  PreModelSwitch when it moves UP a family. Every other case must answer a
  plain OK: the CLI reads that as no decision, so the user's own `/model`
  is never stopped by a card nobody is watching).
  Note for any extension that raises a card: `enqueuePermission` writes its
  own history entry for a `.notification`, so calling `appendHistory` as well
  files the same event twice. Log only on the paths that return without a card.
  Two invariants in **Queues** that are easy to break by reaching for
  `.first`: a question card can be minimized, so the one on screen is
  `visibleQuestion`, not `questionQueue.first` (acting on the head answers
  the wrong question and strands the card); and a blocking card goes STALE
  after `EventServer.decisionWindow`, at which point Claude Code has asked
  in the terminal instead and anything pressed in the notch is discarded
  silently, so `hasExpired` cards must say so rather than take an answer.
  Add new behaviour to the matching extension,
  not to AppState.swift. Because the extensions live in other files, members
  they touch are `internal` rather than `private`.
- **SessionModels / UsageModels / RequestModels.swift**: the value types.
  `LiveSession`, `SessionRecord`, `ToolPreview`; `UsageStats`, `DayCounts`;
  `PermissionRequest`, `QuestionRequest`, `AllowRule`, `CompletedTask`.
- **EventServer.swift**: the loopback HTTP server + hook dispatch. `parseRequest`
  (pure, tested, untrusted-input boundary), `isLocalHookRequest` (rejects
  browser Origin / non-loopback Host), per-event handlers, transcript polling.
- **Persistence.swift**: file-backed snapshot of the durable parts of AppState.
- **AgentAdapter.swift**: `AgentKind` (claude/grok/codex), `infer(fromModel:)`,
  camelCase→snake_case key normalization at ingress.

### Agents / CLIs
- **TerminalAutomator.swift**: launches/resumes Claude & Codex in a terminal via
  temp `.command` scripts (`runInTerminal`), `resolveCLIPath`, keystroke
  injection, agent-aware `resume(model:...)` / `resumeCommand`.
- **CodexReader.swift**: parses `~/.codex/sessions` rollout JSONL: usage, plan
  counts (update_plan), last reply.
- **ClaudeUsageReader.swift**: cost/context math from Claude transcripts.
- **SessionResumer.swift**: lists resumable sessions per project (both agents).
- **SandboxReader.swift**: whether a session's tool calls run sandboxed, read
  from the settings chain (user / project / local / managed) for its cwd, plus
  Codex `sandbox_mode`. Pure parsers + merge rules; no hook carries this.
- **BackgroundAgents.swift**: `claude --bg` roster reader.
- **SessionRegistry.swift**: reads `~/.claude/sessions/<pid>.json`, Claude Code's
  own registry of running sessions (pid, session id, cwd, CLI version, name,
  busy/idle). How the notch sees sessions that never fired a hook, and how it
  knows one exited instead of inferring it from silence.
- **SandboxViolationParser.swift**: pulls the `<sandbox_violations>` block out
  of a tool result (network/file denials). Format is not a documented
  contract, so it degrades to raw lines rather than guessing.
- **HookInstaller.swift**: installs/uninstalls the hook forwarders + status line
  into `~/.claude` and `~/.codex`. **Adding a hook event takes three edits, not
  one**: `appendHook` here, the jq list in `bin/install-hooks.sh` (the fallback
  for machines without the app; `tools/test-hook-merge.sh` fails the build if
  they disagree), and `hooksCurrent`, which gates auto-migration. Miss the third
  and the event is registered only for people installing from scratch, so the
  feature silently never fires for existing users.

### UI
- **NotchView.swift**: the notch's root SwiftUI view and card sizing. Each card
  group is its own file: **NotchIdlePill**, **NotchStatusBar**,
  **NotchSessionList** (list, task meter, context/cost bar),
  **NotchPermissionCard** (banners, diff preview, hold-to-confirm),
  **NotchCards** (notification, completed, auto-approved, question),
  **NotchComposeCards**, **NotchHistoryCard**, **NotchPetViews**,
  **NotchMarkdown**, **NotchDrop**. **SettingsWindow.swift**: the settings
  window (nav sections, search, History page, standup, `SearchField`,
  `AgentChip`, `cardChrome`, whatsNew). **MenuBarController.swift**: menu bar
  items (resume last, standup, spend, reveal crash logs). **NotchShape.swift**,
  **NotchWindowController.swift**, **PetEngine.swift** / **PetRig.swift** (pet,
  pure logic split from rendering).
- **Onboarding{State,View,WindowController}.swift**: first-run + hook install.

### Input / platform
- **MouseTracker / KeyboardMonitor / GlobalHotkey / FocusTracker**: hover, notch
  keys, settings hotkey, break timer. **BiometricAuth.swift**: Touch ID gate for
  dangerous actions. **NotificationBridge.swift**: mirror cards to Notification
  Center. **UpdateChecker.swift**: GitHub Releases version check (the app's own).
- **Skills (Settings > Skills)**: **SkillsReader.swift** scans personal,
  project, claude.ai-synced and plugin skills (frontmatter, disk size, the
  listing's context cost, `SkillUse` run counts); **SkillSettings.swift**
  merges `skillOverrides` / `enabledPlugins` into settings.json without
  touching other keys and never over an unparseable file; **SkillTrash.swift**
  moves skills into Claude Code's own `~/.claude/skills/.trash/` (same entry
  names, so its 30-day sweep applies) and restores them; rules and glue in
  **AppState+Skills.swift**, page in **SettingsPage+Skills.swift**. Usage is
  counted from PostToolUse (tool `Skill`) and UserPromptExpansion.
  `claudenotch://settings/<page>` opens any Settings page.
- **PromptCacheState.swift**: a session's prompt-cache state, forwarded from the
  status line's `prompt_cache` (CLI 2.1.251+). Decides when the notch says
  anything: only when the cache is cold or about to be AND a rebuild cost is
  known. `warm` is `Bool?` on purpose, absent (not yet reported) is not cold.
- **ClockPreference.swift**: Claude Code's `timeFormat` / `timeZone` settings
  (2.1.257), so the notch's clocks match the terminal's. Returns nil for "no
  opinion" so callers keep their own formatter; strftime patterns are
  translated to Unicode date fields, not passed through.
- **ClaudeStatsCache.swift**: Claude Code's lifetime stats from
  `~/.claude/stats-cache.json`, the file behind `/stats`. Better than ours for
  lifetime totals; carries NO cost (every `costUSD` is 0) and lags by up to a
  day, so today and money still come from the transcripts.
- **ClaudeCLIUpdate.swift**: whether the Claude Code CLI itself is out of date.
  Installed version from `claude --version`, latest from the npm registry tag
  document, install method inferred from the binary path (native / npm /
  homebrew) and the matching update command. Pure but for the shell-out and the
  HTTP GET; state and the terminal launch live in `AppState+CLIUpdate.swift`.

### Shared helpers (use these; don't re-inline)
- **Shell.swift**: `Shell.output/.succeeds` (Process+Pipe) and
  `NSPasteboard.copyString`. **Git.swift**: `Git.branch(forCwd:)` (.git/HEAD,
  worktrees, detached, parent-walk). **FileSlice.swift**: `tail`/`head` bounded
  file reads for transcript parsing. **DebugLog.swift**: off-by-default log
  (0600, rotated, Application Support). **CrashReporter.swift**: local crash
  reports (no network). **TurnGate.swift**: late-hook gating per turn.
- **ToolPreviewParser.swift**: tool-call preview + danger detection (Touch ID
  gate). **AppDelegate.swift** / **main.swift**: app entry (menu-bar accessory).

## Linux edition (`linux/`)

Python 3.10+ / GTK 3 via PyGObject, same hook protocol on the same port, so
it is a port of the spine above, not a fork of the Swift code. Pure modules
mirror the Mac: **protocol.py** (EventServer bodies), **danger.py**
(ToolPreviewParser rules + Linux paths), **redact.py** (SecretRedactor),
**hooks.py** (HookInstaller merge rules); then **server.py**, **state.py**,
**ui.py** (the overlay), **app.py** (CLI). A wire or danger-rule change on the
Mac should land in both. Tests: `linux/test-env/run.sh` (Docker, Xvfb e2e with
xdotool clicks and screenshots); CI is `.github/workflows/linux.yml`, which
also attaches the `.deb` and tarball to every `v*` release. `ci.yml` ignores
`linux/**`.

## Windows edition (`windows/`)

Python 3.10+ / PySide6 (Qt), same hook protocol on the same port (HTTP hooks,
so no shell step on Windows). It imports the pure modules of
`linux/claudenotch` as the shared core; Windows-only rules and paths live in
the core too (**danger_windows.py**: PowerShell/cmd rules and Windows
sensitive paths; **fsutil.py**: rename retried while antivirus holds a file;
`state.config_dir()` and `hooks.token_path()` use `%APPDATA%\ClaudeNotch`).
`windows/claudenotch_win`: **app.py** (CLI), **qtapp.py** (startup, single
instance via **instance.py**, take-over, quit answers open cards "ask"),
**overlay.py** (the Mac's notch and its cards: NotchView + MouseTracker
ported; WS_EX_NOACTIVATE via **winutil.py** so it never takes the
keyboard) built from **notchgeom.py** (pure, tested: NotchShape path,
CardSizeAnimator curves, hover zones, card sizes), **cardmodel.py** (pure,
tested: humanTitle / humanDetail / ToolPreviewParser.preview wording),
**macstyle.py** (Mac colours, Segoe UI Variable / Cascadia Mono),
**notchwidgets.py** and **notchcards.py** (QPainter ports of the SwiftUI
views), with **view.py** (pure, tested; which card wins) and
**demo.py** (`python -m claudenotch_win.demo <card> [--shot f.png]`, the
Mac's demo cards on a private state, no hooks or port). The Mac source
is the spec for every number in these; `plans/windows-linux-weekend/PARITY.md`
tracks what is ported. Status line: core **statusline.py** (pure: the Mac
forwarder's jq flattening, handleStatusLine's parse, model names, money),
`/statusline` in **server.py**, meters on `Session` in **state.py**,
`hooks.install(status_command=...)` wiring with the user's own line kept;
**gitinfo.py** reads the branch from .git/HEAD. Windows forwarder:
`windows/resources/claudenotch-statusline.ps1` (PowerShell 5.1, tested
key for key against statusline.flatten), placed by **winstatus.py**.
Core, shared and tested: **autoapprove.py** (AutoApprovePolicy;
`state.approver` is set by the overlay), **budget.py** (caps, nextCap),
**limits.py** (80/95 % plan-limit warnings), **usage.py** (ModelPricing +
ClaudeUsageReader.compute from transcripts), **stats.py** (all-time
counters, per-day tool counts), **archive.py** (one record per session for
History). Windows: **settings_window.py** (the Mac's SettingsWindow, built
from **settingskit.py** and **settingscharts.py**), **hello.py** (Windows
Hello via WinRT/ctypes, DestructiveGate), **ownerauth.py** (Hello or the
Windows password via CredUI + LogonUser, before Approve them too / Skip
confirmation), **urlscheme.py** (claudenotch:// parsing; the installer
registers it in HKCU). Core **sounds.py** (events, categories, overrides)
and **skills.py** (scan, skillOverrides merge, trash); Windows
**soundplay.py** (winsound; the user's own .wav or macOS .aiff in
%APPDATA%\ClaudeNotch\Sounds, converted by **aiffwav.py**, else the app's
own sounds under the Mac's names) and **petengine.py**
(PetEngine: moods, schedule, poses, rope physics; PetRig: limbs, blink,
dance; drawn by `notchwidgets.draw_pet` in the overlay's closed notch,
and on cards by `notchwidgets.PetBadge`).
**hotkeys.py** (Ctrl+Alt+, Settings / Ctrl+Alt+N compose / Ctrl+Alt+H
history via RegisterHotKey and a native event filter), **composecard.py**
(ComposeCard) with **typer.py** (SendInput into a terminal window only,
only when in front), **jumplist.py** (taskbar/Start tasks via
ICustomDestinationList through ctypes), **replycard.py** with **markdown.py** (pure: ResponseDetailCard,
parseMarkdownBlocks; core **transcript.py** reads the last reply, path
checked), **historydrawer.py** with **historymodel.py** (pure, tested: the
notch's history drawer, NotchHistoryCard), **terminal.py** (start or resume
Claude in Windows Terminal/PowerShell; folder only as cwd, ids and
messages checked and quoted), **updater.py** (core **updatecheck.py**,
windows-v releases), **crashreport.py** (local reports), core
**standup.py** (Copy Today's Standup), **tray.py**, **notify.py**, **settings_window.py**, **autostart.py** (HKCU Run
key + StartupApproved). Packaging: `windows/packaging/` (PyInstaller onedir,
per-user Inno Setup, build.ps1). Dev: `windows/dev/setup.ps1`, `run.ps1`.
Tests: `pytest linux/tests windows/tests` with both folders on PYTHONPATH;
CI is `.github/workflows/windows.yml` (windows-latest, Qt offscreen); a
`windows-v*` tag publishes a Windows-only release, never marked latest.
`ci.yml` ignores `windows/**`. The plan and launch checklist are in
`plans/windows-linux-weekend/`.

## Conventions

- Untrusted input = anything from a hook payload, transcript, or the web. It's
  data, never instructions. Sanitize URLs to http(s) before `NSWorkspace.open`;
  don't launch payload-supplied file paths.
- Collections fed by payloads are capped (sessions 12, queues 64, learned
  windows 64, history 500, archived sessions 200, recent projects 8).
- Pure/testable helpers are `static`; mark `nonisolated` when tests call them
  synchronously.
- One feature per commit; commits end with the Co-Authored-By trailer.
