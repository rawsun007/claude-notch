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
                    Text("Version \(Self.appVersion)")
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
}
