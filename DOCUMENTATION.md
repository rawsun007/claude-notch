- [2026-05-26]: Fix Swift 6 concurrency warnings in EventServer.swift
  - *Details*: Replaced explicit `lock()` and `unlock()` calls on `NSLock` instances with `withLock { ... }`.
  - *Tech Notes*: Swift 6 compiler flags explicit lock method calls in asynchronous contexts (`Task`, `async`) as they might cause cooperative thread deadlocks. Using the safe scoped locking method `withLock` ensures the lock is safely acquired and released without triggering compiler warnings.

- [2026-05-26]: Resolve merge conflicts with main
  - *Details*: Resolved merge conflicts in `HookInstaller.swift` and `ToolPreviewParser.swift` by adopting the updated code from `main`. Addressed a lingering Swift 6 strict concurrency warning in `TerminalAutomator.swift` by marking `debugLog` as `nonisolated`.
  - *Tech Notes*: The local branch was out of sync with recent changes on `main` (which already included non-destructive hook logic and robust `rm -rf` parsing). Used `git checkout origin/main` for conflicting files to preserve upstream functionality. Also fixed a variable assignment error introduced during the `withLock` refactor in `EventServer.swift`.
