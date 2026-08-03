import SwiftUI
import AppKit

// The Session page: live sessions, what to resume, and the per-session controls.

extension SettingsView {
    var session: some View {
        page(L("Session", comment: "Settings page title")) {
            sectionLabel(L("Current session", comment: "Settings section heading"))
            group {
                actionRow(L("Send a message to Claude…", comment: "Settings button"), "paperplane") {
                    state.beginCompose()
                    window()?.close()
                }
                divider
                actionRow(L("Clear the active session", comment: "Settings button"), "xmark.circle") { state.clearSession() }
            }

            sectionLabel(L("Finished tasks", comment: "Settings section heading"))
            group {
                row(L("Check what Claude actually did", comment: "Settings toggle"),
                    L("When a task finishes, compare the closing message against what the turn really did, and say so on the card if it claims a change it never made or says the tests pass when none ran. Off by default: it is an opinion about the work, and it stays quiet on an ordinary turn.", comment: "Settings toggle explanation"),
                    Binding(get: { state.completionAuditEnabled },
                            set: { state.setCompletionAuditEnabled($0) }))
            }

            sectionLabel(L("Auto-approve for a while", comment: "Settings section heading"))
            Text(L("Turn on auto-approve for a set time and it switches itself back off, or keep it on until you turn it off.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)
            group {
                actionRow(L("Keep on until I turn it off", comment: "Settings button"), "infinity") { state.setAutoApprove(true) }
                divider
                let windows = [15, 30, 60, 120]
                ForEach(Array(windows.enumerated()), id: \.element) { idx, m in
                    actionRow(windowLabel(m), "clock") { state.enableAutoApprove(forMinutes: m) }
                    if idx < windows.count - 1 { divider }
                }
            }
            if let until = state.autoApproveUntil {
                Text("Auto-approve on until \(until.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption).foregroundStyle(.orange)
                Button("Turn off now") { state.setAutoApprove(false) }
            } else if state.autoApprove {
                Text(L("Auto-approve is on until you turn it off.", comment: "Settings explanation"))
                    .font(.caption).foregroundStyle(.orange)
                Button("Turn off now") { state.setAutoApprove(false) }
            }

            sectionLabel(L("Snooze passive cards", comment: "Settings section heading"))
            group {
                let windows = [15, 30, 60]
                ForEach(Array(windows.enumerated()), id: \.element) { idx, m in
                    actionRow(String(format: L("Snooze for %@", comment: "Settings button. %@ is a duration such as 30 min"), windowLabel(m)), "moon.zzz") { state.snooze(forMinutes: m) }
                    if idx < windows.count - 1 { divider }
                }
            }
            if let until = state.snoozedUntil {
                Text("Snoozed until \(until.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption).foregroundStyle(.orange)
                Button("Cancel snooze") { state.cancelSnooze() }
            }

            sectionLabel(L("Projects & recent sessions", comment: "Settings section heading"))
            Text(L("Closed a terminal by accident? Expand a project and resume right where you left off.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)
            if projectSessions.isEmpty {
                group {
                    HStack {
                        Text(L("No past sessions found yet.", comment: "Settings explanation"))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                }
            } else {
                SearchField(placeholder: "Filter by project or prompt…", text: $sessionSearch)

                let matches = filteredProjectSessions
                if matches.isEmpty {
                    group {
                        HStack {
                            Text("No sessions match “\(sessionSearch)”.")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 10).padding(.horizontal, 14)
                    }
                } else {
                    group {
                        ForEach(Array(matches.enumerated()), id: \.element.cwd) { idx, proj in
                            projectRow(proj, forceOpen: !sessionSearch.isEmpty)
                            if idx < matches.count - 1 { divider }
                        }
                    }
                }
            }

            let diff = state.currentDiffStat
            if diff.added > 0 || diff.removed > 0 {
                sectionLabel(L("Lines changed this session", comment: "Settings section heading"))
                group {
                    HStack(spacing: 12) {
                        Text("+\(diff.added)")
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.green)
                        Text("-\(diff.removed)")
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.red)
                        Spacer()
                        Text("net \(diff.added - diff.removed >= 0 ? "+" : "")\(diff.added - diff.removed)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                }
            }

            if !state.currentTouchedFiles.isEmpty {
                sectionLabel(L("Files touched this session", comment: "Settings section heading"))
                group {
                    let files = Array(state.currentTouchedFiles.prefix(10))
                    ForEach(Array(files.enumerated()), id: \.element) { idx, path in
                        actionRow((path as NSString).lastPathComponent, "doc") {
                            AppState.openEditedFile(path)
                        }
                        if idx < files.count - 1 { divider }
                    }
                }
                Button("Reveal all in Finder") {
                    let urls = state.currentTouchedFiles.map { URL(fileURLWithPath: $0) }
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                .padding(.top, 2)
            }
        }
        .task(id: section) {
            guard section == .session else { return }
            let codexOn = HookInstaller.isCodexInstalled
            let loaded = await Task.detached(priority: .utility) {
                SessionResumer.allAgentSessionsByProject(includeCodex: codexOn)
            }.value
            projectSessions = loaded
        }
        .confirmationDialog(
            "Move this session to the Trash?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { s in
            Button("Move to Trash", role: .destructive) { deleteSession(s) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { s in
            Text("“\(s.title)” goes to the Trash. You can restore it from there; Claude Code won't be able to resume it while it's trashed.")
        }
    }
}
