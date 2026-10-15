import SwiftUI
import AppKit

// The Skills page, kept short: one line on what skills cost, then one row per
// source (a plugin, a project, your own, claude.ai) with a single switch for
// the whole group. The individual skills stay folded away until you open a
// row, and each one is a single line when you do. Search shows a flat list.

extension SettingsView {
    var skillsPage: some View {
        page(L("Skills", comment: "Settings page title")) {
            Text(L("Every skill adds a little to each Claude turn, even unused ones. Turn off what you don't need.", comment: "Skills page one-line explanation"))
                .font(.callout).foregroundStyle(.secondary)

            skillSummaryBar

            SearchField(placeholder: L("Search skills", comment: "Search field placeholder"), text: $skillQuery)

            if let msg = state.skillsMessage {
                Label(msg, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }

            if state.skills.isEmpty {
                group {
                    HStack { Text(state.skillsScanning ? L("Looking for skills...", comment: "Skills page while scanning") : L("No skills found.", comment: "Skills page empty state")).foregroundStyle(.secondary); Spacer() }
                        .padding(.vertical, 10).padding(.horizontal, 14)
                }
            } else if !skillQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                skillSearchResults
            } else {
                group {
                    ForEach(Array(state.skillGroupSummaries.enumerated()), id: \.element.id) { i, grp in
                        if i > 0 { divider }
                        skillGroupRow(grp)
                        if expandedSkillGroups.contains(grp.id) {
                            ForEach(grp.items) { s in compactSkillRow(s, inGroup: true) }
                                .padding(.leading, 28)
                        }
                    }
                }
            }

            if !state.skillTrash.isEmpty { skillTrashRow }
        }
        .onAppear { state.refreshSkills() }
        .alert(item: $skillPendingTrash) { s in
            Alert(title: Text(String(format: L("Move %@ to the trash?", comment: "Confirm deleting a skill. %@ is its name"), s.name)),
                  message: Text(L("You can restore it from this page for 30 days.", comment: "Confirm deleting a skill, explanation")),
                  primaryButton: .destructive(Text(L("Move to Trash", comment: "Button"))) { state.trashSkill(s) },
                  secondaryButton: .cancel())
        }
    }

    // MARK: summary

