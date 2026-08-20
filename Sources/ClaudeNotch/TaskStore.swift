import Foundation

// Claude Code's own task list, read from disk.
//
// It keeps one directory per session under ~/.claude/tasks/<session-id>/, with
// a numbered JSON file per task: id, subject, description, status, and the
// blocks / blockedBy edges between them.
//
// Why read it when the TaskCreated and TaskCompleted hooks already report the
// same work: because the hooks only describe what happened while this app was
// running and listening. The directory describes what is true. A session that
// was going before the app launched, one whose hooks were never installed, or
// one that has been resumed after a restart, all have a real task list that the
// hooks can no longer tell us about.
//
// What this does not do is bring the meter back on current models. Claude Code
// withdrew the todo tools from its newer models in 2.1.233, and nothing writes
// here unless the task tools are actually used. This makes the meter right when
// there is something to be right about; it cannot invent a list that was never
// made.
enum TaskStore {

    struct Task: Equatable {
        let id: String
        let subject: String
        let status: String
        /// Ids this task is waiting on. A task with unmet dependencies is not
        /// stalled, it is queued, and those are different things to look at.
        let blockedBy: [String]

        var isDone: Bool { status == "completed" }
        var isBlocked: Bool { !blockedBy.isEmpty && !isDone }
    }

    static var directory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/tasks")
    }

    /// Every task for one session, in file order, which is creation order.
    ///
    /// Off the main thread: it is a directory listing plus a small read per
    /// task, and it runs on a timer rather than per hook.
    nonisolated static func tasks(sessionId: String, directory: String = TaskStore.directory) -> [Task] {
        guard !sessionId.isEmpty else { return [] }
        let dir = (directory as NSString).appendingPathComponent(sessionId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        // Numbered files, sorted numerically: "10.json" comes after "9.json",
        // which a plain string sort gets backwards.
        let ordered = names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> (Int, String)? in
                guard let n = Int(name.dropLast(5)) else { return nil }
                return (n, name)
            }
            .sorted { $0.0 < $1.0 }

        var out: [Task] = []
        for (_, name) in ordered.prefix(maxTasks) {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: path),
                  let task = parse(data) else { continue }
            out.append(task)
        }
        return out
    }

    /// A session with more open tasks than this is not a checklist any more, and
    /// the meter is a meter, not a project plan.
    static let maxTasks = 200

    nonisolated static func parse(_ data: Data) -> Task? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let id = (obj["id"] as? String) ?? (obj["id"] as? Int).map(String.init) ?? ""
        guard !id.isEmpty else { return nil }
        let subject = ((obj["subject"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let status = ((obj["status"] as? String) ?? "").lowercased()
        let blockedBy = ((obj["blockedBy"] as? [Any]) ?? []).compactMap { $0 as? String }
        return Task(id: id, subject: String(subject.prefix(200)),
                    status: status, blockedBy: blockedBy)
    }

    /// Done and total, the two numbers the meter draws.
    ///
    /// Deleted tasks are already absent from the directory, so nothing has to be
    /// filtered out to stop a cancelled task inflating the denominator, which is
    /// the bug the hook-driven version had to work around.
    nonisolated static func progress(_ tasks: [Task]) -> (done: Int, total: Int) {
        (tasks.filter(\.isDone).count, tasks.count)
    }

    /// Sessions with a task directory, most recently written first. Used to find
    /// a list for a session whose hooks never reached us.
    nonisolated static func sessionsWithTasks(directory: String = TaskStore.directory) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return names
            .compactMap { name -> (Date, String)? in
                let path = (directory as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
                return (modified ?? .distantPast, name)
            }
            .sorted { $0.0 > $1.0 }
            .map(\.1)
    }
}
