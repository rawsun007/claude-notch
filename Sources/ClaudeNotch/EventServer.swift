import Foundation
import AppKit

final class EventServer {
    private let port: UInt16
    private weak var state: AppState?
    private var listener: HookListener?
    private var bindRetryTimer: DispatchSourceTimer?
    /// What this install's own hook URL carries, or nil when it carries
    /// nothing. Read from settings.json rather than from the token file, so the
    /// app can only ever demand what the caller is actually sending. Read once
    /// at startup: it changes when the hooks are installed, which restarts the
    /// app anyway.
    private let expectedToken: String? = HookToken.expected()
    private let queue = DispatchQueue(label: "com.claudenotch.server")
    private let workQueue = DispatchQueue(label: "com.claudenotch.server.work", attributes: .concurrent)
    private let transcriptPollLock = NSLock()
    // Per-transcript poll generation, keyed by transcript path, so concurrent
    // sessions each keep polling independently. A newer poll for a given path
    // supersedes only the previous poll for that same path — never the polls of
    // other sessions (which previously happened because the "active" path and
    // generation id were single shared values).
    private var transcriptPollTokens: [String: Int] = [:]

    /// Last read size per transcript path, for skipping unchanged files.
    private var transcriptSizes: [String: UInt64] = [:]
    // taskId → subject, learned from TaskCreate / TaskUpdate(with subject).
    // Lets us put a human label on TaskUpdate calls that only carry {taskId, status}.
    private var taskRegistry: [String: String] = [:]
    private let taskRegistryLock = NSLock()

    // Throttle per-transcript context+cost recomputation (parses the whole file).
    private var meterLastComputed: [String: Date] = [:]
    private let meterLock = NSLock()

    // Last plan-limit reading we logged, so a redraw-per-keystroke status line
    // doesn't fill the debug log with the same numbers.
    private var lastLimitsFingerprint = ""
    private let limitsLock = NSLock()

    // Throttle the daily total-cost recompute (parses every recent transcript).
    private var todayCostLastComputed = Date.distantPast
    private let todayCostLock = NSLock()
    // Steady refresh so the daily figure the budget enforcer reads never goes
    // stale. Without it, todayCostUSD only updated as a side-effect of Stop /
    // activity hooks, so right after a relaunch (e.g. an update) it sat at 0
    // and enforcement was blind until the next turn ended.
    private var dailyCostTimer: DispatchSourceTimer?

