import SwiftUI
import AppKit

// The Skills page: every skill Claude Code loads, what each one costs in the
// listing Claude reads on every turn, and the switches to turn them down,
// delete them safely, or bring them back from the trash.

extension SettingsView {
    var skillsPage: some View {
        page(L("Skills", comment: "Settings page title")) {
            Text(L("Claude Code lists the name and description of every skill to Claude on every turn, used or not. Turn down the ones you don't need to give that context back. Changes apply to new sessions.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)

            skillBudgetCard
            if !state.skillSuggestions.isEmpty { skillSuggestionsCard }

            HStack(spacing: 10) {
                SearchField(placeholder: L("Search skills", comment: "Search field placeholder"), text: $skillQuery)
                Picker("", selection: $skillFilter) {
                    Text(L("All", comment: "Skills filter")).tag(SkillInfo.Source?.none)
                    ForEach(SkillInfo.Source.allCases, id: \.self) { s in Text(Self.skillSourceLabel(s)).tag(SkillInfo.Source?.some(s)) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                Button { state.refreshSkills() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("Scan again", comment: "Tooltip: rescan skills"))
            }

            if let msg = state.skillsMessage {
                Label(msg, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }

            if state.skills.isEmpty {
                group {
                    HStack { Text(state.skillsScanning ? L("Looking for skills...", comment: "Skills page while scanning") : L("No skills found.", comment: "Skills page empty state")).foregroundStyle(.secondary); Spacer() }
                        .padding(.vertical, 10).padding(.horizontal, 14)
                }
            } else {
                ForEach(skillGroups, id: \.title) { grp in
                    sectionLabel(grp.title)
                    if let plugin = grp.plugin { pluginHeader(plugin, count: grp.items.count) }
                    group {
                        ForEach(Array(grp.items.enumerated()), id: \.element.id) { i, s in
                            if i > 0 { divider }
                            skillRow(s)
                        }
                    }
                }
            }

            if !state.skillTrash.isEmpty { skillTrashSection }

            Text(L("Plugin skills turn off with their plugin. Skills from claude.ai come back if deleted here, so they can only be hidden. Usage counts start from when ClaudeNotch began watching.", comment: "Skills page footnote"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { state.refreshSkills() }
        .alert(item: $skillPendingTrash) { s in
            Alert(title: Text(String(format: L("Move %@ to the trash?", comment: "Confirm deleting a skill. %@ is its name"), s.name)),
                  message: Text(L("It goes to Claude Code's skills trash and can be restored from this page for 30 days.", comment: "Confirm deleting a skill, explanation")),
                  primaryButton: .destructive(Text(L("Move to Trash", comment: "Button"))) { state.trashSkill(s) },
                  secondaryButton: .cancel())
        }
    }

    static func skillSourceLabel(_ s: SkillInfo.Source) -> String {
        switch s {
        case .personal: return L("Personal", comment: "Skill source")
        case .project: return L("Project", comment: "Skill source")
        case .synced: return L("claude.ai", comment: "Skill source")
        case .plugin: return L("Plugin", comment: "Skill source")
        }
    }

    // MARK: groups

    private struct SkillGroup { let title: String; let plugin: String?; let items: [SkillInfo] }

    private var skillGroups: [SkillGroup] {
        let q = skillQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = state.skills.filter { s in
            (skillFilter == nil || s.source == skillFilter) &&
            (q.isEmpty || s.name.lowercased().contains(q) || s.description.lowercased().contains(q))
        }
        var out: [SkillGroup] = []
        let personal = shown.filter { $0.source == .personal }
        if !personal.isEmpty { out.append(SkillGroup(title: L("Personal", comment: "Skill group"), plugin: nil, items: personal)) }
        for p in Array(Set(shown.compactMap(\.project))).sorted() {
            out.append(SkillGroup(title: String(format: L("Project: %@", comment: "Skill group. %@ is the project folder name"), (p as NSString).lastPathComponent), plugin: nil, items: shown.filter { $0.project == p }))
        }
        let synced = shown.filter { $0.source == .synced }
        if !synced.isEmpty { out.append(SkillGroup(title: L("From claude.ai", comment: "Skill group"), plugin: nil, items: synced)) }
        for p in Array(Set(shown.compactMap(\.plugin))).sorted() {
            out.append(SkillGroup(title: String(format: L("Plugin: %@", comment: "Skill group. %@ is the plugin id"), p), plugin: p, items: shown.filter { $0.plugin == p }))
        }
        return out
    }

    // MARK: budget

    private var skillBudgetCard: some View {
        let used = state.skillsListedTokens
        let budget = AppState.listingBudgetTokens(contextWindow: 1_000_000), small = AppState.listingBudgetTokens(contextWindow: 200_000)
        let p = min(1, Double(used) / Double(budget))
        return group {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: L("About %@ tokens of skills in every turn", comment: "Skills budget headline. %@ is a number"), used.formatted()))
                        .font(.headline)
                    Spacer()
                    Text(String(format: L("%d skills", comment: "Count of skills"), state.skills.count)).foregroundStyle(.secondary)
                }
                ProgressView(value: p).tint(p > 0.9 ? .red : p > 0.7 ? .orange : .accentColor)
                Text(String(format: L("Claude Code gives the skill listing about 1%% of the context window: %@ tokens on a 1M-token model, %@ on a 200K one. Past that it cuts descriptions, starting with the skills used least.", comment: "Skills budget explanation. Two numbers"), budget.formatted(), small.formatted()))
                    .font(.caption).foregroundStyle(.secondary)
                if used > small {
                    Label(L("Over the budget of a 200K-token model: on those, some descriptions are being cut.", comment: "Skills budget warning"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
        }
    }

    private var skillSuggestionsCard: some View {
        let list = state.skillSuggestions
        let saved = list.reduce(0) { $0 + $1.listingTokens - ($1.name.count + 7) / 4 }
        return group {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L("%d skills haven't run since ClaudeNotch started watching", comment: "Skill suggestion headline. %d is a count"), list.count)).font(.callout.weight(.semibold))
                    Text(String(format: L("Set them to Name only and get back about %@ tokens every turn: %@", comment: "Skill suggestion detail. First %@ is tokens, second the skill names"), saved.formatted(), list.prefix(4).map(\.name).joined(separator: ", ") + (list.count > 4 ? "..." : "")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(L("Name only", comment: "Button: set suggested skills to name only")) { state.setSkillsVisibility(list, .nameOnly) }
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
        }
    }

    // MARK: rows

    private func pluginHeader(_ id: String, count: Int) -> some View {
        let on = state.pluginEnabled[id] ?? true
        return HStack {
            Text(String(format: L("%d skills, on or off together with the plugin", comment: "Plugin row. %d is a count"), count)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Toggle(L("Plugin enabled", comment: "Toggle for a plugin"), isOn: Binding(get: { on }, set: { state.setPluginEnabled(id, $0) }))
                .toggleStyle(.switch).controlSize(.small)
        }
    }

    private func skillRow(_ s: SkillInfo) -> some View {
        let vis = state.skillVisibility(s)
        let use = SkillUse.lookup(state.skillUsage, name: s.name)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.name).font(.body.weight(.medium)).lineLimit(1)
                    if vis != .on {
                        Text(vis.label).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                if !s.description.isEmpty {
                    Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 10) {
                    Text(String(format: L("~%d tokens per turn", comment: "Skill context cost"), (AppState.listedChars(s, vis) + 3) / 4))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(s.bytes), countStyle: .file))
                    if let use {
                        Text(String(format: L("ran %d times, last %@", comment: "Skill usage. %d count, %@ relative time"), use.count, use.last.formatted(.relative(presentation: .named))))
                    } else {
                        Text(L("not seen running", comment: "Skill usage: none recorded"))
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if s.source != .plugin {
                Menu {
                    ForEach(SkillSettings.Visibility.allCases) { v in
                        Button { state.setSkillVisibility(s, v, scope: s.source == .project ? .project : .everywhere) } label: {
                            if v == vis { Label(v.label, systemImage: "checkmark") } else { Text(v.label) }
                        }
                        .help(v.help)
                    }
                } label: { Text(vis.label) }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Menu {
                Button(L("Reveal in Finder", comment: "Skill menu")) { state.revealSkill(s) }
                Button(L("Open SKILL.md", comment: "Skill menu")) { state.openSkillFile(s) }
                if s.canTrash {
                    Divider()
                    Button(L("Move to Trash...", comment: "Skill menu"), role: .destructive) { skillPendingTrash = s }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.vertical, 9).padding(.horizontal, 14)
    }

    // MARK: trash

    private var skillTrashSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(L("Trash", comment: "Skills trash heading"))
            group {
                ForEach(Array(state.skillTrash.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { divider }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(.body.weight(.medium))
                            Text(e.daysLeft.map { String(format: L("Deleted for good in %d days", comment: "Skill trash entry. %d days"), $0) } ?? L("In the trash", comment: "Skill trash entry with no date"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Restore", comment: "Button: restore a skill from the trash")) { state.restoreSkill(e) }
                    }
                    .padding(.vertical, 8).padding(.horizontal, 14)
                }
            }
        }
    }
}
