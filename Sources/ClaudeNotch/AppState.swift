import Foundation
import AppKit

enum NotchMode: Equatable {
    case idle
    case thinking(label: String)
    case permission(PermissionRequest)
    case completed(CompletedTask)
    case question(QuestionRequest)
    case compose
}

struct AskOption: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let description: String
}

struct AskQuestion: Identifiable, Equatable {
    let id = UUID()
    let header: String          // short tag, e.g. "Approach"
    let text: String            // full question
    let multiSelect: Bool
    let options: [AskOption]
}

final class QuestionRequest: Identifiable, Equatable {
    let id = UUID()
    let questions: [AskQuestion]
    let source: String
    let cwd: String
    let receivedAt = Date()
    let originatorBundleID: String?
    let resolver: ([[String]]?) -> Void   // nil = cancel; otherwise one [labels] per question

    init(questions: [AskQuestion], source: String, cwd: String, originatorBundleID: String? = nil, resolver: @escaping ([[String]]?) -> Void) {
        self.questions = questions
        self.source = source
        self.cwd = cwd
        self.originatorBundleID = originatorBundleID
        self.resolver = resolver
    }

    static func == (lhs: QuestionRequest, rhs: QuestionRequest) -> Bool {
        lhs.id == rhs.id
    }
}

enum PermissionDecision: String {
    case allow, deny, ask
}

final class PermissionRequest: Identifiable, Equatable {
    enum Kind: Equatable {
        case toolUse                // blocking — must resolve to allow/deny/ask
        case notification           // non-blocking — just a visibility ping
    }

    let id = UUID()
    let kind: Kind
    let title: String         // e.g. "Run shell command"
    let detail: String        // e.g. the command string
    let toolName: String      // e.g. "Bash"
    let source: String        // e.g. "Claude Code"
    let cwd: String
    let receivedAt = Date()
    let originatorBundleID: String?   // app that was frontmost when request came in
    let resolver: (PermissionDecision) -> Void

    init(kind: Kind, title: String, detail: String, toolName: String, source: String, cwd: String, originatorBundleID: String? = nil, resolver: @escaping (PermissionDecision) -> Void) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.toolName = toolName
        self.source = source
        self.cwd = cwd
        self.originatorBundleID = originatorBundleID
        self.resolver = resolver
    }

    static func == (lhs: PermissionRequest, rhs: PermissionRequest) -> Bool {
        lhs.id == rhs.id
    }
}