    /// Recompute today's total estimated cost across all sessions (heavy: reads
    /// every recent transcript) and push it for the daily budget check. Throttled
    /// to once a minute, off the main thread.
    private func maybePushTodayCost(force: Bool = false) {
        let now = Date()
        let go = todayCostLock.withLock { () -> Bool in
            if !force, now.timeIntervalSince(todayCostLastComputed) < 25 { return false }
            todayCostLastComputed = now
            return true
        }
        guard go else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            let usage = ClaudeUsageReader.compute()
            let effort = ClaudeUsageReader.effortFromSettings()
            Task { @MainActor [weak state = self.state] in
                state?.noteTodayCost(usage.today.costUSD)
                state?.noteRollingCosts(fiveHour: usage.fiveHour.costUSD,
                                        weekly: usage.week.costUSD)
                state?.noteEffort(effort)
            }
        }
    }

    /// Parse a session transcript for its context + cost meter off the main
    /// thread and push it to AppState. `throttle` skips a recompute if one ran
    /// for this transcript within the interval (the full-file parse isn't free).
    private func pushSessionMeter(transcriptPath path: String, sessionId: String, throttle: TimeInterval = 0) {
        guard !path.isEmpty, EventServer.isAllowedTranscriptPath(path) else { return }
        maybePushTodayCost()
        if throttle > 0 {
            let now = Date()
            let skip = meterLock.withLock { () -> Bool in
                if let last = meterLastComputed[path], now.timeIntervalSince(last) < throttle { return true }
                meterLastComputed[path] = now
                return false
            }
            if skip { return }
        } else {
            meterLock.withLock { meterLastComputed[path] = Date() }
        }
        workQueue.async { [weak self] in
            guard let self, let m = ClaudeUsageReader.sessionMeter(transcriptPath: path) else { return }
            Task { @MainActor [weak state = self.state] in
                state?.noteSessionMeter(sessionId: sessionId,
                                        contextTokens: m.contextTokens,
                                        costUSD: m.costUSD,
                                        model: m.model)
            }
        }
    }

    private func recordTask(id: String, subject: String) {
        guard !id.isEmpty, !subject.isEmpty else { return }
        taskRegistryLock.withLock {
            taskRegistry[id] = subject
        }
    }

    private func taskSubject(for id: String) -> String? {
        guard !id.isEmpty else { return nil }
        return taskRegistryLock.withLock { taskRegistry[id] }
    }

    /// Best-effort: pull a task id out of TaskCreate's response, which Claude
    /// Code emits as either a dict ({id/taskId/...}) or a free-form string
    /// ("Created task 5: …"). First integer wins for the string case.
    /// Pure (no instance state) and `static` so it's unit-testable.
    static func extractTaskId(from response: Any) -> String? {
        if let dict = response as? [String: Any] {
            for key in ["taskId", "task_id", "id"] {
                if let v = dict[key] as? String, !v.isEmpty { return v }
                if let i = dict[key] as? Int { return String(i) }
            }
            if let task = dict["task"] as? [String: Any] {
                return extractTaskId(from: task)
            }
        }
        // The common wrapper: {"content": [{"type": "text", "text": "Task #1 …"}]}.
        // Without this the dict branch above finds no id key, falls through
        // every other case, and the task is never counted.
        if let dict = response as? [String: Any], let content = dict["content"] {
            if let id = extractTaskId(from: content) { return id }
        }
        if let dict = response as? [String: Any], let text = dict["text"] as? String {
            if let id = extractTaskId(from: text) { return id }
        }
        if let s = response as? String,
           let range = s.range(of: #"\d+"#, options: .regularExpression) {
            return String(s[range])
        }
        if let arr = response as? [Any] {
            for item in arr {
                if let id = extractTaskId(from: item) { return id }
            }
        }
        return nil
    }

    /// Like humanDetail, but consults the task registry when TaskUpdate is
    /// missing its subject (the common case — most TaskUpdate calls only
    /// carry {taskId, status}).
    private func enrichedDetail(for tool: String, input: [String: Any]) -> String {
        if tool == "TaskUpdate" {
            let subject = (input["subject"] as? String) ?? ""
            let taskId  = (input["taskId"] as? String) ?? ""
            let status  = (input["status"] as? String) ?? ""
            if subject.isEmpty, !taskId.isEmpty, let known = taskSubject(for: taskId) {
                return status.isEmpty ? known : "\(known)  →  \(status)"
            }
        }
        return humanDetail(for: tool, input: input)
    }

    init(port: UInt16, state: AppState) {
        self.port = port
        self.state = state
    }

    /// Best-effort "who did this hook fire for?" — preferred answer is the
    /// app that was frontmost when the hook landed, but if that's us (the
    /// notch panel was key at the time), fall back to the last non-self
    /// app the FrontmostTracker saw. Without this filter, every "Open IDE"
    /// click after the notch had focus would just no-op (activate ourself).
    @MainActor
    fileprivate static func capturedOriginator(state: AppState?) -> String? {
        let me = Bundle.main.bundleIdentifier
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           bid != me {
            return bid
        }
        return state?.frontmost.lastNonSelf?.bundleIdentifier
    }

    func start() throws {
        // Bound by hand rather than through NWListener, which sets SO_REUSEPORT
        // on its socket whatever `allowLocalEndpointReuse` says. That option
        // lets a second process running as the same user bind this port and
        // take a share of the connections, and the share includes PreToolUse
        // and PermissionRequest: blocking hooks, where whoever answers decides
        // whether a tool call runs. See HookSocket for the rest of it.
        // A port that is busy right now is usually the copy of this app that
        // is still exiting: every update and every quick restart goes through a
        // moment where both processes exist. Giving up on the first refusal
        // left the app running deaf until someone relaunched it by hand, which
        // is the failure the menu bar warning was built to describe rather than
        // a failure worth having.
        do {
            try bind()
        } catch HookListener.ListenError.inUse {
            NSLog("ClaudeNotch: port \(port) busy, retrying")
            scheduleBindRetry()
        }

        // Seed model and effort immediately at launch so Row 2 is populated
        // before the first hook fires (no wait for the 12-second timer below).
        workQueue.async { [weak self] in
            guard let self else { return }
            let model = ClaudeUsageReader.lastUsedModel()
            let effort = ClaudeUsageReader.effortFromSettings()
            Task { @MainActor [weak state = self.state] in
                if !model.isEmpty { state?.noteStartupModel(model) }
                state?.noteEffort(effort)
            }
        }

        // Keep today's cost fresh for the budget enforcer even when no hooks are
        // firing. First tick at +12s (a grace window after launch) then every
        // 30s; `force` bypasses the recompute throttle.
        let t = DispatchSource.makeTimerSource(queue: workQueue)
        t.schedule(deadline: .now() + 12, repeating: 30)
        t.setEventHandler { [weak self] in self?.maybePushTodayCost(force: true) }
        t.resume()
        dailyCostTimer = t
    }

    /// Take the port, or throw.
    private func bind() throws {
        let l = HookListener(queue: queue)
        try l.start(port: UInt16(port)) { [weak self] conn in self?.accept(conn) }
        listener = l
        NSLog("ClaudeNotch listening on 127.0.0.1:\(port) (exclusive)")
        Task { @MainActor [weak state] in state?.noteServerListening() }
    }

    /// How long a predecessor gets to finish exiting before the app says
    /// anything. Quitting and relaunching takes about a second; a card that
    /// flashed up every time would be noise, and worse, noise about the one
    /// thing that has to mean something when it appears.
    static let bindGrace: TimeInterval = 8

    /// How often to try again. Frequently while a predecessor might still be
    /// letting go, then slowly forever, because whatever has the port may give
    /// it back at any point and the app can simply start working again.
    static let bindRetryInterval: TimeInterval = 2
    static let bindRetrySlowInterval: TimeInterval = 30

    private func scheduleBindRetry() {
        let startedAt = Date()
        var reported = false
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.bindRetryInterval,
                   repeating: Self.bindRetryInterval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if (try? self.bind()) != nil {
                NSLog("ClaudeNotch: took port \(self.port) on retry")
                self.bindRetryTimer?.cancel()
                self.bindRetryTimer = nil
                return
            }
            let waited = Date().timeIntervalSince(startedAt)
            // Past the grace period this is no longer a restart racing itself,
            // so say so, once, and keep trying at a slower pace.
            if !reported, waited > Self.bindGrace {
                reported = true
                let port = self.port
                Task { @MainActor [weak state = self.state] in
                    state?.noteServerFailed(.portTaken(port: Int(port)))
                }
                t.schedule(deadline: .now() + Self.bindRetrySlowInterval,
                           repeating: Self.bindRetrySlowInterval)
            }
        }
        t.resume()
        bindRetryTimer = t
    }

    /// Release the port and stop the timers.
    ///
    /// The app itself never stops the server (it lives as long as the process),
    /// but a test that asserts nobody else can take the port has to be able to
    /// give it back, and a listener that cannot be shut down is one that cannot
    /// be tested for exclusivity.
    func stop() {
        bindRetryTimer?.cancel()
        bindRetryTimer = nil
        dailyCostTimer?.cancel()
        dailyCostTimer = nil
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: HookConnection) {
        conn.read(max: EventServer.maxRequestBytes) { [weak self] buffer in
            guard let self, let req = EventServer.parseRequest(buffer) else { return false }
            self.handle(req, on: conn)
            return true
        }
    }

    /// Hard ceiling on a single request. Real hook payloads are a few KB; the
    /// largest (a status line) is tens of KB. Anything past a megabyte is either
    /// broken or a local process trying to make us buffer without end — a
    /// connection that never sends the CRLFCRLF terminator, or one that declares a
    /// giant Content-Length, would otherwise grow `buf` until the app is out of
    /// memory. Loopback-only, so this is a misbehaving-local-process guard, not a
    /// network one, but it is cheap and it closes the one unbounded path in here.
    static let maxRequestBytes = 1024 * 1024

    struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
        var host: String? = nil
        var origin: String? = nil
        /// Everything after the `?`, unparsed. Carries the hook token when the
        /// installed URLs have one; see HookToken.
        var query: String? = nil
    }

    /// Parse a raw HTTP/1.1 request off the socket buffer. Returns nil when the
    /// buffer doesn't yet hold a complete request (no header terminator, or the
    /// body is shorter than Content-Length) so the caller keeps reading. Pure
    /// and `static` so the untrusted-byte handling is unit-testable.
    static func parseRequest(_ data: Data) -> HTTPRequest? {
        let crlfcrlf = Data([13, 10, 13, 10])
        guard let split = data.range(of: crlfcrlf) else { return nil }
        guard let headerString = String(data: data.subdata(in: 0..<split.lowerBound), encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(targetParts.first ?? "")
        let query = targetParts.count > 1 ? String(targetParts[1]) : nil

        var contentLength = 0
        var sawContentLength = false
        var host: String?
        var origin: String?
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch name {
                case "content-length":
                    // Two of these is a malformed request, and picking one of
                    // the two lengths is how a parser ends up disagreeing with
                    // whatever else reads the same bytes. Refuse it instead:
                    // no real hook sends a second one.
                    if sawContentLength { return nil }
                    sawContentLength = true
                    guard let n = Int(value) else { return nil }
                    contentLength = n
                case "host": host = value
                case "origin": origin = value
                default: break
                }
            }
        }
        // A declared length past the ceiling is refused outright rather than
        // waited on: otherwise the reader keeps asking for more of a body that is
        // never coming, and the buffer grows unbounded.
        guard contentLength >= 0, contentLength <= maxRequestBytes else { return nil }

        let bodyStart = split.upperBound
        if data.count - bodyStart < contentLength { return nil }
        let body = contentLength > 0
            ? data.subdata(in: bodyStart..<(bodyStart + contentLength))
            : Data()
        return HTTPRequest(method: method, path: path, body: body, host: host,
                           origin: origin, query: query)
    }

    /// Whether a parsed request looks like it genuinely came from a local hook
    /// (curl/bash) and not a browser aimed at us. Our forwarders talk to
    /// 127.0.0.1 and send no Origin; a web page — including a DNS-rebinding one
    /// pointing its own domain at 127.0.0.1 — sends a browser Origin and a
    /// non-loopback Host. Reject those so a page the user happens to have open
    /// can't inject spoofed sessions, activity, or notifications into the notch.
    static func isLocalHookRequest(_ req: HTTPRequest) -> Bool {
        // Every hook is a POST. The Origin check below only covers requests a
        // browser marks as cross-origin, and a browser marks NONE of its
        // navigational GETs that way: `<img src="http://127.0.0.1:53127/permission">`
        // on any page the user visits sends no Origin and a loopback Host, so it
        // walked straight past the guard and queued a blocking permission card
        // that held the notch for the full decision window. A browser cannot
        // make a no-Origin POST, so requiring the method closes that door
        // without touching the forwarders.
        guard req.method.uppercased() == "POST" else { return false }
        if req.origin != nil { return false }           // browsers always set Origin on cross-origin POST
        guard let host = req.host else { return true }  // curl/1.0 without Host: allow
        // Strip the port; accept only loopback authorities.
        let name = host.hasPrefix("[") ? "[::1]"        // IPv6 literal, port after ]
            : String(host.split(separator: ":").first ?? "")
        return name == "127.0.0.1" || name == "localhost" || name == "[::1]" || host == "[::1]"
    }

    /// The directories a genuine agent transcript can live under. Claude Code
    /// keeps transcripts in ~/.claude/projects (relocatable via
    /// CLAUDE_CONFIG_DIR); Codex in ~/.codex/sessions (CODEX_HOME). Computed so
    /// tests can pass an explicit environment/home.
    static func transcriptRoots(home: String = NSHomeDirectory(),
                                env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        func root(_ override: String?, default def: String) -> String {
            let base = (override?.isEmpty == false) ? override! : (home as NSString).appendingPathComponent(def)
            // Normalize away any trailing slash, then add exactly one so a
            // prefix check can't match a sibling like "~/.claudeXYZ".
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            return trimmed + "/"
        }
        return [
            root(env["CLAUDE_CONFIG_DIR"], default: ".claude"),
            root(env["CODEX_HOME"], default: ".codex"),
        ]
    }

    /// Whether a hook-supplied `transcript_path` is one we'll actually read.
    /// The path is untrusted (any local process can POST a hook), so a value
    /// like "/etc/passwd" or "~/.claude/../.ssh/id_rsa" must be refused: we only
    /// read agent transcripts, which live under the roots above. Resolves
    /// symlinks first, then `..`, so neither a traversal nor a symlink planted
    /// inside a root (pointing the bounded read at, say, ~/.ssh/id_rsa) escapes.
    static func isAllowedTranscriptPath(_ path: String,
                                        roots: [String] = EventServer.transcriptRoots()) -> Bool {
        guard !path.isEmpty else { return false }
        // resolvingSymlinksInPath resolves symlinks before collapsing `..`,
        // matching kernel semantics — the secure order.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return roots.contains { root in
            // Resolve the root the same way so a home dir that is itself a
            // symlink still matches (both sides land on the same real prefix).
            let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            let dir = base.hasSuffix("/") ? base : base + "/"
            return resolved.hasPrefix(dir)
        }
    }

    private func handle(_ req: HTTPRequest, on conn: HookConnection) {
        // Drop anything that looks browser-originated: our hooks are curl/bash on
        // loopback and never carry an Origin. This closes the drive-by / DNS-
        // rebinding path where a page the user has open POSTs spoofed events.
        guard EventServer.isLocalHookRequest(req) else {
            NSLog("ClaudeNotch: rejected non-local request (host=%@ origin=%@)",
                  req.host ?? "-", req.origin ?? "-")
            conn.close()
            return
        }
        // A shared secret with our own forwarders, enforced only once this
        // install actually has one. See HookToken for what that does and does
        // not buy, and for why it can never make the app deaf.
        guard HookToken.allows(query: req.query, expected: expectedToken) else {
            NSLog("ClaudeNotch: rejected a hook with no valid token")
            conn.close()
            return
        }
        let rawPayload = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
        // Canonicalize key casing so Grok/Codex (camelCase) payloads read the
        // same as Claude's (snake_case). A Claude payload passes through
        // unchanged, so existing behavior is untouched.
        let payload = AgentAdapter.normalizeKeys(rawPayload)
        let path = (req.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? req.path).lowercased()

        // Every hook payload tells us about a project (cwd) — record it, except
        // for SessionEnd, which exists only to REMOVE a session (recording it
        // here would just re-add the session we're about to drop).
        // /statusline is a pure data feed (fires on every status render); it must
        // not drive session lifecycle or it would resurrect ended sessions.
        if path != "/sessionend", path != "/statusline" {
            recordSessionMetadata(payload: payload)
        }
        let sessionId = (payload["session_id"] as? String) ?? ""
        let transcriptPath = (payload["transcript_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if path != "/prompt", path != "/sessionend", let transcriptPath {
            let duration: TimeInterval = path == "/stop" ? 4 : 300
            startResponsePolling(transcriptPath: transcriptPath, sessionId: sessionId, duration: duration)
        }

        switch path {
        case "/hook":
            handleUnifiedHook(payload: payload, on: conn)
        case "/permission":
            handleBlockingPermission(payload: payload, on: conn)
        case "/question":
            handleBlockingQuestion(payload: payload, on: conn)
        case "/notification":
            handleNotification(payload: payload)
            sendOK(on: conn)
        case "/stop":
            handleStop(payload: payload)
            sendOK(on: conn)
        case "/sessionend":
            handleSessionEnd(payload: payload)
            sendOK(on: conn)
        case "/activity":
            handleActivity(payload: payload)
            sendOK(on: conn)
        case "/task":
            handleTask(payload: payload)
            sendOK(on: conn)
        case "/compact":
            handleCompact(payload: payload)
            sendOK(on: conn)
        case "/postcompact":
            handlePostCompact(payload: payload)
            sendOK(on: conn)
        case "/statusline":
            handleStatusLine(payload: payload)
            sendOK(on: conn)
        case "/prompt":
            handlePrompt(payload: payload)
            if let transcriptPath {
                startResponsePolling(transcriptPath: transcriptPath, sessionId: sessionId, duration: 300, delayFirstRead: true)
            }
            sendOK(on: conn)
        case "/subagentstart":
            handleSubagentStart(payload: payload)
            sendOK(on: conn)
        case "/pretool":
            handlePreTool(payload: payload)
            sendOK(on: conn)
        case "/extpretool":
            // External agent (e.g. Codex) tool starting. Safe commands: pop a
            // brief "running" card and return empty (the agent's own flow
            // proceeds). Dangerous commands: block with the allow/deny card and
            // return the agent's decision wire. Sends its own response.
            handleExternalPreTool(payload: payload, on: conn)
        case "/thinking":
            handlePostToolThinking(payload: payload)
            sendOK(on: conn)
        case "/posttool":
            sendOK(on: conn)
        case "/ping":
            sendOK(on: conn)
        default:
            NSLog("ClaudeNotch: unknown path \(path)")
            sendOK(on: conn)
        }
    }

    private func recordSessionMetadata(payload: [String: Any]) {
        let cwd = (payload["cwd"] as? String) ?? ""
        guard !cwd.isEmpty else { return }
        let sessionId = (payload["session_id"] as? String) ?? ""
        let permissionMode = (payload["permission_mode"] as? String) ?? ""
        Task { @MainActor [weak state] in
            let frontBID = Self.capturedOriginator(state: state)
            state?.noteSession(cwd: cwd, sessionId: sessionId, originatorBundleID: frontBID)
            // Every hook comes through here, which makes it the one place that
            // sees a session waiting out a usage limit start working again.
            // The restart is not announced by anything: the turn simply
            // continues, so the evidence is that a hook arrived at all.
            state?.noteUsageLimitMaybeResumed(sessionId: sessionId, cwd: cwd)
            if !permissionMode.isEmpty {
                state?.notePermissionMode(permissionMode, sessionId: sessionId, cwd: cwd)
            }
        }
    }

    private func handleActivity(payload: [String: Any]) {
        let tool = (payload["tool_name"] as? String) ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let sessionId = (payload["session_id"] as? String) ?? ""

        // Codex sends no status line, so read its rollout for the live context
        // meter after each tool (the token_count line is fresh by PostToolUse).
        let model = (payload["model"] as? String) ?? ""
        if AgentKind.infer(fromModel: model) == .codex, !sessionId.isEmpty {
            let cwd = (payload["cwd"] as? String) ?? ""
            DispatchQueue.global(qos: .utility).async { [weak state] in
                // Resolve the rollout ONCE: finding it walks the whole
                // ~/.codex/sessions tree, and this runs on every tool call, so
                // the per-session-id variants would pay for that walk twice a
                // call against a directory that only ever grows.
                let rollout = CodexReader.rolloutURL(forSessionId: sessionId)
                // Codex tracks tasks via update_plan (inside an exec tool), so
                // parse the plan from the rollout to drive the notch task bar.
                if let rollout, let plan = CodexReader.latestPlan(from: rollout) {
                    Task { @MainActor in state?.noteTodos(total: plan.total, done: plan.done, sessionId: sessionId) }
                }
                let branch = CodexReader.gitBranch(forCwd: cwd)
                guard let rollout, let u = CodexReader.usage(from: rollout) else {
                    // Even with no usage yet, surface the branch.
                    if !branch.isEmpty {
                        Task { @MainActor in state?.noteCodexUsage(sessionId: sessionId, cwd: cwd, contextTokens: 0, contextWindow: 0, model: model, gitBranch: branch) }
                    }
                    return
                }
                Task { @MainActor in
                    state?.noteCodexUsage(sessionId: sessionId, cwd: cwd,
                                          contextTokens: u.contextTokens,
                                          contextWindow: u.contextWindow,
                                          model: u.model.isEmpty ? model : u.model,
                                          gitBranch: branch,
                                          totalTokens: u.totalTokens)
                }
            }
        }

        // Learn taskId → subject so a later TaskUpdate (which only carries
        // {taskId, status}) can be rendered with a real label.
        if tool == "TaskCreate" {
            let subject = (input["subject"] as? String) ?? (input["description"] as? String) ?? ""
            var taskId  = (input["taskId"] as? String) ?? ""
            if taskId.isEmpty, let resp = payload["tool_response"], !(resp is NSNull) {
                taskId = Self.extractTaskId(from: resp) ?? ""
            }
            recordTask(id: taskId, subject: subject)
            if !taskId.isEmpty {
                let id = taskId
                Task { @MainActor [weak state] in
                    state?.noteTaskCreated(id: id, subject: subject, sessionId: sessionId)
                }
            }
        } else if tool == "TodoWrite" {
            // The terminal to-do list. It arrives whole on every call, so count
            // the snapshot and feed the notch task meter.
            let todos = (input["todos"] as? [[String: Any]]) ?? []
            let total = todos.count
            let done = todos.filter { ($0["status"] as? String) == "completed" }.count
            Task { @MainActor [weak state] in
                state?.noteTodos(total: total, done: done, sessionId: sessionId)
            }
        } else if tool == "TaskUpdate" {
            let subject = (input["subject"] as? String) ?? ""
            let taskId  = (input["taskId"] as? String) ?? ""
            recordTask(id: taskId, subject: subject)
            // Secondary feed for the progress meter: status transitions arrive
            // here even if the dedicated TaskCompleted hook is missed.
            let status = (input["status"] as? String) ?? ""
            if !taskId.isEmpty {
                Task { @MainActor [weak state] in
                    // Count it as created first, whatever the status. TaskCreate
                    // carries no id in its input (only subject/description, with
                    // the id buried in the reply), so an update is often the
                    // first time the app hears a task's id at all. Without this
                    // a whole list could be worked through and the meter would
                    // sit at zero, which is what it did.
                    state?.noteTaskCreated(id: taskId, subject: subject,
                                           sessionId: sessionId, viaUpdate: true)
                    switch status {
                    case "completed": state?.noteTaskCompleted(id: taskId, sessionId: sessionId)
                    case "deleted":   state?.noteTaskDeleted(id: taskId, sessionId: sessionId)
                    default:          break
                    }
                }
            }
        }

        // Did this turn actually run the tests, and did they pass? Feeds
        // CompletionAudit, which is why the failure signal has to be explicit:
        // a wrong "the tests failed" is worse than saying nothing.
        if tool == "Bash", let command = input["command"] as? String {
            let cwd = (payload["cwd"] as? String) ?? ""
            let isTest = CompletionAudit.isTestCommand(command)
            let failed = isTest ? CompletionAudit.toolReportedFailure(payload["tool_response"]) : nil
            Task { @MainActor [weak state] in
                // Any command at all, because one can edit files without an
                // Edit tool and the audit must not call that "nothing changed".
                state?.noteCommandRun(sessionId: sessionId, cwd: cwd)
                if isTest { state?.noteTestRun(failed: failed, sessionId: sessionId, cwd: cwd) }
            }
        }

        // Track files Claude edits so the notch can list what changed.
        if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool) {
            let path = (input["file_path"] as? String)
                ?? (input["notebook_path"] as? String)
                ?? ""
            if !path.isEmpty {
                let cwd = (payload["cwd"] as? String) ?? ""
                Task { @MainActor [weak state] in
                    state?.noteFileTouched(path, sessionId: sessionId, cwd: cwd)
                }
            }
        }

        Task { @MainActor [weak state] in
            guard let state else { return }
            guard !tool.isEmpty else { return }
            let detail = self.enrichedDetail(for: tool, input: input)
            let label = detail.isEmpty ? tool : "\(tool): \(detail)"
            state.noteActivity(String(label.prefix(80)), sessionId: sessionId)
        }
        // Also catch any assistant text Claude wrote before this tool call.
        // Cheap and keeps the notch fresh between Stop hooks.
        if let path = payload["transcript_path"] as? String, !path.isEmpty {
            readAndPushClaudeResponse(transcriptPath: path, sessionId: sessionId)
            // Refresh the context/cost meter as the turn grows, but not on every
            // tool call — the parse reads the whole transcript.
            pushSessionMeter(transcriptPath: path, sessionId: sessionId, throttle: 4)
        }
    }

    /// StatusLine feed: Claude Code passes authoritative context-window and
    /// plan-limit (5h / weekly) usage percentages to its statusLine command on
    /// stdin. Our forwarder relays them here — the only local source of real
    /// plan-limit usage. Numbers arrive as 0...100 (or absent).
    private func handleStatusLine(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        let model = (payload["model"] as? String) ?? ""
        // What `/rename` set, and the worktree this session is in. Both are how
        // you tell two sessions in the same repo apart; the folder name cannot.
        // The status line is the right source for the name: SessionStart fires
        // once, but a session can be renamed at any point in its life.
        let sessionName = (payload["session_name"] as? String) ?? ""
        let worktree = (payload["worktree"] as? String) ?? ""
        // The open PR for this branch, if there is one. Claude Code resolves it;
        // the app would otherwise have to shell out to `gh` to know.
        let prURL = (payload["pr_url"] as? String) ?? ""
        let prState = (payload["pr_state"] as? String) ?? ""
        // The effort the RUNNING session is on. settings.json only says what a
        // new session would start at, and the two part company the moment you
        // change effort mid-session.
        let effort = (payload["effort"] as? String) ?? ""
        func num(_ key: String) -> Double? {
            if let d = payload[key] as? Double { return d }
            if let i = payload[key] as? Int { return Double(i) }
            if let s = payload[key] as? String, let d = Double(s) { return d }
            return nil
        }
        let prNumber = num("pr_number").map(Int.init)
        let contextPct = num("context_pct")
        let fiveHourPct = num("five_hour_pct")
        let sevenDayPct = num("seven_day_pct")
        // The window Claude Code itself is measuring against, and the tokens it
        // counts as being in it. This is the only place either number is
        // reported: hooks don't carry them, and the transcript doesn't record
        // them. Everything else the app does with a context window is inference.
        // Claude Code's OWN cost for this session. Everything the app computes
        // itself is an estimate from public per-token prices; this is the number
        // Claude Code bills against, so it wins wherever it exists.
        let costUSD = num("cost_usd")
        let linesAdded = num("lines_added").map(Int.init)
        let linesRemoved = num("lines_removed").map(Int.init)
        let contextWindow = num("context_window").map(Int.init)
        let contextTokens = num("context_tokens").map(Int.init)
        // Unix epoch seconds. A percentage says you are in trouble; the reset
        // says whether you can wait it out.
        let fiveHourResetsAt = num("five_hour_resets_at").map { Date(timeIntervalSince1970: $0) }
        let sevenDayResetsAt = num("seven_day_resets_at").map { Date(timeIntervalSince1970: $0) }
        // Log a status line only when its numbers CHANGE. Claude Code pushes one
        // on every redraw, so logging them all buries the log; logging none left
        // us unable to tell a stale reading from a wrong one.
        func show(_ v: Any?) -> String { v.map { "\($0)" } ?? "nil" }
        let fingerprint = show(fiveHourPct) + show(fiveHourResetsAt)
            + show(sevenDayPct) + show(sevenDayResetsAt)
        let changed: Bool = limitsLock.withLock {
            guard lastLimitsFingerprint != fingerprint else { return false }
            lastLimitsFingerprint = fingerprint
            return true
        }
        if changed {
            debugLog("statusline: 5h=" + show(fiveHourPct) + "% reset=" + show(fiveHourResetsAt)
                     + " wk=" + show(sevenDayPct) + "% reset=" + show(sevenDayResetsAt))
        }
        // Nothing usable — don't churn the UI.
        guard contextPct != nil || fiveHourPct != nil || sevenDayPct != nil
                || contextWindow != nil || !sessionName.isEmpty || !worktree.isEmpty
                || prNumber != nil || !effort.isEmpty || costUSD != nil else { return }
        Task { @MainActor [weak state] in
            state?.noteStatusLine(sessionId: sessionId, model: model,
                                  sessionName: sessionName, worktree: worktree,
                                  prNumber: prNumber, prURL: prURL, prState: prState,
                                  effort: effort,
                                  reportedCostUSD: costUSD,
                                  linesAdded: linesAdded, linesRemoved: linesRemoved,
                                  contextPct: contextPct,
                                  contextWindow: contextWindow,
                                  contextTokens: contextTokens,
                                  fiveHourPct: fiveHourPct,
                                  sevenDayPct: sevenDayPct,
                                  fiveHourResetsAt: fiveHourResetsAt,
                                  sevenDayResetsAt: sevenDayResetsAt)
        }
    }

    /// PreCompact: context is about to be compacted. Show a transient cue.
    private func handleCompact(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteCompacting(sessionId: sessionId)
        }
    }

    /// A session's two spendable budgets, both read off PostToolUse: the
    /// WebSearch calls it has made, and either budget coming back refused.
    ///
    /// Neither has a hook of its own. The refusal arrives as an ordinary tool
    /// result, which is also the only place it is ever stated — Claude reads
    /// it, adjusts, and says nothing about it in the reply.
    private func handleAgentBudgets(payload: [String: Any]) {
        let tool = (payload["tool_name"] as? String) ?? ""
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        let cap = AgentBudgets.capReached(in: payload["tool_response"])
        // A refused search never ran, so it costs nothing and is not counted.
        let searched = tool == "WebSearch" && cap == nil
        guard searched || cap != nil else { return }
        Task { @MainActor [weak state] in
            if searched { state?.noteWebSearch(sessionId: sessionId, cwd: cwd) }
            if let cap { state?.noteBudgetCapReached(cap, sessionId: sessionId, cwd: cwd) }
        }
    }

    /// FileChanged: a watched file moved on disk. Carries `file_path` and
    /// `event`.
    ///
    /// Only reported when the agent did not do it. Claude Code's own edits
    /// already arrive as PostToolUse, and repeating them would turn a useful
    /// signal into a running commentary on the session's own work. What is left
    /// is the case worth knowing: the tree changed under the agent, which is
    /// usually the user editing in another window, a branch switch, or a build.
    private func handleFileChanged(payload: [String: Any]) {
        let path = (payload["file_path"] as? String) ?? ""
        guard !path.isEmpty else { return }
        let event = (payload["event"] as? String) ?? ""
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteFileChangedOutsideTheAgent(path: path, event: event,
                                                  sessionId: sessionId, cwd: cwd)
        }
    }

    /// InstructionsLoaded: the session pulled in a CLAUDE.md or a memory file.
    /// Carries `file_path`, `memory_type`, `load_reason`, and the glob or parent
    /// that dragged it in.
    private func handleInstructionsLoaded(payload: [String: Any]) {
        let path = (payload["file_path"] as? String) ?? ""
        guard !path.isEmpty else { return }
        let type = (payload["memory_type"] as? String) ?? ""
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteInstructionsLoaded(path: path, memoryType: type,
                                          sessionId: sessionId, cwd: cwd)
        }
    }

    /// PostToolUseFailure: a tool call did not work. Carries the tool, its
    /// error, how long it ran, and whether the user interrupted it.
    ///
    /// Nothing showed any of this before: a session whose every command fails
    /// looked exactly like a session working, because the only thing on screen
    /// was the name of the tool it had just started.
    private func handleToolFailure(payload: [String: Any]) {
        guard let event = ToolFailure.parse(payload) else { return }
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteToolFailed(event, sessionId: sessionId, cwd: cwd)
        }
    }

    /// A tool call that worked ends whatever run of failures was going.
    private func handleToolSucceeded(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteToolSucceeded(sessionId: sessionId, cwd: cwd)
        }
    }

    /// PostCompact: compaction finished. Carries `trigger` ("manual" for
    /// /compact, "auto" when the window filled up) and `compact_summary`, the
    /// text the session keeps in place of what it just dropped.
    private func handlePostCompact(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        let trigger = (payload["trigger"] as? String) ?? ""
        let summary = (payload["compact_summary"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteCompacted(sessionId: sessionId, cwd: cwd,
                                 trigger: trigger, summary: summary)
        }
    }

    /// SubagentStart: a subagent was just spawned. Increment the session's
    /// runningAgentCount so the badge in the row persists through any tool
    /// activity updates that would otherwise overwrite a plain label.
    private func handleSubagentStart(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteSubagentStarted(sessionId: sessionId)
        }
    }

    /// SubagentStop: agent finished, parent session still running. Decrement
    /// the count so the badge disappears once all agents are done.
    private func handleSubagentStop(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteSubagentStopped(sessionId: sessionId)
        }
    }

    /// Dedicated TaskCreated / TaskCompleted hook events — the primary feed for
    /// the per-session progress meter. One event fires per task, so batch
    /// TaskCreate calls (which the PostToolUse path under-counts) are handled
    /// correctly here. The forwarding script casts a wide net over candidate
    /// id/subject field names since these payloads aren't documented.
    private func handleTask(payload: [String: Any]) {
        let event = (payload["event"] as? String) ?? ""
        let taskId = (payload["task_id"] as? String) ?? ""
        let subject = (payload["subject"] as? String) ?? ""
        let sessionId = (payload["session_id"] as? String) ?? ""
        guard !taskId.isEmpty else { return }
        Task { @MainActor [weak state] in
            switch event {
            case "TaskCreated":   state?.noteTaskCreated(id: taskId, subject: subject, sessionId: sessionId)
            case "TaskCompleted": state?.noteTaskCompleted(id: taskId, sessionId: sessionId)
            default:              break
            }
        }
    }

    private func handlePrompt(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        Task { @MainActor [weak state] in
            let prompt = (payload["prompt"] as? String) ?? ""
            state?.noteUserPrompt(prompt, sessionId: sessionId)
        }
    }

    // MARK: - Handlers

    private func handleNotification(payload: [String: Any]) {
        let notice = AgentNotice.classify(payload)
        let sessionId = (payload["session_id"] as? String) ?? ""
        Task { @MainActor [weak state] in
            guard let state else { return }
            // A background agent that needs input is stuck, and it has no terminal
            // to be stuck in front of. Say which agent, say what it was asked to
            // do, and let the card open it.
            if let notice {
                state.noteAgentNotice(notice, sessionId: sessionId)
            }
            let msg = (payload["message"] as? String)
                ?? (payload["title"] as? String)
                ?? "Claude needs your attention"
            let detail = (payload["detail"] as? String) ?? detailFromHookPayload(payload)
            let source = (payload["source"] as? String) ?? "Claude Code"
            let frontBID = Self.capturedOriginator(state: state)
            let req = PermissionRequest(
                kind: .notification,
                title: notice == .needsInput ? "Background agent needs you" : msg,
                detail: detail,
                toolName: "Notification",
                source: source,
                cwd: (payload["cwd"] as? String) ?? "",
                originatorBundleID: frontBID,
                resolver: { _, _ in }
            )
            state.enqueuePermission(req)
        }
    }

    private func handleStop(payload: [String: Any]) {
        let path = (payload["transcript_path"] as? String) ?? ""
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""

        // Stop fires BEFORE Claude's final assistant message is necessarily
        // flushed to disk. Read now + at +300/+800ms — whichever finds newer
        // content wins (noteClaudeResponse is idempotent).
        if !path.isEmpty {
            readAndPushClaudeResponse(transcriptPath: path, sessionId: sessionId)
            workQueue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                self?.readAndPushClaudeResponse(transcriptPath: path, sessionId: sessionId)
            }
            workQueue.asyncAfter(deadline: .now() + .milliseconds(800)) { [weak self] in
                self?.readAndPushClaudeResponse(transcriptPath: path, sessionId: sessionId)
            }
            // Turn ended: recompute the context/cost meter unthrottled so the
            // final numbers are accurate. Slight delay so the last turn's usage
            // is on disk.
            workQueue.asyncAfter(deadline: .now() + .milliseconds(900)) { [weak self] in
                self?.pushSessionMeter(transcriptPath: path, sessionId: sessionId)
            }
            // Judge the turn only once its closing message is actually on disk.
            // The card goes up immediately below, because waiting a second to
            // tell someone their task finished is worse than a verdict that
            // arrives a beat later. Auditing at Stop time instead would read
            // whatever response was there before, which is the previous turn's.
            workQueue.asyncAfter(deadline: .now() + .milliseconds(950)) { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak state = self.state] in
                    state?.auditLatestCompleted(sessionId: sessionId, cwd: cwd)
                }
            }
        }

        Task { @MainActor [weak state] in
            guard let state else { return }
            state.markSessionDone(cwd: cwd, sessionId: sessionId)
            // Name the agent that actually ran (and the user's custom title when
            // they set one) — a Codex turn must not report "Claude finished".
            let agent = state.sessionAgent(sessionId: sessionId, cwd: cwd)
            let entity = state.completionEntityName(sessionId: sessionId, cwd: cwd)
            let title = (payload["title"] as? String) ?? "\(entity) finished"
            let detail = (payload["detail"] as? String) ?? detailFromHookPayload(payload)
            let source = (payload["source"] as? String) ?? agent.displayName
            let frontBID = Self.capturedOriginator(state: state)
            let task = CompletedTask(
                title: title,
                detail: detail,
                source: source,
                cwd: (payload["cwd"] as? String) ?? "",
                originatorBundleID: frontBID,
                entityName: entity
            )
            state.enqueueCompleted(task)
        }
    }

    /// StopFailure hook: the turn died from an API-level error (rate limit,
    /// overloaded, billing…). The terminal shows it, but the user who walked
    /// away has no idea their long task stopped — alert loudly.
    private func handleStopFailure(payload: [String: Any]) {
        let reasonKey = (payload["failure_reason"] as? String)
            ?? (payload["reason"] as? String)
            ?? (payload["error_type"] as? String)
            ?? (payload["matcher"] as? String)
            ?? "unknown"
        // Claude Code often sends the reason code back as the message, so the
        // card would read "invalid_request" at the user twice over. A bare code
        // is not a message; say what it means instead.
        let rawDetail = (payload["message"] as? String)
            ?? (payload["error"] as? String)
            ?? ""
        let detail = Self.failureDetail(reason: reasonKey, message: rawDetail)
        let title: String
        switch reasonKey {
        case "rate_limit":            title = "Rate limited, session stopped"
        case "overloaded":            title = "Servers overloaded, session stopped"
        case "authentication_failed": title = "Authentication failed"
        case "oauth_org_not_allowed": title = "Org not allowed, auth error"
        case "billing_error":         title = "Billing error, session stopped"
        case "invalid_request":       title = "Invalid request, session stopped"
        case "model_not_found":       title = "Model not found"
        case "server_error":          title = "Server error, session stopped"
        case "max_output_tokens":     title = "Hit max output tokens"
        default:                      title = "Session stopped on an error"
        }
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        Task { @MainActor [weak state] in
            guard let state else { return }
            // Running out of usage stopped being a failure in Claude Code
            // 2.1.234: it waits for the reset and carries on by itself. A red
            // "session stopped on an error" card is now the wrong story, and
            // the right one has a time in it.
            if UsageLimitPause.isLimitStop(reason: reasonKey) {
                state.notePausedByUsageLimit(sessionId: sessionId, cwd: cwd)
                return
            }
            state.noteStopFailure(reason: reasonKey, title: title, detail: detail,
                                  cwd: cwd, sessionId: sessionId)
        }
    }

    /// What to actually put in front of the user for a failed turn.
    ///
    /// The hook's `message` is preferred, because when it is a real sentence it
    /// is more specific than anything guessable here. But it frequently is just
    /// the reason code repeated, which tells the user nothing they can act on
    /// and reads like the app leaking its own internals. A bare
    /// `snake_case_token` is treated as no message at all.
    nonisolated static func failureDetail(reason: String, message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBareCode = trimmed.isEmpty
            || trimmed.caseInsensitiveCompare(reason) == .orderedSame
            || (!trimmed.contains(" ")
                && trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz_").inverted) == nil)
        guard isBareCode else { return trimmed }
        switch reason {
        case "rate_limit":
            return "You have hit the usage limit. It will lift on its own."
        case "overloaded":
            return "Anthropic's servers are busy. Try the turn again in a moment."
        case "authentication_failed":
            return "Your login is no longer valid. Run /login in the terminal."
        case "oauth_org_not_allowed":
            return "Your organisation does not allow this account here."
        case "billing_error":
            return "The account cannot be billed right now. Check your plan or credits."
        case "invalid_request":
            return "Claude Code sent a request the API refused. Usually the conversation outgrew the context window."
        case "model_not_found":
            return "That model is not available on your account."
        case "server_error":
            return "Something went wrong on Anthropic's side. The turn did not finish."
        case "max_output_tokens":
            return "The reply hit its length limit and was cut off."
        default:
            return "The turn stopped before it finished."
        }
    }

    /// SessionStart hook: a session opened (startup / resume / clear /
    /// compact). recordSessionMetadata already created the LiveSession; this
    /// adds what only SessionStart knows — the model id before any transcript
    /// exists, and the session title if one is set.
    private func handleSessionStart(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        let model = (payload["model"] as? String) ?? ""
        let title = (payload["session_title"] as? String) ?? ""
        let source = (payload["source"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteSessionStart(sessionId: sessionId, cwd: cwd,
                                    model: model, title: title, source: source)
        }
    }

    /// DirectoryAdded hook: a directory was granted to a running session via
    /// `/add-dir` or the SDK's register_repo_root.
    ///
    /// Worth showing because it widens what the session may touch, after you
    /// decided what it could touch. The hook cannot block it — it fires after
    /// the fact — so this is a record, not a gate.
    ///
    /// CwdChanged hook: Claude ran `cd`, so a session moved. Carries `old_cwd`
    /// and `new_cwd`.
    /// A named teammate in this session's team has stopped and is idle.
    ///
    /// The payload carries `teammate_name` on top of the common fields, plus a
    /// `team_name` the CLI already marks deprecated, which is why it is not
    /// read here.
    ///
    /// Answered with a plain OK. This event can carry a decision that keeps the
    /// teammate working, and the notch has no business making that call: it
    /// reports, it does not steer somebody else's agent.
    private func handleTeammateIdle(payload: [String: Any]) {
        let name = (payload["teammate_name"] as? String) ?? ""
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteTeammateIdle(name: name, sessionId: sessionId, cwd: cwd)
        }
    }

    /// A worktree was created. The payload carries `name`, not a path: the two
    /// worktree events are not symmetric, which is verified against the CLI's
    /// own schema rather than assumed. `worktree_path` is read as a fallback so
    /// a future CLI that does send one is not ignored.
    private func handleWorktreeCreate(payload: [String: Any]) {
        let name = (payload["name"] as? String) ?? ""
        let path = (payload["worktree_path"] as? String) ?? ""
        guard !name.isEmpty || !path.isEmpty else { return }
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteWorktreeCreated(name: name.isEmpty ? (path as NSString).lastPathComponent : name,
                                       sessionId: sessionId, cwd: cwd)
        }
    }

    /// A worktree was removed. This one carries `worktree_path`.
    private func handleWorktreeRemove(payload: [String: Any]) {
        let path = (payload["worktree_path"] as? String) ?? (payload["name"] as? String) ?? ""
        guard !path.isEmpty else { return }
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteWorktreeRemoved(path: path, sessionId: sessionId, cwd: cwd)
        }
    }

    private func handleCwdChanged(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        let oldCwd = (payload["old_cwd"] as? String) ?? ""
        let newCwd = (payload["new_cwd"] as? String) ?? ""
        guard !newCwd.isEmpty else { return }
        Task { @MainActor [weak state] in
            state?.noteCwdChanged(sessionId: sessionId, oldCwd: oldCwd, newCwd: newCwd)
        }
    }

    /// The payload carries `directory_path` and `how_added` (`slash_command`
    /// or `register_repo_root`) on top of the common fields.
    /// The sandbox refused something during a tool call. Claude Code puts the
    /// details in the tool result, so this rides the PostToolUse payload the
    /// app already receives rather than needing a hook of its own.
    private func handleSandboxViolations(payload: [String: Any]) {
        let items = SandboxViolationParser.violations(in: payload["tool_response"])
        guard !items.isEmpty else { return }
        let toolName = (payload["tool_name"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        let sessionId = (payload["session_id"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteSandboxViolations(items, toolName: toolName, cwd: cwd, sessionId: sessionId)
        }
    }

    /// A settings file changed mid-session. `source` says which tier
    /// (user / project / local / policy / skills), `file_path` is optional.
    private func handleConfigChange(payload: [String: Any]) {
        let source = (payload["source"] as? String) ?? ""
        let filePath = (payload["file_path"] as? String)
            ?? (payload["filePath"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteConfigChanged(source: source, filePath: filePath)
        }
    }

    /// Auto mode denied a tool call. The payload carries `tool_name`,
    /// `tool_input`, `tool_use_id` and `reason`.
    private func handlePermissionDenied(payload: [String: Any]) {
        let toolName = (payload["tool_name"] as? String) ?? "tool"
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let cwd = (payload["cwd"] as? String) ?? ""
        let sessionId = (payload["session_id"] as? String) ?? ""
        let reason = Self.denialReason(from: payload)
        let title = humanTitle(for: toolName)
        let detail = enrichedDetail(for: toolName, input: toolInput)
        Task { @MainActor [weak state] in
            state?.noteAutoDenied(toolName: toolName, title: title, detail: detail,
                                  cwd: cwd, reason: reason, sessionId: sessionId)
        }
    }

    /// Why the call was blocked. `reason` is the documented field; the rest are
    /// fallbacks, kept for the same reason as DirectoryAdded's — this arrives
    /// from a CLI that ships faster than its reference, and a renamed key
    /// should degrade to a card with no reason, not to no card.
    ///
    /// Truncated: it is model-authored text of unbounded length, and it renders
    /// in a card two lines tall.
    nonisolated static func denialReason(from payload: [String: Any]) -> String {
        for key in ["reason", "denial_reason", "message", "permissionDecisionReason",
                    "decision_reason", "denialReason"] {
            if let v = payload[key] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let clean = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                return String(SecretRedactor.redact(clean).prefix(240))
            }
        }
        return ""
    }

    private func handleDirectoryAdded(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        let dir = Self.addedDirectory(from: payload)
        if dir.isEmpty {
            DebugLog.append("hook", "DirectoryAdded: no directory in payload, keys=\(payload.keys.sorted())")
        }
        let how = Self.addedDirectoryHow(from: payload)
        Task { @MainActor [weak state] in
            state?.noteDirectoryAdded(sessionId: sessionId, cwd: cwd,
                                      directory: dir, how: how)
        }
    }

    /// The added path out of a DirectoryAdded payload. `directory_path` is the
    /// documented field; the rest are fallbacks, kept because this arrives from
    /// a CLI that ships faster than its reference, and a renamed key would
    /// otherwise fail silently rather than loudly.
    nonisolated static func addedDirectory(from payload: [String: Any]) -> String {
        for key in ["directory_path", "directory", "path", "added_directory",
                    "dir", "addedDirectory", "directoryPath"] {
            if let v = payload[key] as? String, !v.isEmpty { return v }
        }
        return ""
    }

    /// How the directory was granted. `/add-dir` is someone deciding to widen
    /// the session; `register_repo_root` is the SDK doing it as a matter of
    /// course, which is worth distinguishing in the record.
    nonisolated static func addedDirectoryHow(from payload: [String: Any]) -> String {
        switch (payload["how_added"] as? String) ?? "" {
        case "slash_command":      return "/add-dir"
        case "register_repo_root": return "SDK repo root"
        case let other where !other.isEmpty: return other
        default:                   return ""
        }
    }

    /// SessionEnd hook (Ctrl+C / Ctrl+D / exit): the session is gone, so stop
    /// polling its transcript and drop it from the notch immediately.
    private func handleSessionEnd(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        if let path = (payload["transcript_path"] as? String), !path.isEmpty {
            cancelPolling(transcriptPath: path)
        }
        Task { @MainActor [weak state] in
            state?.clearToolRepeats(sessionId: sessionId, cwd: cwd)
            state?.removeSession(sessionId: sessionId, cwd: cwd)
        }
    }

    /// Stop any in-flight poll loop for a transcript path (its next tick sees a
    /// missing token and bails) so an ended session can't be resurrected.
    private func cancelPolling(transcriptPath path: String) {
        transcriptPollLock.withLock {
            transcriptPollTokens[path] = nil
        }
    }

    /// Read the transcript and push the latest assistant text into state.
    /// Safe to call from any queue.
    private func readAndPushClaudeResponse(transcriptPath path: String, sessionId: String = "") {
        guard let text = lastAssistantText(fromTranscriptAt: path) else { return }
        Task { @MainActor [weak state] in
            state?.noteClaudeResponse(text, sessionId: sessionId)
        }
    }

    private func startResponsePolling(transcriptPath path: String, sessionId: String = "", duration: TimeInterval, delayFirstRead: Bool = false) {
        // A payload-supplied path outside the transcript roots is never read, so
        // don't spin a poll loop over it either.
        guard EventServer.isAllowedTranscriptPath(path) else { return }
        let token = transcriptPollLock.withLock { () -> Int in
            let next = (transcriptPollTokens[path] ?? 0) + 1
            transcriptPollTokens[path] = next
            return next
        }
        let deadline = Date().addingTimeInterval(duration)
        if delayFirstRead {
            workQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                guard let self else { return }
                let isCurrent = self.transcriptPollLock.withLock {
                    self.transcriptPollTokens[path] == token
                }
                guard isCurrent else { return }
                self.pollTranscript(path: path, sessionId: sessionId, token: token, until: deadline)
            }
        } else {
            pollTranscript(path: path, sessionId: sessionId, token: token, until: deadline)
        }
    }

    private func transcriptGrew(path: String) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? nil
        guard let size else { return true }   // cannot tell: do the work
        return transcriptPollLock.withLock {
            let previous = transcriptSizes[path]
            transcriptSizes[path] = size
            return previous != size
        }
    }

    private func pollTranscript(path: String, sessionId: String, token: Int, until deadline: Date) {
        // Polling runs for five minutes after a prompt, and a turn is usually
        // over long before that: the rest of the window was spent re-reading and
        // re-parsing half a megabyte, twice, every 700ms, to discover the file
        // had not changed. A transcript is append-only, so its size answers that
        // for the price of a stat.
        guard transcriptGrew(path: path) else {
            scheduleNextPoll(path: path, sessionId: sessionId, token: token, until: deadline)
            return
        }
        readAndPushClaudeResponse(transcriptPath: path, sessionId: sessionId)
        // Refresh task progress from the transcript (the source of truth), so
        // the notch bar stays accurate mid-task and recovers even if a TodoWrite
        // hook was missed (e.g. the app restarted while a turn ran).
        if let todos = latestTodos(fromTranscriptAt: path) {
            Task { @MainActor [weak state] in
                state?.noteTodos(total: todos.total, done: todos.done, sessionId: sessionId)
            }
        }
        scheduleNextPoll(path: path, sessionId: sessionId, token: token, until: deadline)
    }

    private func scheduleNextPoll(path: String, sessionId: String, token: Int, until deadline: Date) {
        guard Date() < deadline else { finishPolling(path: path, token: token); return }
        workQueue.asyncAfter(deadline: .now() + .milliseconds(700)) { [weak self] in
            guard let self else { return }
            let isCurrent = self.transcriptPollLock.withLock {
                self.transcriptPollTokens[path] == token
            }
            guard isCurrent else { return }
            self.pollTranscript(path: path, sessionId: sessionId, token: token, until: deadline)
        }
    }

    /// Drop a transcript's poll token once its loop ends, but only if it is
    /// still the current generation — otherwise a newer poll has taken over and
    /// owns the entry. Keeps `transcriptPollTokens` from growing unbounded.
    private func finishPolling(path: String, token: Int) {
        transcriptPollLock.withLock {
            if transcriptPollTokens[path] == token {
                transcriptPollTokens[path] = nil
            }
        }
    }

    /// Scan the transcript tail for the most recent TodoWrite tool call and
    /// return its (total, completed) counts. The transcript is the source of
    /// truth for the task list, so this keeps the notch bar right even when a
    /// hook was missed. Returns nil if no TodoWrite is found in the tail.
    private func latestTodos(fromTranscriptAt path: String) -> (total: Int, done: Int)? {
        guard EventServer.isAllowedTranscriptPath(path),
              let body = FileSlice.tail(URL(fileURLWithPath: path), bytes: 512 * 1024) else { return nil }
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let d = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let inner = (obj["message"] as? [String: Any]) ?? obj
            guard let blocks = inner["content"] as? [[String: Any]] else { continue }
            for b in blocks where (b["type"] as? String) == "tool_use" && (b["name"] as? String) == "TodoWrite" {
                guard let input = b["input"] as? [String: Any],
                      let todos = input["todos"] as? [[String: Any]], !todos.isEmpty else { continue }
                let done = todos.filter { ($0["status"] as? String) == "completed" }.count
                return (todos.count, done)
            }
        }
        return nil
    }

    /// Tail the JSONL transcript and pull the most recent assistant text
    /// content. Tolerant of multiple message shapes Claude Code emits.
    private func lastAssistantText(fromTranscriptAt path: String) -> String? {
        guard EventServer.isAllowedTranscriptPath(path) else {
            debugLog("transcript read: REFUSED out-of-root path")
            return nil
        }
        debugLog("transcript read: \(path)")
        guard let body = FileSlice.tail(URL(fileURLWithPath: path), bytes: 512 * 1024) else {
            debugLog("transcript read: FAILED to open file")
            return nil
        }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
        debugLog("transcript read: \(lines.count) lines")
        for raw in lines.reversed() {
            guard let lineData = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            let inner = (obj["message"] as? [String: Any]) ?? obj
            let role = (inner["role"] as? String) ?? (obj["type"] as? String) ?? ""
            guard role == "assistant" else { continue }

            if let text = (inner["content"] as? String), !text.isEmpty {
                debugLog("transcript read: found text shape A (\(text.count) chars)")
                return text
            }
            if let blocks = inner["content"] as? [[String: Any]] {
                let texts = blocks.compactMap { b -> String? in
                    if let t = b["text"] as? String, !t.isEmpty { return t }
                    return nil
                }
                if !texts.isEmpty {
                    let joined = texts.joined(separator: "\n\n")
                    debugLog("transcript read: found text shape B (\(joined.count) chars)")
                    return joined
                }
            }
        }
        debugLog("transcript read: no assistant text found in \(lines.count) lines")
        return nil
    }

    private func debugLog(_ msg: String) { DebugLog.append("server", msg) }

    /// PreToolUse: tool was just approved and is now executing. Update the
    /// activity strip live so the user sees what's running while it runs.
    private func handlePreTool(payload: [String: Any]) {
        let tool = (payload["tool_name"] as? String) ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let sessionId = (payload["session_id"] as? String) ?? ""
        guard !tool.isEmpty else { return }
        let cwd = (payload["cwd"] as? String) ?? ""
        Task { @MainActor [weak state] in
            guard let state else { return }
            let detail = self.enrichedDetail(for: tool, input: input)
            let label = detail.isEmpty ? tool : "\(tool): \(detail)"
            state.noteActivity(String(label.prefix(80)), sessionId: sessionId)
            // Counted here rather than on PostToolUse so a session stuck
            // retrying the same call shows up as it starts, and still counts
            // when a call never returns at all.
            state.noteToolRepeat(tool: tool, input: input, sessionId: sessionId, cwd: cwd)
        }
    }

    /// External-agent tool start (e.g. Codex). Purely informational: pop a brief
    /// "running" card and return an empty body. We deliberately do NOT gate
    /// permission here: Codex runs its own approval prompt for risky commands,
    /// and a hook can only veto (never auto-approve), so mirroring it would just
    /// double-prompt. Codex owns permission; ClaudeNotch surfaces and observes.
    private func handleExternalPreTool(payload: [String: Any], on conn: HookConnection) {
        let tool = (payload["tool_name"] as? String) ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let sessionId = (payload["session_id"] as? String) ?? ""
        guard !tool.isEmpty else { send(body: "", on: conn); return }
        let detail = enrichedDetail(for: tool, input: input)
        // Risky commands are the ones Codex will prompt for, so flag the card as
        // "needs your approval" to nudge the user to the terminal. We never gate.
        let dangers = ToolPreviewParser.dangerReasons(for: tool, input: input)
        let needsApproval = !dangers.isEmpty
        Task { @MainActor [weak state] in
            state?.noteExternalActivity(tool: tool, detail: detail,
                                        needsApproval: needsApproval, dangerReasons: dangers,
                                        sessionId: sessionId)
        }
        send(body: "", on: conn)
    }

    /// PostToolUse: tool finished, Claude is now reasoning between actions.
    /// Clears the command strip and shows "thinking" until the next tool starts.
    private func handlePostToolThinking(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteThinkingBetweenTools(sessionId: sessionId)
        }
    }

    /// Build the tool-permission card for a PreToolUse gate. One definition of
    /// how a Bash/Edit/... approval is presented — title, human detail, preview,
    /// danger flags, originating app — shared by the script-hook and native-HTTP
    /// permission paths. @MainActor because the originator capture is.
    @MainActor
    private func makeToolPermissionRequest(
        toolName: String, toolInput: [String: Any], cwd: String,
        resolver: @escaping (PermissionDecision, String?) -> Void
    ) -> PermissionRequest {
        PermissionRequest(
            kind: .toolUse,
            title: humanTitle(for: toolName),
            detail: enrichedDetail(for: toolName, input: toolInput),
            toolName: toolName,
            source: "Claude Code",
            cwd: cwd,
            originatorBundleID: Self.capturedOriginator(state: state),
            preview: ToolPreviewParser.preview(for: toolName, input: toolInput),
            dangerReasons: ToolPreviewParser.dangerReasons(for: toolName, input: toolInput),
            resolver: resolver
        )
    }

    private func handleBlockingPermission(payload: [String: Any], on conn: HookConnection) {
        let toolName = (payload["tool_name"] as? String) ?? "tool"
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let cwd = (payload["cwd"] as? String) ?? ""

        let pending = PendingAnswer(conn: conn, queue: workQueue,
                                    timeout: Self.decisionWindow) {
            Self.legacyDecisionBody(.ask, reason: nil)
        }

        Task { @MainActor [weak self] in
            guard let self, let state = self.state else {
                pending.answer(Self.legacyDecisionBody(.ask, reason: nil))
                return
            }
            state.enqueuePermission(self.makeToolPermissionRequest(
                toolName: toolName, toolInput: toolInput, cwd: cwd
            ) { decision, reason in
                pending.answer(Self.legacyDecisionBody(decision, reason: reason))
            })
        }
    }

    /// The wire the script hook reads: `{decision, reason}`. Built with
    /// JSONSerialization so a free-text reason is escaped;
    /// claudenotch-permission.sh forwards `reason` as the
    /// permissionDecisionReason on a deny.
    nonisolated static func legacyDecisionBody(_ decision: PermissionDecision,
                                               reason: String?) -> String {
        var dict: [String: Any] = ["decision": decision.rawValue]
        if decision == .deny, let reason, !reason.isEmpty { dict["reason"] = reason }
        return (try? JSONSerialization.data(withJSONObject: dict))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"decision\":\"\(decision.rawValue)\"}"
    }

    /// Parse an AskUserQuestion payload into `AskQuestion`s. Accepts either
    /// Claude Code's full PreToolUse JSON (tool_input.questions) or our own shape
    /// ({questions: [...]}). Pure and `static` so it's the one, unit-testable
    /// definition shared by the script-hook and native-HTTP question handlers.
    static func parseQuestions(from payload: [String: Any]) -> [AskQuestion] {
        let raw: [[String: Any]] = {
            if let qs = payload["questions"] as? [[String: Any]] { return qs }
            if let ti = payload["tool_input"] as? [String: Any],
               let qs = ti["questions"] as? [[String: Any]] { return qs }
            return []
        }()
        return raw.compactMap { dict in
            guard let q = dict["question"] as? String else { return nil }
            let options: [AskOption] = ((dict["options"] as? [[String: Any]]) ?? []).compactMap { o in
                guard let label = o["label"] as? String else { return nil }
                return AskOption(label: label, description: (o["description"] as? String) ?? "")
            }
            guard !options.isEmpty else { return nil }
            return AskQuestion(header: (dict["header"] as? String) ?? "", text: q,
                               multiSelect: (dict["multiSelect"] as? Bool) ?? false, options: options)
        }
    }

    private func handleBlockingQuestion(payload: [String: Any], on conn: HookConnection) {
        let cwd = (payload["cwd"] as? String) ?? ""
        let parsed = EventServer.parseQuestions(from: payload)

        guard !parsed.isEmpty else {
            send(body: "{\"cancelled\":true,\"reason\":\"no questions parsed\"}", on: conn)
            return
        }

        let pending = PendingAnswer(conn: conn, queue: workQueue,
                                    timeout: Self.decisionWindow) {
            "{\"cancelled\":true,\"reason\":\"timeout\"}"
        }

        Task { @MainActor [weak state] in
            guard let state else {
                pending.answer("{\"cancelled\":true,\"reason\":\"no state\"}")
                return
            }
            let frontBID = Self.capturedOriginator(state: state)
            state.enqueueQuestion(QuestionRequest(
                questions: parsed, source: "Claude Code", cwd: cwd,
                originatorBundleID: frontBID,
                resolver: { ans in
                    pending.answer(Self.legacyAnswersBody(questions: parsed, answers: ans))
                }
            ))
        }
    }

    /// The wire the script hook reads for a question.
    ///
    /// Always fed back as the hook's deny reason so Claude Code never renders
    /// its own blocking prompt in the terminal. We used to optionally return
    /// allow plus AppleScript keystrokes, which left the terminal waiting for
    /// input whenever the keystroke mis-timed or the wrong app had focus.
    nonisolated static func legacyAnswersBody(questions: [AskQuestion],
                                              answers: [[String]]?) -> String {
        guard let answers else { return "{\"cancelled\":true,\"reason\":\"user dismissed\"}" }
        let pairs = zip(questions, answers).map { q, picks -> [String: Any] in
            ["question": q.text, "header": q.header, "picked": picks]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["mode": "deny", "answers": pairs]),
              let body = String(data: data, encoding: .utf8)
        else { return "{\"cancelled\":true,\"reason\":\"encode failed\"}" }
        return body
    }

    // MARK: - HTTP hook unified endpoint

    /// Single entry point for native HTTP hooks (`"type": "http"` in settings.json).
    /// Claude Code POSTs the full event JSON here; we return hookSpecificOutput directly
    /// instead of relying on the shell-script intermediaries to format it.
    private func handleUnifiedHook(payload: [String: Any], on conn: HookConnection) {
        let eventName = (payload["hook_event_name"] as? String) ?? ""
        let toolName  = (payload["tool_name"] as? String) ?? ""

        switch eventName {
        case "PreToolUse":
            switch toolName {
            case "Grep", "Glob", "LS", "BashOutput", "KillShell":
                sendHookOutput(["hookSpecificOutput": ["hookEventName": "PreToolUse",
                                                       "permissionDecision": "ask"]], on: conn)
            case "AskUserQuestion":
                handleBlockingQuestionHTTP(payload: payload, on: conn)
            default:
                handleBlockingPermissionHTTP(payload: payload, on: conn)
            }
        case "PermissionRequest":
            handleBlockingPermReqHTTP(payload: payload, on: conn)
        case "PermissionDenied":
            handlePermissionDenied(payload: payload)
            // Plain OK. The hook may answer `{retry: true}` to tell the model
            // to try again — the notch reports what happened, it does not
            // overrule the classifier that blocked it.
            sendOK(on: conn)
        case "FileChanged":
            handleFileChanged(payload: payload)
            sendOK(on: conn)
        case "InstructionsLoaded":
            handleInstructionsLoaded(payload: payload)
            sendOK(on: conn)
        case "PostToolUseFailure":
            handleToolFailure(payload: payload)
            sendOK(on: conn)
        case "PostToolUse":
            handleToolSucceeded(payload: payload)
            handleActivity(payload: payload)
            handlePostToolThinking(payload: payload)
            handleSandboxViolations(payload: payload)
            handleAgentBudgets(payload: payload)
            sendOK(on: conn)
        case "UserPromptSubmit":
            handlePrompt(payload: payload)
            sendOK(on: conn)
        case "Notification":
            handleNotification(payload: payload)
            sendOK(on: conn)
        case "Stop":
            handleStop(payload: payload)
            sendOK(on: conn)
        case "StopFailure":
            handleStopFailure(payload: payload)
            sendOK(on: conn)
        case "SubagentStart":
            handleSubagentStart(payload: payload)
            sendOK(on: conn)
        case "SubagentStop":
            handleSubagentStop(payload: payload)
            sendOK(on: conn)
        case "DirectoryAdded":
            handleDirectoryAdded(payload: payload)
            sendOK(on: conn)
        case "CwdChanged":
            handleCwdChanged(payload: payload)
            sendOK(on: conn)
        case "TeammateIdle":
            handleTeammateIdle(payload: payload)
            sendOK(on: conn)
        case "WorktreeCreate":
            handleWorktreeCreate(payload: payload)
            sendOK(on: conn)
        case "WorktreeRemove":
            handleWorktreeRemove(payload: payload)
            sendOK(on: conn)
        case "SessionStart":
            handleSessionStart(payload: payload)
            sendOK(on: conn)
        case "SessionEnd":
            handleSessionEnd(payload: payload)
            sendOK(on: conn)
        case "TaskCreated", "TaskCompleted":
            var norm = payload
            let tid = (payload["task_id"] as? String)
                ?? (payload["taskId"] as? String)
                ?? (payload["id"] as? String)
                ?? ""
            let sub = (payload["task_subject"] as? String)
                ?? (payload["subject"] as? String)
                ?? (payload["title"] as? String)
                ?? (payload["task_description"] as? String)
                ?? (payload["description"] as? String)
                ?? ""
            norm["event"] = eventName
            norm["task_id"] = tid
            norm["subject"] = sub
            handleTask(payload: norm)
            sendOK(on: conn)
        case "PreCompact":
            handleCompact(payload: payload)
            sendOK(on: conn)
        case "PostCompact":
            handlePostCompact(payload: payload)
            sendOK(on: conn)
        case "Elicitation":
            // Blocking: this one sends its own response.
            handleElicitationHTTP(payload: payload, on: conn)
        case "ElicitationResult":
            handleElicitationResult(payload: payload)
            sendOK(on: conn)
        case "ConfigChange":
            handleConfigChange(payload: payload)
            // Plain OK: this hook can BLOCK a settings change by answering
            // `{blocked: true}`. The notch reports, it does not veto — and a
            // crash or a timeout here must never be able to stop the user
            // editing their own settings.
            sendOK(on: conn)
        default:
            sendOK(on: conn)
        }
    }

    /// How long a card may sit unanswered before the hook is let go.
    ///
    /// Matches the 3-minute "waiting on you" nudge plus room, and must stay
    /// under the 290s the installed hook entry allows, or Claude Code gives up
    /// on us and prompts in the terminal while the card is still on screen.
    static let decisionWindow: TimeInterval = 285

    /// Shared path: put a permission card up, and answer the connection when it
    /// resolves or when the window closes, whichever happens first.
    ///
    /// Nothing waits. This used to park a queue thread on a semaphore for the
    /// whole window; see PendingAnswer for why that does not scale past the
    /// number of cards the app is willing to queue.
    private func decidePermission(toolName: String, toolInput: [String: Any],
                                  cwd: String, on conn: HookConnection,
                                  reply: @escaping (PermissionDecision, String?) -> String) {
        let pending = PendingAnswer(conn: conn, queue: workQueue,
                                    timeout: Self.decisionWindow) {
            // Nobody answered: say nothing rather than deciding for them.
            reply(.ask, nil)
        }
        Task { @MainActor [weak self] in
            guard let self, let state = self.state else {
                pending.answer(reply(.ask, nil))
                return
            }
            state.enqueuePermission(self.makeToolPermissionRequest(
                toolName: toolName, toolInput: toolInput, cwd: cwd
            ) { decision, reason in
                pending.answer(reply(decision, reason))
            })
        }
    }

    /// PreToolUse via HTTP hook: returns hookSpecificOutput with permissionDecision.
    private func handleBlockingPermissionHTTP(payload: [String: Any], on conn: HookConnection) {
        let toolName  = (payload["tool_name"]  as? String)        ?? "tool"
        let toolInput = (payload["tool_input"] as? [String: Any]) ?? [:]
        let cwd       = (payload["cwd"]        as? String)        ?? ""
        decidePermission(toolName: toolName, toolInput: toolInput, cwd: cwd, on: conn) { final, reason in
            var inner: [String: Any] = ["hookEventName": "PreToolUse", "permissionDecision": final.rawValue]
            if final == .deny, let r = reason, !r.isEmpty { inner["permissionDecisionReason"] = String(r.prefix(200)) }
            return Self.jsonBody(["hookSpecificOutput": inner])
        }
    }

    /// PermissionRequest via HTTP hook: returns hookSpecificOutput with decision.behavior.
    private func handleBlockingPermReqHTTP(payload: [String: Any], on conn: HookConnection) {
        let toolName  = (payload["tool_name"]  as? String)        ?? "tool"
        let toolInput = (payload["tool_input"] as? [String: Any]) ?? [:]
        let cwd       = (payload["cwd"]        as? String)        ?? ""
        decidePermission(toolName: toolName, toolInput: toolInput, cwd: cwd, on: conn) { final, _ in
            guard final != .ask else { return Self.okBody }
            let behavior = (final == .allow) ? "allow" : "deny"
            return Self.jsonBody(["hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": behavior],
            ]])
        }
    }

    /// Elicitation via HTTP hook: an MCP server is asking the user something
    /// mid-tool-call. Answer it in the notch and hand the answer back.
    ///
    /// A bare OK means "no opinion", and Claude Code then asks in the terminal
    /// exactly as it would have. That is the reply for everything this card
    /// cannot answer faithfully: a URL flow, a free-text field, a dismissed
    /// card, a timeout.
    private func handleElicitationHTTP(payload: [String: Any], on conn: HookConnection) {
        guard let form = ElicitationParser.form(from: payload) else { sendOK(on: conn); return }
        let cwd = (payload["cwd"] as? String) ?? ""
        let questions = form.questions
        guard !questions.isEmpty else { sendOK(on: conn); return }

        let pending = PendingAnswer(conn: conn, queue: workQueue,
                                    timeout: Self.decisionWindow) { Self.okBody }

        Task { @MainActor [weak state] in
            guard let state else { pending.answer(Self.okBody); return }
            let frontBID = Self.capturedOriginator(state: state)
            // The server's name is the source: the user is being asked by a
            // thing they installed, not by Claude, and the card should say so.
            let source = form.serverName.isEmpty ? "MCP server" : form.serverName
            state.enqueueQuestion(QuestionRequest(
                questions: questions, source: source, cwd: cwd,
                originatorBundleID: frontBID,
                elicitationId: (payload["elicitation_id"] as? String) ?? "",
                resolver: { ans in
                    guard let ans, let content = form.content(from: ans) else {
                        pending.answer(Self.okBody)   // cancelled, or not fully answered
                        return
                    }
                    pending.answer(Self.jsonBody(["hookSpecificOutput": [
                        "hookEventName": "Elicitation",
                        "action": "accept",
                        "content": content,
                    ]]))
                }
            ))
        }
    }

    /// ElicitationResult: an elicitation is over, however it ended — answered
    /// here, answered in the terminal after our hook timed out, cancelled, or
    /// abandoned when the tool call was interrupted.
    ///
    /// It is what takes down a card nobody can answer any more. Without it the
    /// card sits there for five minutes waiting on a question that no longer
    /// exists.
    private func handleElicitationResult(payload: [String: Any]) {
        let id = (payload["elicitation_id"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.dismissElicitation(id: id)
        }
    }

    /// AskUserQuestion via HTTP hook: returns hookSpecificOutput deny+reason with answers.
    private func handleBlockingQuestionHTTP(payload: [String: Any], on conn: HookConnection) {
        let cwd = (payload["cwd"] as? String) ?? ""
        let parsed = EventServer.parseQuestions(from: payload)
        guard !parsed.isEmpty else { sendOK(on: conn); return }

        let pending = PendingAnswer(conn: conn, queue: workQueue,
                                    timeout: Self.decisionWindow) { Self.okBody }

        Task { @MainActor [weak state] in
            guard let state else { pending.answer(Self.okBody); return }
            let frontBID = Self.capturedOriginator(state: state)
            state.enqueueQuestion(QuestionRequest(
                questions: parsed, source: "Claude Code", cwd: cwd,
                originatorBundleID: frontBID,
                resolver: { ans in
                    guard let ans else { pending.answer(Self.okBody); return }
                    pending.answer(Self.answersBody(questions: parsed, answers: ans))
                }
            ))
        }
    }

    /// The answers, as the deny-with-reason wire Claude Code reads them from.
    /// Pure and static so the exact text a session receives can be pinned by a
    /// test rather than only seen in a terminal.
    nonisolated static func answersBody(questions: [AskQuestion], answers: [[String]]) -> String {
        let lines = zip(questions, answers).map { q, picks -> String in
            let h = q.header.isEmpty ? q.text : q.header
            let picked = picks.filter { !$0.isEmpty }
            return picked.isEmpty ? "  - \(h): (no preference)" : "  - \(h): \(picked.joined(separator: ", "))"
        }
        let reason = "[ClaudeNotch, user replied via the notch]\n\(lines.joined(separator: "\n"))\n\nUse these answers and continue."
        return jsonBody(["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": String(reason.prefix(2000)),
        ]])
    }

    // MARK: - Response

    /// The bodies, as strings, so a path that answers later can build one
    /// without a connection in hand.
    static let okBody = "{\"ok\":true}"

    nonisolated static func jsonBody(_ dict: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: dict))
            .flatMap { String(data: $0, encoding: .utf8) } ?? okBody
    }

    private func sendOK(on conn: HookConnection) {
        send(body: "{\"ok\":true}", on: conn)
    }

    private func sendHookOutput(_ dict: [String: Any], on conn: HookConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: dict))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"ok\":true}"
        send(body: body, on: conn)
    }

    /// One response, then the socket closes. The status line and headers live
    /// in HookConnection, so there is exactly one place that writes HTTP.
    private func send(body: String, on conn: HookConnection) {
        conn.send(body: body)
    }
}