    /// One card: the total, a slim bar, and the single most useful action.
    private var skillSummaryBar: some View {
        let used = state.skillsListedTokens, budget = AppState.listingBudgetTokens(contextWindow: 1_000_000)
        let p = min(1, Double(used) / Double(budget))
        let suggestions = state.skillSuggestions
        let saved = suggestions.reduce(0) { $0 + $1.listingTokens - ($1.name.count + 7) / 4 }
        return group {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: L("~%@ tokens per turn", comment: "Skills total. %@ is a number"), used.formatted())).font(.headline)
                    Text(String(format: L("from %d skills", comment: "Skills total, count"), state.skills.count)).foregroundStyle(.secondary)
                    Spacer()
                    if !suggestions.isEmpty {
                        Button(String(format: L("Free up ~%@", comment: "Button: shrink unused skills. %@ is tokens"), saved.formatted())) {
                            state.setSkillsVisibility(suggestions, .nameOnly)
                        }
                        .help(String(format: L("Set %d skills that never ran to Name only: %@", comment: "Tooltip. %d count, %@ names"), suggestions.count, suggestions.map(\.name).joined(separator: ", ")))
                    }
                }
                ProgressView(value: p).tint(p > 0.9 ? .red : p > 0.7 ? .orange : .accentColor)
                    .help(String(format: L("Claude Code keeps about %@ tokens for skills on a 1M-token model. Past that, descriptions get cut.", comment: "Tooltip on the skills bar. %@ is a number"), budget.formatted()))
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
        }
    }

    // MARK: groups

    private func skillGroupIcon(_ k: AppState.SkillGroupSummary.Kind) -> String {
        switch k {
        case .personal: return "person.crop.circle"
        case .synced: return "icloud"
        case .project: return "folder"
        case .plugin: return "puzzlepiece.extension"
        }
    }

    private func skillGroupRow(_ grp: AppState.SkillGroupSummary) -> some View {
        let open = expandedSkillGroups.contains(grp.id)
        return HStack(spacing: 10) {
            Button {
                if open { expandedSkillGroups.remove(grp.id) } else { expandedSkillGroups.insert(grp.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                    Image(systemName: skillGroupIcon(grp.kind)).foregroundStyle(Color.accentColor).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(grp.title).font(.body.weight(.semibold))
                            Text(String(format: L("%d skills", comment: "Count of skills"), grp.items.count)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(grp.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(String(format: L("~%@ tok", comment: "Tokens, short. %@ is a number"), grp.tokens.formatted()))
                .font(.caption.monospacedDigit()).foregroundStyle(grp.tokens > 0 ? .secondary : .tertiary)
                .frame(minWidth: 64, alignment: .trailing)

            groupControl(grp)
        }
        .padding(.vertical, 9).padding(.horizontal, 14)
    }

    /// A plugin is a switch (its skills only turn off with it); any other
    /// group is a menu that sets every skill in it at once.
    @ViewBuilder
    private func groupControl(_ grp: AppState.SkillGroupSummary) -> some View {
        if case .plugin(let id) = grp.kind {
            Toggle("", isOn: Binding(get: { state.pluginEnabled[id] ?? true }, set: { state.setPluginEnabled(id, $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help(L("Turns the whole plugin on or off, with all its skills", comment: "Tooltip on a plugin switch"))
        } else {
            Menu {
                ForEach(SkillSettings.Visibility.allCases) { v in
                    Button(v.label) { state.setSkillsVisibility(grp.items, v) }.help(v.help)
                }
            } label: { Text(grp.state?.label ?? L("Mixed", comment: "Skill group state when its skills differ")) }
            .menuStyle(.borderlessButton).fixedSize()
            .help(L("Set every skill in this group", comment: "Tooltip on a skill group menu"))
        }
    }

    // MARK: rows

    /// A skill on one line: name (description on hover), its cost, whether it
    /// has run, its state, and a menu for the rest.
    private func compactSkillRow(_ s: SkillInfo, inGroup: Bool) -> some View {
        let vis = state.skillVisibility(s)
        let use = SkillUse.lookup(state.skillUsage, name: s.name)
        let shown = inGroup ? (s.name.split(separator: ":").last.map(String.init) ?? s.name) : s.name
        return HStack(spacing: 8) {
            Circle().fill(use == nil ? Color.secondary.opacity(0.3) : Color.green).frame(width: 6, height: 6)
                .help(use.map { String(format: L("Ran %d times, last %@", comment: "Skill usage. %d count, %@ relative time"), $0.count, $0.last.formatted(.relative(presentation: .named))) }
                      ?? L("Not seen running yet", comment: "Skill usage: none recorded"))
            Text(shown).lineLimit(1).foregroundStyle(vis == .off ? .secondary : .primary)
                .help(s.description.isEmpty ? s.name : s.description)
            Spacer(minLength: 8)
            Text(String(format: L("~%@ tok", comment: "Tokens, short. %@ is a number"), ((AppState.listedChars(s, vis) + 3) / 4).formatted()))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            if s.source != .plugin {
                Menu {
                    ForEach(SkillSettings.Visibility.allCases) { v in
                        Button { state.setSkillVisibility(s, v, scope: s.source == .project ? .project : .everywhere) } label: {
                            if v == vis { Label(v.label, systemImage: "checkmark") } else { Text(v.label) }
                        }
                    }
                } label: { Text(vis.label).font(.caption) }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Menu {
                Button(L("Reveal in Finder", comment: "Skill menu")) { state.revealSkill(s) }
                Button(L("Open SKILL.md", comment: "Skill menu")) { state.openSkillFile(s) }
                if s.canTrash {
                    Divider()
                    Button(L("Move to Trash...", comment: "Skill menu"), role: .destructive) { skillPendingTrash = s }
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .font(.callout)
        .padding(.vertical, 5).padding(.horizontal, 14)
    }

    private var skillSearchResults: some View {
        let q = skillQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = state.skills.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
        return group {
            if hits.isEmpty {
                HStack { Text(L("No matching skills.", comment: "Skills search empty")).foregroundStyle(.secondary); Spacer() }
                    .padding(.vertical, 10).padding(.horizontal, 14)
            } else {
                ForEach(hits) { s in compactSkillRow(s, inGroup: false) }
            }
        }
    }

    // MARK: trash

    private var skillTrashRow: some View {
        group {
            Button { showSkillTrash.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showSkillTrash ? 90 : 0)).frame(width: 10)
                    Image(systemName: "trash").foregroundStyle(.secondary).frame(width: 18)
                    Text(String(format: L("Trash (%d)", comment: "Skills trash row. %d is a count"), state.skillTrash.count))
                    Spacer()
                    Text(L("kept 30 days", comment: "Skills trash retention")).font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 9).padding(.horizontal, 14)
            if showSkillTrash {
                ForEach(state.skillTrash) { e in
                    HStack(spacing: 8) {
                        Text(e.name).lineLimit(1)
                        Spacer()
                        if let d = e.daysLeft {
                            Text(String(format: L("%d days left", comment: "Skill trash entry. %d days"), d)).font(.caption).foregroundStyle(.secondary)
                        }
                        Button(L("Restore", comment: "Button: restore a skill from the trash")) { state.restoreSkill(e) }.controlSize(.small)
                    }
                    .font(.callout)
                    .padding(.vertical, 5).padding(.horizontal, 14).padding(.leading, 28)
                }
            }
        }
    }
}
