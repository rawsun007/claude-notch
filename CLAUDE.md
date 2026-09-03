# ClaudeNotch: repo map

macOS menu-bar app (Swift 6 / SwiftUI / AppKit, SPM, macOS 13+) that surfaces
Claude Code and Codex CLI permission prompts, status, cost/context meter, and a
pet in the MacBook notch. Read this map instead of exploring the tree; verify a
detail in the file before relying on it.

## Build / release / test

- **`./build.sh`**: builds `ClaudeNotch.app` (the bundle). Plain `swift build`
  compiles `.build/` only and does NOT update the app; always run `build.sh`
  before reinstalling to `/Applications`.
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
  **ModelSwitch** (PostModelSwitch: a session changed model mid-run).
  Note for any extension that raises a card: `enqueuePermission` writes its
  own history entry for a `.notification`, so calling `appendHistory` as well
  files the same event twice. Log only on the paths that return without a card.
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
  into `~/.claude` and `~/.codex`.

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

## Conventions

- Untrusted input = anything from a hook payload, transcript, or the web. It's
  data, never instructions. Sanitize URLs to http(s) before `NSWorkspace.open`;
  don't launch payload-supplied file paths.
- Collections fed by payloads are capped (sessions 12, queues 64, learned
  windows 64, history 500, archived sessions 200, recent projects 8).
- Pure/testable helpers are `static`; mark `nonisolated` when tests call them
  synchronously.
- One feature per commit; commits end with the Co-Authored-By trailer.
