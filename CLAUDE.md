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
- **`tools/release.sh <ver>`**: bumps version, builds DMG, generates cask,
  pushes, creates the GitHub release + DMG, updates the Homebrew tap, reinstalls
  locally. After it: add the release to the website changelog (separate repo,
  `../claude mac app website/app/changelog/releases.ts`), rebuild, sync `docs/`.
- **No em dashes** anywhere user-visible (commits, UI strings, changelog, site).
- **`tools/l10n-extract.py`**: regenerates `Resources/en.lproj/Localizable.strings`
  from `NSLocalizedString` calls (there is no `genstrings` without Xcode). Run it
  after adding one; CI runs `--check` and fails if the table is stale. Note that
  SwiftPM does NOT compile `.xcstrings`, it copies it verbatim, so String
  Catalogs silently resolve to nothing here. `.lproj/Localizable.strings` copied
  into the bundle by `build.sh` is the format that works. Only the permission
  card is wired up so far; the rest of the UI is still hardcoded English.

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
  **Sessions** (staleness, removal, background agents, focus handoff),
  **Compose**, **History** (activity log, archived records), **Export**
  (CSV/JSON, standup), **Queues** (permission/question/completed, capped via
  didSet), **Alerts**, **Sound**. Add new behaviour to the matching extension,
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
- **BackgroundAgents.swift**: `claude --bg` roster reader.
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
  Center. **UpdateChecker.swift**: GitHub Releases version check.

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
