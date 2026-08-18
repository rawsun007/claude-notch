import SwiftUI
import AppKit

// The two pages about the app rather than the work: Developer (sample cards and
// pet animations) and About (version, update check, credits).

extension SettingsView {
    var developer: some View {
        page(L("Developer", comment: "Settings page title")) {
            Text(L("Fire a sample card to see what the notch looks like.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)
            DisclosureGroup(isExpanded: $devSampleCardsOpen) {
                group {
                    actionRow(L("Tool permission", comment: "Settings button"), "terminal") { demoPermission() }
                    divider
                    actionRow(L("Destructive command", comment: "Settings button"), "exclamationmark.triangle") { demoDangerous() }
                    divider
                    actionRow(L("Edit with diff preview", comment: "Settings button"), "doc.text.magnifyingglass") { demoDiff() }
                    divider
                    actionRow(L("Auto-approve (live activity)", comment: "Settings button"), "bolt.badge.a") { demoAutoApprove() }
                    divider
                    actionRow(L("Notification", comment: "Settings button"), "bell") { demoNotification() }
                    divider
                    actionRow(L("Task complete", comment: "Settings button"), "checkmark.seal") { demoCompleted() }
                    divider
                    // Built from the same list the menu bar reads, so the two
                    // Demos menus cannot drift apart again.
                    ForEach(Array(DemoCards.auditVerdicts.enumerated()), id: \.offset) { _, item in
                        actionRow(L(item.title, comment: "Settings button"), item.symbol) {
                            demoAudit(item.verdict)
                        }
                        divider
                    }
                    actionRow(L("Thinking pulse", comment: "Settings button"), "brain") { state.pingThinking(label: "Editing AuthMiddleware.swift") }
                    divider
                    actionRow(L("Cost budget alert", comment: "Settings button"), "dollarsign.circle") { state.demoBudgetAlert() }
                    divider
                    actionRow(L("Budget hard-stop", comment: "Settings button"), "hand.raised") { state.demoBudgetBlock() }
                }
                .padding(.top, 6)
            } label: {
                Text(L("Sample cards", comment: "Settings explanation")).font(.callout.weight(.semibold))
            }

            DisclosureGroup(isExpanded: $devPetDemosOpen) {
                group {
                    // The same two lists the Pet page shows. This one used to be
                    // a single flat run, which is where the Spider-Pet went to
                    // hide among the naps.
                    let everyday = PetActivity.everydayCases
                    let specials = PetActivity.specialCases
                    actionRow(L("Play all", comment: "Settings button"), "play.circle") {
                        state.demoPet(everyday + specials)
                    }
                    divider
                    ForEach(everyday, id: \.self) { activity in
                        actionRow(activity.title, "pawprint") { state.demoPet([activity]) }
                        divider
                    }
                    listHeading(L("Guest appearances", comment: "Settings section heading"))
                    ForEach(Array(specials.enumerated()), id: \.element) { idx, activity in
                        if let guest = activity.special {
                            specialPetRow(activity, guest)
                            if idx < specials.count - 1 { divider }
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(L("Pet animations", comment: "Settings explanation")).font(.callout.weight(.semibold))
            }
        }
    }

    var about: some View {
        page(L("About", comment: "Settings page title")) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("ClaudeNotch", comment: "Settings explanation")).font(.title2.weight(.semibold))
                    Text(L("Claude Code, living in your notch.", comment: "Settings explanation"))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(String(format: L("Version %@", comment: "About page. %@ is a version and build number"), Self.appVersion))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            if !Self.whatsNew.isEmpty {
                sectionLabel(String(format: L("What's new in v%@", comment: "Settings section heading. %@ is the version number"), Self.appVersion))
                // Grouped by kind (Added / Fixed / …) like the website
                // changelog: one wall of sparkles made a new feature and a bug
                // fix look identical.
                ForEach(Array(Self.whatsNew.enumerated()), id: \.offset) { _, changeGroup in
                    changeGroupHeading(changeGroup.kind)
                    group {
                        ForEach(Array(changeGroup.items.enumerated()), id: \.offset) { idx, line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: changeGroup.kind.symbol)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(changeGroup.kind.tint)
                                    .padding(.top, 2)
                                Text(line).font(.callout)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 14)
                            if idx < changeGroup.items.count - 1 { divider }
                        }
                    }
                }
            }
            // The CLI this app exists to watch has its own release train and
            // ships several times a week. The app already tells you when IT is
            // out of date; being three versions behind on Claude Code is the
            // more consequential half, and half the notch's newer features
            // need a recent one to have anything to show.
            sectionLabel(L("Claude Code", comment: "Settings section heading"))
            group {
                claudeCLIRow
            }
            group {
                hookHealthRow
            }
            group {
                aboutLink("Full changelog", ProjectLinks.changelog)
                divider
                aboutLink("Source on GitHub", ProjectLinks.github)
            }
            group {
                actionRow(L("Send feedback", comment: "Settings button"), "bubble.left.and.bubble.right") { Self.openFeedback() }
                divider
                actionRow(L("Check for updates…", comment: "Settings button"), "arrow.down.circle") { UpdateChecker.shared.check(userInitiated: true) }
                if onOpenSetup != nil {
                    divider
                    actionRow(L("Run setup again…", comment: "Settings button"), "wand.and.stars") { onOpenSetup?() }
                }
            }
        }
    }

    /// Whether hooks are actually reaching the app.
    ///
    /// Everything the notch shows arrives this way and none of it is visible,
    /// so when nothing appears there has been no way to tell "nothing is
    /// happening" from "nothing is getting through". This is that answer, in
    /// one line, refreshed while the window is open.
    @ViewBuilder
    private var hookHealthRow: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let health = HookHealth.state(serverHealthy: state.serverStatus.isHealthy,
                                          installed: HookInstaller.isInstalled,
                                          lastHookAt: state.lastHookAt)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: HookHealth.isProblem(health)
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(HookHealth.isProblem(health) ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Hooks", comment: "Settings row label for hook delivery health"))
                        .font(.callout).fontWeight(.medium)
                    Text(HookHealth.summary(health))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    /// Installed Claude Code version, whether a newer one exists, and a button
    /// that runs the right update command for how this copy was installed.
    private var claudeCLIRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ClaudeCLIUpdate.summary(state.claudeCLI))
                        .fixedSize(horizontal: false, vertical: true)
                    if state.claudeCLI.updateAvailable {
                        // What will actually run, before it runs. The command
                        // differs by install method, and a button that opens a
                        // terminal should say what it is about to type.
                        Text(state.claudeCLI.command)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    // A session keeps the binary it launched with, so updating
                    // changes nothing in a window that is already open. Saying
                    // so is what stops the update reading as having failed.
                    if !state.sessionsOnOlderCLI.isEmpty {
                        Text(Self.olderSessionsNote(state.sessionsOnOlderCLI))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if state.cliUpdateChecking {
                        ProgressView().controlSize(.small)
                    }
                    // Always offered, including while an update is pending. It
                    // was not, and after installing an update there was no way
                    // to make the card stop asking for one.
                    Button(L("Check", comment: "Settings button: re-check the Claude Code version")) {
                        state.refreshCLIUpdate(force: true)
                    }
                    .controlSize(.small)
                    if state.claudeCLI.updateAvailable {
                        Button(L("Update", comment: "Settings button: update the Claude Code CLI")) {
                            state.updateClaudeCLI()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            // What you would get by updating. Shown only when there is an
            // update AND notes for it were actually found: an empty "What's
            // new" heading is worse than no heading.
            ForEach(Array(state.claudeCLI.notes.enumerated()), id: \.offset) { _, release in
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: L("What's new in %@", comment: "Settings heading above CLI release notes. %@ is a version number"),
                                release.version))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\u{2022}").font(.caption).foregroundStyle(.tertiary)
                            Text(item).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
            if !state.claudeCLI.path.isEmpty {
                Text(state.claudeCLI.path)
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .onAppear { state.refreshCLIUpdate() }
    }

    /// "One session is still on 2.1.227." / "3 sessions are still on an older
    /// version." Pure so the phrasing is testable.
    static func olderSessionsNote(_ sessions: [LiveSession]) -> String {
        let versions = Set(sessions.map(\.cliVersion))
        if sessions.count == 1, let only = versions.first {
            return String(format: L("One running session is still on %@. It picks up the new version when you restart it.",
                                    comment: "Settings note. %@ is a version number"), only)
        }
        if versions.count == 1, let only = versions.first {
            return String(format: L("%1$d running sessions are still on %2$@. They pick up the new version when you restart them.",
                                    comment: "Settings note. %1$d is a count, %2$@ a version number"),
                          sessions.count, only)
        }
        return String(format: L("%d running sessions are still on an older version. They pick it up when you restart them.",
                                comment: "Settings note. %d is a count of sessions"), sessions.count)
    }
}