// MARK: - Formatting

func humanTitle(for tool: String) -> String {
    switch tool {
    case "Bash":         return "Run shell command"
    case "Write":        return "Write file"
    case "Edit":         return "Edit file"
    case "MultiEdit":    return "Edit file"
    case "Read":         return "Read file"
    case "NotebookEdit": return "Edit notebook"
    case "TaskUpdate":   return "Update task"
    case "TaskCreate":   return "Create task"
    case "TaskList":     return "List tasks"
    case "TaskGet":      return "Get task"
    case "TaskStop":     return "Stop task"
    case "WebFetch":     return "Fetch URL"
    case "WebSearch":    return "Search the web"
    case "Task":         return "Spawn subagent"
    case "ExitPlanMode": return "Approve plan"
    case "TodoWrite":    return "Update todos"
    case "SlashCommand": return "Run slash command"
    case "Skill":        return "Load skill"
    // Codex tool names (snake_case, different vocabulary from Claude's).
    case "shell", "local_shell", "exec", "exec_command", "unified_exec":
        return "Run shell command"
    case "write_stdin":  return "Send input to a running command"
    case "apply_patch":  return "Edit file"
    case "read_file":    return "Read file"
    case "web_search":   return "Search the web"
    case "webrun", "web.run", "web": return "Search the web"
    case "view_image":   return "View image"
    case "update_plan":  return "Update plan"
    default:             return "Run \(tool)"
    }
}