final class CompletedTask: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let source: String
    let cwd: String
    let receivedAt = Date()
    let originatorBundleID: String?

    init(title: String, detail: String, source: String, cwd: String, originatorBundleID: String? = nil) {
        self.title = title
        self.detail = detail
        self.source = source
        self.cwd = cwd
        self.originatorBundleID = originatorBundleID
    }

    static func == (lhs: CompletedTask, rhs: CompletedTask) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var mode: NotchMode = .idle
    @Published private(set) var permissionQueue: [PermissionRequest] = []
    @Published private(set) var completedQueue: [CompletedTask] = []
    @Published private(set) var questionQueue: [QuestionRequest] = []
    @Published private(set) var sessionAllowlist: Set<String> = []
    @Published var isHovering: Bool = false

    // Live session info — populated from every hook payload.
    @Published private(set) var currentProject: String = ""        // basename of cwd
    @Published private(set) var currentCwd: String = ""
    @Published private(set) var lastActivity: String = ""          // "Bash: ls -la" etc.
    @Published private(set) var lastUserPrompt: String = ""
    @Published private(set) var recentProjects: [String] = []      // ordered, deduped cwds (newest first)
    @Published private(set) var lastOriginatorBundleID: String? = nil
    @Published private(set) var lastHookAt: Date? = nil
    @Published private(set) var lastClaudeResponse: String = ""
    @Published var composeText: String = ""
    @Published private(set) var isComposing: Bool = false

    // After this many seconds without a hook, drop the activity line.
    private let activityStaleAfter: TimeInterval = 90
    // After this many seconds without a hook, also drop the project name
    // (the terminal is most likely closed).
    private let projectStaleAfter: TimeInterval = 300
    private var staleTimer: Timer?

    func setHovering(_ value: Bool) {
        if isHovering != value { isHovering = value }
    }

    func noteSession(cwd: String, originatorBundleID: String? = nil) {
        guard !cwd.isEmpty else { return }
        currentCwd = cwd
        currentProject = (cwd as NSString).lastPathComponent
        recentProjects.removeAll { $0 == cwd }
        recentProjects.insert(cwd, at: 0)
        if recentProjects.count > 8 { recentProjects = Array(recentProjects.prefix(8)) }
        if let bid = originatorBundleID { lastOriginatorBundleID = bid }
        lastHookAt = Date()
        ensureStaleTimer()
    }

    func noteActivity(_ label: String) {
        lastActivity = label
        lastHookAt = Date()
        ensureStaleTimer()
    }

    func noteUserPrompt(_ prompt: String) {
        lastUserPrompt = String(prompt.prefix(140))
        lastHookAt = Date()
        ensureStaleTimer()
    }

    /// Manually wipe the live session info — useful when you closed the
    /// terminal and want the notch to forget what was running there.
    func clearSession() {
        currentProject = ""
        currentCwd = ""
        lastActivity = ""
        lastUserPrompt = ""
        lastClaudeResponse = ""
        lastHookAt = nil
    }

    func noteClaudeResponse(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastClaudeResponse = String(trimmed.prefix(240))
        lastHookAt = Date()
    }

    // MARK: - Compose (send message to Claude)

    func beginCompose() {
        composeText = ""
        isComposing = true
        recompute()
    }

    func sendCompose() {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { cancelCompose() }
        guard !text.isEmpty else { return }
        let target = lastOriginatorBundleID
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let bid = target else { return }
        TerminalAutomator.sendText(text, toBundleID: bid)
    }

    func cancelCompose() {
        composeText = ""
        isComposing = false
        recompute()
    }

    private func ensureStaleTimer() {
        guard staleTimer == nil else { return }
        staleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkStale() }
        }
    }

    private func checkStale() {
        guard let last = lastHookAt else { return }
        let age = Date().timeIntervalSince(last)
        if age > projectStaleAfter {
            // Full clear — terminal is almost certainly closed.
            currentProject = ""
            currentCwd = ""
            lastActivity = ""
            lastUserPrompt = ""
            lastHookAt = nil
            staleTimer?.invalidate()
            staleTimer = nil
        } else if age > activityStaleAfter {
            // Just drop the volatile fields.
            if !lastActivity.isEmpty { lastActivity = "" }
            if !lastUserPrompt.isEmpty { lastUserPrompt = "" }
        }
    }

    let frontmost = FrontmostTracker()

    private var thinkingLabel = "Working…"
    private var thinkingExpiresAt: Date?
    private var thinkingTask: Task<Void, Never>?

    func enqueuePermission(_ req: PermissionRequest) {
        if sessionAllowlist.contains(req.toolName) {
            req.resolver(.allow)
            return
        }
        permissionQueue.append(req)
        playAlert()
        recompute()
    }

    func enqueueCompleted(_ task: CompletedTask) {
        completedQueue.append(task)
        playChime()
        recompute()
    }

    func enqueueQuestion(_ req: QuestionRequest) {
        questionQueue.append(req)
        playAlert()
        recompute()
    }

    func resolveCurrentQuestion(_ answers: [[String]]?) {
        guard !questionQueue.isEmpty else { return }
        let first = questionQueue.removeFirst()
        first.resolver(answers)
        recompute()
    }

    func resolveCurrentPermission(_ decision: PermissionDecision, alwaysAllow: Bool = false) {
        guard !permissionQueue.isEmpty else { return }
        let first = permissionQueue.removeFirst()
        if alwaysAllow && decision == .allow {
            sessionAllowlist.insert(first.toolName)
        }
        first.resolver(decision)
        recompute()
    }

    func dismissCurrentCompleted() {
        guard !completedQueue.isEmpty else { return }
        completedQueue.removeFirst()
        recompute()
    }

    func clearAllowlist() {
        sessionAllowlist.removeAll()
    }

    func pingThinking(label: String) {
        thinkingLabel = label
        thinkingExpiresAt = Date().addingTimeInterval(8)
        recompute()
        thinkingTask?.cancel()
        thinkingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_500_000_000)
            guard let self else { return }
            await MainActor.run {
                if let exp = self.thinkingExpiresAt, exp <= Date() {
                    self.thinkingExpiresAt = nil
                    self.recompute()
                }
            }
        }
    }

    func openLastApp() {
        frontmost.activateLastApp()
    }

    func openOriginator(_ bundleID: String?) {
        if let bid = bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
           !app.isTerminated {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        frontmost.activateLastApp()
    }

    private func playAlert() {
        NSSound(named: NSSound.Name("Funk"))?.play()
    }

    private func playChime() {
        NSSound(named: NSSound.Name("Glass"))?.play()
    }

    private func recompute() {
        let next: NotchMode
        if isComposing {
            next = .compose
        } else if let q = questionQueue.first {
            next = .question(q)
        } else if let p = permissionQueue.first {
            next = .permission(p)
        } else if let c = completedQueue.first {
            next = .completed(c)
        } else if let exp = thinkingExpiresAt, exp > Date() {
            next = .thinking(label: thinkingLabel)
        } else {
            next = .idle
        }
        if next != mode {
            mode = next
        }
    }
}

@MainActor
final class FrontmostTracker {
    private(set) var lastNonSelf: NSRunningApplication?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, let app else { return }
                let me = Bundle.main.bundleIdentifier
                let bid = app.bundleIdentifier
                guard bid != me else { return }
                // Skip system stuff that flashes through.
                let skip: Set<String> = ["com.apple.WindowManager", "com.apple.dock", "com.apple.notificationcenterui"]
                if let bid, skip.contains(bid) { return }
                self.lastNonSelf = app
            }
        }
        // Seed with the currently frontmost app
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastNonSelf = app
        }
    }

    func activateLastApp() {
        if let app = lastNonSelf, !app.isTerminated {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        let bundles = [
            "com.anthropic.claudefordesktop",
            "com.todesktop.230313mzl4w4u92",   // Cursor
            "com.microsoft.VSCode",
            "com.googlecode.iterm2",
            "com.apple.Terminal"
        ]
        for b in bundles {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
                app.activate(options: [.activateIgnoringOtherApps])
                return
            }
        }
    }
}
