import Foundation
import Network
import AppKit

final class EventServer {
    private let port: UInt16
    private weak var state: AppState?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.claudenotch.server")
    private let workQueue = DispatchQueue(label: "com.claudenotch.server.work", attributes: .concurrent)
    private let transcriptPollLock = NSLock()
    // Per-transcript poll generation, keyed by transcript path, so concurrent
    // sessions each keep polling independently. A newer poll for a given path
    // supersedes only the previous poll for that same path — never the polls of
    // other sessions (which previously happened because the "active" path and
    // generation id were single shared values).
    private var transcriptPollTokens: [String: Int] = [:]

    // taskId → subject, learned from TaskCreate / TaskUpdate(with subject).
    // Lets us put a human label on TaskUpdate calls that only carry {taskId, status}.
    private var taskRegistry: [String: String] = [:]
    private let taskRegistryLock = NSLock()

    // Throttle per-transcript context+cost recomputation (parses the whole file).
    private var meterLastComputed: [String: Date] = [:]
    private let meterLock = NSLock()

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
        guard !path.isEmpty else { return }
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
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
        NSLog("ClaudeNotch listening on 127.0.0.1:\(port)")

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

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }
            if let req = EventServer.parseRequest(buf) {
                self.handle(req, on: conn)
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
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
        let path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if name == "content-length" { contentLength = Int(value) ?? 0 }
            }
        }

        let bodyStart = split.upperBound
        if data.count - bodyStart < contentLength { return nil }
        let body = contentLength > 0
            ? data.subdata(in: bodyStart..<(bodyStart + contentLength))
            : Data()
        return HTTPRequest(method: method, path: path, body: body)
    }

    private func handle(_ req: HTTPRequest, on conn: NWConnection) {
        let payload = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
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
            if !permissionMode.isEmpty {
                state?.notePermissionMode(permissionMode, sessionId: sessionId, cwd: cwd)
            }
        }
    }

    private func handleActivity(payload: [String: Any]) {
        let tool = (payload["tool_name"] as? String) ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let sessionId = (payload["session_id"] as? String) ?? ""

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
        } else if tool == "TaskUpdate" {
            let subject = (input["subject"] as? String) ?? ""
            let taskId  = (input["taskId"] as? String) ?? ""
            recordTask(id: taskId, subject: subject)
            // Secondary feed for the progress meter: status transitions arrive
            // here even if the dedicated TaskCompleted hook is missed.
            let status = (input["status"] as? String) ?? ""
            if !taskId.isEmpty {
                Task { @MainActor [weak state] in
                    switch status {
                    case "completed": state?.noteTaskCompleted(id: taskId, sessionId: sessionId)
                    case "deleted":   state?.noteTaskDeleted(id: taskId, sessionId: sessionId)
                    default:          break
                    }
                }
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
        func num(_ key: String) -> Double? {
            if let d = payload[key] as? Double { return d }
            if let i = payload[key] as? Int { return Double(i) }
            if let s = payload[key] as? String, let d = Double(s) { return d }
            return nil
        }
        let contextPct = num("context_pct")
        let fiveHourPct = num("five_hour_pct")
        let sevenDayPct = num("seven_day_pct")
        // The window Claude Code itself is measuring against, and the tokens it
        // counts as being in it. This is the only place either number is
        // reported: hooks don't carry them, and the transcript doesn't record
        // them. Everything else the app does with a context window is inference.
        let contextWindow = num("context_window").map(Int.init)
        let contextTokens = num("context_tokens").map(Int.init)
        // Nothing usable — don't churn the UI.
        guard contextPct != nil || fiveHourPct != nil || sevenDayPct != nil
                || contextWindow != nil else { return }
        Task { @MainActor [weak state] in
            state?.noteStatusLine(sessionId: sessionId, model: model,
                                  contextPct: contextPct,
                                  contextWindow: contextWindow,
                                  contextTokens: contextTokens,
                                  fiveHourPct: fiveHourPct,
                                  sevenDayPct: sevenDayPct)
        }
    }

    /// PreCompact: context is about to be compacted. Show a transient cue.
    private func handleCompact(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteCompacting(sessionId: sessionId)
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
        Task { @MainActor [weak state] in
            guard let state else { return }
            let msg = (payload["message"] as? String)
                ?? (payload["title"] as? String)
                ?? "Claude needs your attention"
            let detail = (payload["detail"] as? String) ?? detailFromHookPayload(payload)
            let source = (payload["source"] as? String) ?? "Claude Code"
            let frontBID = Self.capturedOriginator(state: state)
            let req = PermissionRequest(
                kind: .notification,
                title: msg,
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
        }

        Task { @MainActor [weak state] in
            guard let state else { return }
            state.markSessionDone(cwd: cwd, sessionId: sessionId)
            let title = (payload["title"] as? String) ?? "Claude finished"
            let detail = (payload["detail"] as? String) ?? detailFromHookPayload(payload)
            let source = (payload["source"] as? String) ?? "Claude Code"
            let frontBID = Self.capturedOriginator(state: state)
            state.enqueueCompleted(.init(
                title: title,
                detail: detail,
                source: source,
                cwd: (payload["cwd"] as? String) ?? "",
                originatorBundleID: frontBID
            ))
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
        let detail = (payload["message"] as? String)
            ?? (payload["error"] as? String)
            ?? ""
        let title: String
        switch reasonKey {
        case "rate_limit":            title = "Rate limited — session stopped"
        case "overloaded":            title = "Servers overloaded — session stopped"
        case "authentication_failed": title = "Authentication failed"
        case "oauth_org_not_allowed": title = "Org not allowed — auth error"
        case "billing_error":         title = "Billing error — session stopped"
        case "invalid_request":       title = "Invalid request — session stopped"
        case "model_not_found":       title = "Model not found"
        case "server_error":          title = "Server error — session stopped"
        case "max_output_tokens":     title = "Hit max output tokens"
        default:                      title = "Session stopped on an error"
        }
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        Task { @MainActor [weak state] in
            guard let state else { return }
            state.noteStopFailure(title: title, detail: detail,
                                  cwd: cwd, sessionId: sessionId)
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

    /// SessionEnd hook (Ctrl+C / Ctrl+D / exit): the session is gone, so stop
    /// polling its transcript and drop it from the notch immediately.
    private func handleSessionEnd(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        if let path = (payload["transcript_path"] as? String), !path.isEmpty {
            cancelPolling(transcriptPath: path)
        }
        Task { @MainActor [weak state] in
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

    private func pollTranscript(path: String, sessionId: String, token: Int, until deadline: Date) {
        readAndPushClaudeResponse(transcriptPath: path, sessionId: sessionId)
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

    /// Tail the JSONL transcript and pull the most recent assistant text
    /// content. Tolerant of multiple message shapes Claude Code emits.
    private func lastAssistantText(fromTranscriptAt path: String) -> String? {
        debugLog("transcript read: \(path)")
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            debugLog("transcript read: FAILED to open file")
            return nil
        }
        let maxBytes: UInt64 = 512 * 1024
        let size = handle.seekToEndOfFile()
        let offset = size > maxBytes ? size - maxBytes : 0
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        try? handle.close()

        var body = String(decoding: data, as: UTF8.self)
        if offset > 0, let newline = body.firstIndex(of: "\n") {
            body = String(body[body.index(after: newline)...])
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

    private func debugLog(_ msg: String) {
        let url = URL(fileURLWithPath: "/tmp/claudenotch-debug.log")
        let line = "[\(Date())] server: \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// PreToolUse: tool was just approved and is now executing. Update the
    /// activity strip live so the user sees what's running while it runs.
    private func handlePreTool(payload: [String: Any]) {
        let tool = (payload["tool_name"] as? String) ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let sessionId = (payload["session_id"] as? String) ?? ""
        guard !tool.isEmpty else { return }
        Task { @MainActor [weak state] in
            guard let state else { return }
            let detail = self.enrichedDetail(for: tool, input: input)
            let label = detail.isEmpty ? tool : "\(tool): \(detail)"
            state.noteActivity(String(label.prefix(80)), sessionId: sessionId)
        }
    }

    /// PostToolUse: tool finished, Claude is now reasoning between actions.
    /// Clears the command strip and shows "thinking" until the next tool starts.
    private func handlePostToolThinking(payload: [String: Any]) {
        let sessionId = (payload["session_id"] as? String) ?? ""
        Task { @MainActor [weak state] in
            state?.noteThinkingBetweenTools(sessionId: sessionId)
        }
    }

    private func handleBlockingPermission(payload: [String: Any], on conn: NWConnection) {
        let toolName = (payload["tool_name"] as? String) ?? "tool"
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let cwd = (payload["cwd"] as? String) ?? ""
        let title = humanTitle(for: toolName)
        let detail = enrichedDetail(for: toolName, input: toolInput)
        let preview = ToolPreviewParser.preview(for: toolName, input: toolInput)
        let dangers = ToolPreviewParser.dangerReasons(for: toolName, input: toolInput)

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var decision: PermissionDecision = .ask
        var denyReason: String? = nil

        Task { @MainActor [weak state] in
            guard let state else { return }
            let frontBID = Self.capturedOriginator(state: state)
            let req = PermissionRequest(
                kind: .toolUse,
                title: title,
                detail: detail,
                toolName: toolName,
                source: "Claude Code",
                cwd: cwd,
                originatorBundleID: frontBID,
                preview: preview,
                dangerReasons: dangers,
                resolver: { d, r in
                    lock.withLock { decision = d; denyReason = r }
                    semaphore.signal()
                }
            )
            state.enqueuePermission(req)
        }

        workQueue.async { [weak self] in
            let result = semaphore.wait(timeout: .now() + .seconds(285))
            let final: PermissionDecision
            let reason: String?
            if result == .timedOut {
                final = .ask
                reason = nil
            } else {
                (final, reason) = lock.withLock { (decision, denyReason) }
            }
            // Build with JSONSerialization so a free-text reason is escaped.
            // The hook (claudenotch-permission.sh) forwards `reason` to Claude
            // as the permissionDecisionReason on a deny.
            var dict: [String: Any] = ["decision": final.rawValue]
            if final == .deny, let r = reason, !r.isEmpty { dict["reason"] = r }
            let body = (try? JSONSerialization.data(withJSONObject: dict))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? "{\"decision\":\"\(final.rawValue)\"}"
            self?.send(body: body, on: conn)
        }
    }

    private func handleBlockingQuestion(payload: [String: Any], on conn: NWConnection) {
        // Accept either Claude Code's full PreToolUse JSON (tool_input.questions)
        // or our own shape ({questions: [...]}).
        let rawQuestions: [[String: Any]] = {
            if let qs = payload["questions"] as? [[String: Any]] { return qs }
            if let ti = payload["tool_input"] as? [String: Any],
               let qs = ti["questions"] as? [[String: Any]] { return qs }
            return []
        }()
        let cwd = (payload["cwd"] as? String) ?? ""

        let parsed: [AskQuestion] = rawQuestions.compactMap { dict in
            guard let q = dict["question"] as? String else { return nil }
            let header = (dict["header"] as? String) ?? ""
            let multi  = (dict["multiSelect"] as? Bool) ?? false
            let opts   = (dict["options"] as? [[String: Any]]) ?? []
            let options: [AskOption] = opts.compactMap { o in
                guard let label = o["label"] as? String else { return nil }
                return AskOption(label: label, description: (o["description"] as? String) ?? "")
            }
            guard !options.isEmpty else { return nil }
            return AskQuestion(header: header, text: q, multiSelect: multi, options: options)
        }

        guard !parsed.isEmpty else {
            send(body: "{\"cancelled\":true,\"reason\":\"no questions parsed\"}", on: conn)
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var answers: [[String]]? = nil

        Task { @MainActor [weak state] in
            guard let state else { return }
            let frontBID = Self.capturedOriginator(state: state)
            let req = QuestionRequest(
                questions: parsed,
                source: "Claude Code",
                cwd: cwd,
                originatorBundleID: frontBID,
                resolver: { ans in
                    lock.withLock { answers = ans }
                    semaphore.signal()
                }
            )
            state.enqueueQuestion(req)
        }

        workQueue.async { [weak self] in
            let result = semaphore.wait(timeout: .now() + .seconds(285))
            let bodyJSON: String
            if result == .timedOut {
                bodyJSON = "{\"cancelled\":true,\"reason\":\"timeout\"}"
                self?.send(body: bodyJSON, on: conn)
                return
            }

            let ans = lock.withLock { answers }
            guard let ans else {
                self?.send(body: "{\"cancelled\":true,\"reason\":\"user dismissed\"}", on: conn)
                return
            }

            // Always feed the answer back through the hook's deny reason so
            // Claude Code never renders its own blocking prompt in the
            // terminal. We used to optionally return allow + AppleScript
            // keystrokes, but that left the terminal waiting for input whenever
            // the keystroke mis-timed or the wrong app had focus — answering in
            // the notch is now sufficient on its own.
            let pairs = zip(parsed, ans).map { (q, picks) -> [String: Any] in
                ["question": q.text, "header": q.header, "picked": picks]
            }
            let payload: [String: Any] = ["mode": "deny", "answers": pairs]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let s = String(data: data, encoding: .utf8) {
                bodyJSON = s
            } else {
                bodyJSON = "{\"cancelled\":true,\"reason\":\"encode failed\"}"
            }

            self?.send(body: bodyJSON, on: conn)
        }
    }

    // MARK: - HTTP hook unified endpoint

    /// Single entry point for native HTTP hooks (`"type": "http"` in settings.json).
    /// Claude Code POSTs the full event JSON here; we return hookSpecificOutput directly
    /// instead of relying on the shell-script intermediaries to format it.
    private func handleUnifiedHook(payload: [String: Any], on conn: NWConnection) {
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
        case "PostToolUse":
            handleActivity(payload: payload)
            handlePostToolThinking(payload: payload)
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
        case "CwdChanged":
            // recordSessionMetadata (called before routing in handle()) already
            // invokes noteSession(cwd:sessionId:) with authoritativeCwd:true,
            // which updates session.cwd, session.project, and currentCwd. No
            // extra work needed here.
            sendOK(on: conn)
        default:
            sendOK(on: conn)
        }
    }

    /// Shared wait: enqueue a permission card on the main actor and block on
    /// workQueue until the user resolves it (or 285 s pass). Must be called
    /// from workQueue.
    private func awaitPermissionDecision(toolName: String, toolInput: [String: Any],
                                         cwd: String) -> (PermissionDecision, String?) {
        let title   = humanTitle(for: toolName)
        let detail  = enrichedDetail(for: toolName, input: toolInput)
        let preview = ToolPreviewParser.preview(for: toolName, input: toolInput)
        let dangers = ToolPreviewParser.dangerReasons(for: toolName, input: toolInput)

        let sem  = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var dec: PermissionDecision = .ask
        var rsn: String?

        Task { @MainActor [weak state] in
            guard let state else { sem.signal(); return }
            let frontBID = Self.capturedOriginator(state: state)
            state.enqueuePermission(PermissionRequest(
                kind: .toolUse, title: title, detail: detail, toolName: toolName,
                source: "Claude Code", cwd: cwd, originatorBundleID: frontBID,
                preview: preview, dangerReasons: dangers,
                resolver: { d, r in lock.withLock { dec = d; rsn = r }; sem.signal() }
            ))
        }
        if sem.wait(timeout: .now() + .seconds(285)) == .timedOut { return (.ask, nil) }
        return lock.withLock { (dec, rsn) }
    }

    /// PreToolUse via HTTP hook: returns hookSpecificOutput with permissionDecision.
    private func handleBlockingPermissionHTTP(payload: [String: Any], on conn: NWConnection) {
        let toolName  = (payload["tool_name"]  as? String)        ?? "tool"
        let toolInput = (payload["tool_input"] as? [String: Any]) ?? [:]
        let cwd       = (payload["cwd"]        as? String)        ?? ""
        workQueue.async { [weak self] in
            guard let self else { return }
            let (final, reason) = self.awaitPermissionDecision(toolName: toolName, toolInput: toolInput, cwd: cwd)
            var inner: [String: Any] = ["hookEventName": "PreToolUse", "permissionDecision": final.rawValue]
            if final == .deny, let r = reason, !r.isEmpty { inner["permissionDecisionReason"] = String(r.prefix(200)) }
            self.sendHookOutput(["hookSpecificOutput": inner], on: conn)
        }
    }

    /// PermissionRequest via HTTP hook: returns hookSpecificOutput with decision.behavior.
    private func handleBlockingPermReqHTTP(payload: [String: Any], on conn: NWConnection) {
        let toolName  = (payload["tool_name"]  as? String)        ?? "tool"
        let toolInput = (payload["tool_input"] as? [String: Any]) ?? [:]
        let cwd       = (payload["cwd"]        as? String)        ?? ""
        workQueue.async { [weak self] in
            guard let self else { return }
            let (final, _) = self.awaitPermissionDecision(toolName: toolName, toolInput: toolInput, cwd: cwd)
            guard final != .ask else { self.sendOK(on: conn); return }
            let behavior = (final == .allow) ? "allow" : "deny"
            self.sendHookOutput(["hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": behavior],
            ]], on: conn)
        }
    }

    /// AskUserQuestion via HTTP hook: returns hookSpecificOutput deny+reason with answers.
    private func handleBlockingQuestionHTTP(payload: [String: Any], on conn: NWConnection) {
        let rawQs: [[String: Any]] = {
            if let qs = payload["questions"] as? [[String: Any]] { return qs }
            if let ti = payload["tool_input"] as? [String: Any],
               let qs = ti["questions"] as? [[String: Any]] { return qs }
            return []
        }()
        let cwd = (payload["cwd"] as? String) ?? ""
        let parsed: [AskQuestion] = rawQs.compactMap { dict in
            guard let q = dict["question"] as? String else { return nil }
            let opts: [AskOption] = ((dict["options"] as? [[String: Any]]) ?? []).compactMap {
                guard let label = $0["label"] as? String else { return nil }
                return AskOption(label: label, description: ($0["description"] as? String) ?? "")
            }
            guard !opts.isEmpty else { return nil }
            return AskQuestion(header: (dict["header"] as? String) ?? "", text: q,
                               multiSelect: (dict["multiSelect"] as? Bool) ?? false, options: opts)
        }
        guard !parsed.isEmpty else { sendOK(on: conn); return }

        let sem  = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var answers: [[String]]?

        Task { @MainActor [weak state] in
            guard let state else { sem.signal(); return }
            let frontBID = Self.capturedOriginator(state: state)
            state.enqueueQuestion(QuestionRequest(
                questions: parsed, source: "Claude Code", cwd: cwd,
                originatorBundleID: frontBID,
                resolver: { ans in lock.withLock { answers = ans }; sem.signal() }
            ))
        }

        workQueue.async { [weak self] in
            guard let self else { return }
            if sem.wait(timeout: .now() + .seconds(285)) == .timedOut { self.sendOK(on: conn); return }
            guard let ans = lock.withLock({ answers }) else { self.sendOK(on: conn); return }
            let lines = zip(parsed, ans).map { q, picks -> String in
                let h = q.header.isEmpty ? q.text : q.header
                let picked = picks.filter { !$0.isEmpty }
                return picked.isEmpty ? "  - \(h): (no preference)" : "  - \(h): \(picked.joined(separator: ", "))"
            }
            let reason = "[ClaudeNotch — user replied via the notch]\n\(lines.joined(separator: "\n"))\n\nUse these answers and continue."
            self.sendHookOutput(["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": String(reason.prefix(2000)),
            ]], on: conn)
        }
    }

    // MARK: - Response

    private func sendOK(on conn: NWConnection) {
        send(body: "{\"ok\":true}", on: conn)
    }

    private func sendHookOutput(_ dict: [String: Any], on conn: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: dict))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"ok\":true}"
        send(body: body, on: conn)
    }

    private func send(body: String, on conn: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
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
    default:             return "Run \(tool)"
    }
}

func humanDetail(for tool: String, input: [String: Any]) -> String {
    switch tool {
    case "Bash":
        return (input["command"] as? String) ?? (input["description"] as? String) ?? ""
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
        if let s = input["command"] as? String  { return s }
        if let s = input["file_path"] as? String { return s }
        if let s = input["query"] as? String     { return s }
        if let s = input["url"] as? String       { return s }
        if let s = input["subject"] as? String   { return s }
        return ""
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