func humanDetail(for tool: String, input: [String: Any]) -> String {
    switch tool {
    case "Bash":
        return (input["command"] as? String) ?? (input["description"] as? String) ?? ""

    // MARK: Codex tools
    //
    // Codex sends `shell` with `command` as an argv ARRAY (usually
    // ["bash","-lc","<script>"]), not a string, so the plain `as? String`
    // casts above silently produce an empty detail and the card renders as a
    // bare tool name. Everything below normalizes Codex's shapes.
    case "shell", "local_shell", "exec", "exec_command", "unified_exec":
        let cmd = CodexToolInput.command(input)
        if !cmd.isEmpty { return cmd }
        return (input["justification"] as? String) ?? ""
    case "write_stdin":
        return CodexToolInput.string(input, keys: ["input", "chars", "text"])
    case "apply_patch":
        let patch = CodexToolInput.patchText(input)
        let files = CodexToolInput.patchFiles(patch)
        if files.count == 1 { return files[0] }
        if files.count > 1  { return "\(files.count) files  ·  \(files.joined(separator: ", "))" }
        return String(patch.prefix(120))
    case "read_file", "view_image":
        return CodexToolInput.string(input, keys: ["path", "file_path", "filename", "url"])
    case "web_search":
        return CodexToolInput.string(input, keys: ["query", "q", "search_query", "prompt"])
    case "webrun", "web.run", "web":
        // Codex's web tool batches actions: {"search_query":[{"q":"..."}]},
        // {"open":[{"ref_id":...,"url":...}]}, {"find":[{"pattern":...}]}.
        return CodexToolInput.webRunDetail(input)
    case "update_plan":
        let plan = (input["plan"] as? [[String: Any]]) ?? []
        let done = plan.filter { ($0["status"] as? String) == "completed" }.count
        let current = plan.first { ($0["status"] as? String) == "in_progress" }
        let step = (current?["step"] as? String) ?? (current?["content"] as? String)
        if let step, !step.isEmpty { return "\(step)  (\(done)/\(plan.count))" }
        if !plan.isEmpty { return "\(done)/\(plan.count) steps done" }
        return (input["explanation"] as? String) ?? ""
    case "Write", "Edit", "MultiEdit", "Read", "NotebookEdit":
        return (input["file_path"] as? String) ?? ""
    case "TaskUpdate":
        let subject = (input["subject"] as? String) ?? ""
        let status  = (input["status"] as? String) ?? ""
        let taskId  = (input["taskId"] as? String) ?? ""
        if !subject.isEmpty && !status.isEmpty { return "\(subject)  →  \(status)" }
        if !subject.isEmpty                    { return subject }
        if !status.isEmpty                     { return "task \(taskId) → \(status)" }
        return taskId
    case "TaskCreate":
        let subject = (input["subject"] as? String) ?? ""
        if !subject.isEmpty { return subject }
        return (input["description"] as? String) ?? ""
    case "WebFetch":
        return (input["url"] as? String) ?? (input["prompt"] as? String) ?? ""
    case "WebSearch":
        return (input["query"] as? String) ?? ""
    case "Task":
        let type = (input["subagent_type"] as? String) ?? ""
        let desc = (input["description"] as? String) ?? ""
        if !type.isEmpty && !desc.isEmpty { return "\(type): \(desc)" }
        return type.isEmpty ? desc : type
    case "ExitPlanMode":
        return (input["plan"] as? String).map { String($0.prefix(120)) } ?? ""
    case "TodoWrite":
        let todos = (input["todos"] as? [[String: Any]]) ?? []
        let inProgress = todos.filter { ($0["status"] as? String) == "in_progress" }.count
        let n = todos.count
        if n == 0 { return "no todos" }
        return inProgress > 0 ? "\(n) todos  ·  \(inProgress) in progress" : "\(n) todos"
    case "SlashCommand":
        return (input["command"] as? String) ?? ""
    case "Skill":
        let name = (input["skill"] as? String) ?? ""
        let args = (input["args"] as? String) ?? ""
        if !name.isEmpty && !args.isEmpty { return "\(name) · \(args)" }
        return name
    default:
        // Unknown tool (MCP tools, future Codex tools). Try the usual payload
        // keys, argv arrays included, before giving up on a detail line.
        let cmd = CodexToolInput.command(input)
        if !cmd.isEmpty { return cmd }
        let known = CodexToolInput.string(
            input,
            keys: ["file_path", "path", "query", "q", "url", "subject", "prompt", "description"]
        )
        return known
    }
}

