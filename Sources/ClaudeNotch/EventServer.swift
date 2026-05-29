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
    private var transcriptPollID = 0
    private var activeTranscriptPath: String?

    // taskId → subject, learned from TaskCreate / TaskUpdate(with subject).
    // Lets us put a human label on TaskUpdate calls that only carry {taskId, status}.
    private var taskRegistry: [String: String] = [:]
    private let taskRegistryLock = NSLock()

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
    private func extractTaskId(from response: Any) -> String? {
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
            if let req = self.parseRequest(buf) {
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

    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
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

        // Every hook payload tells us about a project (cwd) — always record it.
        recordSessionMetadata(payload: payload)
        let sessionId = (payload["session_id"] as? String) ?? ""
        let transcriptPath = (payload["transcript_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if path != "/prompt", let transcriptPath {
            let duration: TimeInterval = path == "/stop" ? 4 : 300
            startResponsePolling(transcriptPath: transcriptPath, sessionId: sessionId, duration: duration)
        }

        switch path {
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
        case "/activity":
            handleActivity(payload: payload)
            sendOK(on: conn)
        case "/prompt":
            handlePrompt(payload: payload)
            if let transcriptPath {
                startResponsePolling(transcriptPath: transcriptPath, sessionId: sessionId, duration: 300, delayFirstRead: true)
            }
            sendOK(on: conn)
        case "/pretool", "/posttool", "/thinking":
            handleThinking(payload: payload)
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
        Task { @MainActor [weak state] in
            let frontBID = Self.capturedOriginator(state: state)
            state?.noteSession(cwd: cwd, sessionId: sessionId, originatorBundleID: frontBID)
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
                taskId = extractTaskId(from: resp) ?? ""
            }
            recordTask(id: taskId, subject: subject)
        } else if tool == "TaskUpdate" {
            let subject = (input["subject"] as? String) ?? ""
            let taskId  = (input["taskId"] as? String) ?? ""
            recordTask(id: taskId, subject: subject)
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
                resolver: { _ in }
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
            activeTranscriptPath = path
            transcriptPollID += 1
            return transcriptPollID
        }
        let deadline = Date().addingTimeInterval(duration)
        if delayFirstRead {
            workQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                guard let self else { return }
                let isCurrent = self.transcriptPollLock.withLock {
                    self.transcriptPollID == token && self.activeTranscriptPath == path
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
        guard Date() < deadline else { return }
        workQueue.asyncAfter(deadline: .now() + .milliseconds(700)) { [weak self] in
            guard let self else { return }
            let isCurrent = self.transcriptPollLock.withLock {
                self.transcriptPollID == token && self.activeTranscriptPath == path
            }
            guard isCurrent else { return }
            self.pollTranscript(path: path, sessionId: sessionId, token: token, until: deadline)
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

    private func handleThinking(payload: [String: Any]) {
        Task { @MainActor [weak state] in
            guard let state else { return }
            let label = (payload["label"] as? String)
                ?? (payload["tool_name"] as? String).map { "Using \($0)" }
                ?? "Working…"
            state.pingThinking(label: label)
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
                resolver: { d in
                    lock.withLock { decision = d }
                    semaphore.signal()
                }
            )
            state.enqueuePermission(req)
        }

        workQueue.async { [weak self] in
            let result = semaphore.wait(timeout: .now() + .seconds(285))
            let final: PermissionDecision
            if result == .timedOut {
                final = .ask
            } else {
                final = lock.withLock { decision }
            }
            let body = "{\"decision\":\"\(final.rawValue)\"}"
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

    // MARK: - Response

    private func sendOK(on conn: NWConnection) {
        send(body: "{\"ok\":true}", on: conn)
    }

    private func send(body: String, on conn: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - Formatting

private func humanTitle(for tool: String) -> String {
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
    default:             return "Run \(tool)"
    }
}

private func humanDetail(for tool: String, input: [String: Any]) -> String {
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
    default:
        if let s = input["command"] as? String  { return s }
        if let s = input["file_path"] as? String { return s }
        if let s = input["query"] as? String     { return s }
        if let s = input["url"] as? String       { return s }
        if let s = input["subject"] as? String   { return s }
        return ""
    }
}

private func detailFromHookPayload(_ payload: [String: Any]) -> String {
    if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
        return (cwd as NSString).lastPathComponent
    }
    if let sessionId = payload["session_id"] as? String, !sessionId.isEmpty {
        return "Session \(String(sessionId.prefix(8)))"
    }
    return ""
}
