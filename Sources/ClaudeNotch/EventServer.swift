import Foundation
import Network
import AppKit

final class EventServer {
    private let port: UInt16
    private weak var state: AppState?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.claudenotch.server")
    private let workQueue = DispatchQueue(label: "com.claudenotch.server.work", attributes: .concurrent)

    init(port: UInt16, state: AppState) {
        self.port = port
        self.state = state
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
        Task { @MainActor [weak state] in
            let frontBID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            state?.noteSession(cwd: cwd, originatorBundleID: frontBID)
        }
    }

    private func handleActivity(payload: [String: Any]) {
        Task { @MainActor [weak state] in
            guard let state else { return }
            let tool = (payload["tool_name"] as? String) ?? ""
            guard !tool.isEmpty else { return }
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let detail = humanDetail(for: tool, input: input)
            let label = detail.isEmpty ? tool : "\(tool): \(detail)"
            state.noteActivity(String(label.prefix(80)))
        }
    }

    private func handlePrompt(payload: [String: Any]) {
        Task { @MainActor [weak state] in
            let prompt = (payload["prompt"] as? String) ?? ""
            state?.noteUserPrompt(prompt)
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
            let frontBID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
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
        Task { @MainActor [weak state] in
            guard let state else { return }
            let title = (payload["title"] as? String) ?? "Claude finished"
            let detail = (payload["detail"] as? String) ?? detailFromHookPayload(payload)
            let source = (payload["source"] as? String) ?? "Claude Code"
            let frontBID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            state.enqueueCompleted(.init(
                title: title,
                detail: detail,
                source: source,
                cwd: (payload["cwd"] as? String) ?? "",
                originatorBundleID: frontBID
            ))
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
        let detail = humanDetail(for: toolName, input: toolInput)

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var decision: PermissionDecision = .ask

        Task { @MainActor [weak state] in
            guard let state else { return }
            let frontBID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let req = PermissionRequest(
                kind: .toolUse,
                title: title,
                detail: detail,
                toolName: toolName,
                source: "Claude Code",
                cwd: cwd,
                originatorBundleID: frontBID,
                resolver: { d in
                    lock.lock()
                    decision = d
                    lock.unlock()
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
                lock.lock(); final = decision; lock.unlock()
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
        var capturedOriginatorBID: String? = nil

        Task { @MainActor [weak state] in
            guard let state else { return }
            let frontBID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            lock.lock(); capturedOriginatorBID = frontBID; lock.unlock()
            let req = QuestionRequest(
                questions: parsed,
                source: "Claude Code",
                cwd: cwd,
                originatorBundleID: frontBID,
                resolver: { ans in
                    lock.lock(); answers = ans; lock.unlock()
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

            lock.lock(); let ans = answers; let originatorBID = capturedOriginatorBID; lock.unlock()
            guard let ans else {
                self?.send(body: "{\"cancelled\":true,\"reason\":\"user dismissed\"}", on: conn)
                return
            }

            // Only allow keystroke route when:
            //   - every question is single-select
            //   - every question got exactly one pick
            //   - we know which app to inject into
            //   - Accessibility is granted
            let allSingleAnswered = zip(parsed, ans).allSatisfy { (q, picks) in
                !q.multiSelect && picks.count == 1
            }
            var indexes: [Int] = []
            if allSingleAnswered {
                for (q, picks) in zip(parsed, ans) {
                    if let label = picks.first,
                       let idx = q.options.firstIndex(where: { $0.label == label }) {
                        indexes.append(idx + 1)
                    } else {
                        indexes.removeAll()
                        break
                    }
                }
            }

            let accessibilityOK: Bool = {
                var ok = false
                let sem = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    ok = TerminalAutomator.isAccessibilityTrusted
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + .seconds(1))
                return ok
            }()

            if allSingleAnswered, !indexes.isEmpty, let bid = originatorBID, accessibilityOK {
                // Schedule the keystroke send. Hook returns allow → Claude Code
                // renders the prompt → AppleScript fires after a short delay.
                Task { @MainActor in
                    TerminalAutomator.sendAnswers(indexes, toBundleID: bid)
                }
                bodyJSON = "{\"mode\":\"allow\"}"
            } else {
                // Fall back to deny+reason so Claude at least sees the answers.
                let pairs = zip(parsed, ans).map { (q, picks) -> [String: Any] in
                    ["question": q.text, "header": q.header, "picked": picks]
                }
                var payload: [String: Any] = ["mode": "deny", "answers": pairs]
                if !accessibilityOK {
                    payload["fallback_reason"] = "accessibility-not-granted"
                } else if !allSingleAnswered {
                    payload["fallback_reason"] = "multi-select-not-supported"
                } else if originatorBID == nil {
                    payload["fallback_reason"] = "originator-unknown"
                }
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let s = String(data: data, encoding: .utf8) {
                    bodyJSON = s
                } else {
                    bodyJSON = "{\"cancelled\":true,\"reason\":\"encode failed\"}"
                }
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
    case "Bash":      return "Run shell command"
    case "Write":     return "Write file"
    case "Edit":      return "Edit file"
    case "MultiEdit": return "Edit file"
    case "Read":      return "Read file"
    default:          return "Run \(tool)"
    }
}

private func humanDetail(for tool: String, input: [String: Any]) -> String {
    switch tool {
    case "Bash":
        return (input["command"] as? String) ?? (input["description"] as? String) ?? ""
    case "Write", "Edit", "MultiEdit", "Read":
        return (input["file_path"] as? String) ?? ""
    default:
        if let s = input["command"] as? String { return s }
        if let s = input["file_path"] as? String { return s }
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