/// Normalizers for Codex's tool payloads. Codex's argument shapes differ from
/// Claude's (argv arrays, patch blobs, alternate key names) and are untrusted
/// input, so everything here is defensive and returns "" rather than throwing.
enum CodexToolInput {

    /// First non-empty string value among `keys`.
    static func string(_ input: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let s = input[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return ""
    }

    /// The shell command as one readable line. Handles `command` as a string,
    /// as an argv array, and the `["bash","-lc","<script>"]` wrapper Codex uses
    /// for nearly every call (the wrapper is noise; the script is the content).
    static func command(_ input: [String: Any]) -> String {
        for key in ["command", "cmd", "argv", "command_line"] {
            if let s = input[key] as? String, !s.isEmpty { return s }
            if let parts = input[key] as? [String] {
                return join(argv: parts)
            }
            if let anys = input[key] as? [Any] {
                let parts = anys.compactMap { $0 as? String }
                if !parts.isEmpty { return join(argv: parts) }
            }
        }
        return ""
    }

    /// `["bash","-lc","git status"]` → `git status`; anything else → the argv
    /// joined by spaces.
    static func join(argv: [String]) -> String {
        if argv.count >= 3, ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"].contains(argv[0]),
           argv[1].hasPrefix("-"), argv[1].contains("c") {
            return argv.dropFirst(2).joined(separator: " ")
        }
        return argv.joined(separator: " ")
    }

    /// The raw patch text of an `apply_patch` call, whichever key carries it.
    /// Codex 0.145 puts the whole `*** Begin Patch` envelope under `command`.
    static func patchText(_ input: [String: Any]) -> String {
        string(input, keys: ["command", "input", "patch", "diff", "content", "changes"])
    }

    /// One line for a `webrun` call. Its arguments are arrays of action
    /// objects, one array per action kind, e.g.
    /// `{"search_query":[{"q":"swift 6"}],"response_length":"short"}`.
    static func webRunDetail(_ input: [String: Any]) -> String {
        // Search is by far the common case; name the query, not the action.
        for key in ["search_query", "image_query", "query"] {
            let qs = actionValues(input[key], fields: ["q", "query", "pattern"])
            if !qs.isEmpty { return qs.joined(separator: "  ·  ") }
        }
        for (key, verb) in [("open", "open"), ("click", "click"), ("find", "find in")] {
            let vals = actionValues(input[key], fields: ["url", "pattern", "ref_id", "id"])
            guard !vals.isEmpty else { continue }
            return "\(verb) \(vals.joined(separator: ", "))"
        }
        return string(input, keys: ["q", "prompt", "url"])
    }

    /// Pull the first meaningful field out of each action object in an array
    /// (`[{"q":"..."}]`), tolerating a bare string or a single dict instead.
    private static func actionValues(_ raw: Any?, fields: [String]) -> [String] {
        guard let raw else { return [] }
        if let s = raw as? String { return s.isEmpty ? [] : [s] }
        if let dict = raw as? [String: Any] {
            let v = string(dict, keys: fields)
            return v.isEmpty ? [] : [v]
        }
        guard let items = raw as? [Any] else { return [] }
        var out: [String] = []
        for item in items.prefix(3) {
            if let s = item as? String, !s.isEmpty { out.append(s) }
            else if let dict = item as? [String: Any] {
                let v = string(dict, keys: fields)
                if !v.isEmpty { out.append(v) }
            }
        }
        return out
    }

    /// File paths named by an apply_patch envelope
    /// (`*** Add File: a.swift`, `*** Update File: b.swift`, ...).
    static func patchFiles(_ patch: String) -> [String] {
        guard !patch.isEmpty else { return [] }
        var files: [String] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("*** ") else { continue }
            for verb in ["Add File:", "Update File:", "Delete File:", "Move to:"] where l.contains(verb) {
                guard let range = l.range(of: verb) else { continue }
                let path = l[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !path.isEmpty, !files.contains(path) { files.append(path) }
            }
            if files.count >= 8 { break }
        }
        return files
    }
}

func detailFromHookPayload(_ payload: [String: Any]) -> String {
    if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
        return (cwd as NSString).lastPathComponent
    }
    if let sessionId = payload["session_id"] as? String, !sessionId.isEmpty {
        return "Session \(String(sessionId.prefix(8)))"
    }
    return ""
}
