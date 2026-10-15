import Foundation
import AppKit

// Skills: what Claude Code has loaded into every session, what it costs, and
// the switches to turn it down. The scanning is in SkillsReader, the settings
// writes in SkillSettings, the trash in SkillTrash; this is the glue and the
// rules, the rules as pure statics so tests can pin them.

extension AppState {
    /// Where a state change is written.
    enum SkillScope { case everywhere, project }

    // MARK: - Rules (pure)

    /// The state a skill is in: a plugin's skills follow the plugin; a
    /// project skill takes its project's local override first; anything with
    /// no override is on. A skill whose own frontmatter hides it from Claude
    /// reads as "only when I type it".
    nonisolated static func visibility(of skill: SkillInfo, user: [String: SkillSettings.Visibility],
                                       project: [String: SkillSettings.Visibility]?, pluginEnabled: [String: Bool]) -> SkillSettings.Visibility {
        if skill.source == .plugin { return (pluginEnabled[skill.plugin ?? ""] ?? true) ? .on : .off }
        let v = project?[skill.overrideKey] ?? user[skill.overrideKey] ?? .on
        if v == .on && skill.modelInvocationDisabled { return .userOnly }
        return v
    }

    /// Characters a skill puts in the listing Claude reads every turn, in a state.
    nonisolated static func listedChars(_ skill: SkillInfo, _ vis: SkillSettings.Visibility) -> Int {
        switch vis {
        case .on: return skill.listingChars
        case .nameOnly: return skill.modelInvocationDisabled ? 0 : skill.name.count + 4
        case .userOnly, .off: return 0
        }
    }

    /// The listing's budget in tokens: Claude Code gives it 1% of the model's
    /// context window (configurable with `skillListingBudgetFraction`).
    nonisolated static func listingBudgetTokens(contextWindow: Int, fraction: Double = 0.01) -> Int {
        Int(Double(contextWindow) * fraction)
    }

    /// Skills worth turning down: on, not hidden by their own frontmatter,
    /// not from a plugin (those go with their plugin), never seen running,
    /// and costing at least `minTokens`. Most expensive first.
    nonisolated static func suggestions(_ skills: [SkillInfo], states: [String: SkillSettings.Visibility],
                                        usage: [String: SkillUse], minTokens: Int = 60) -> [SkillInfo] {
        skills.filter { s in
            s.source != .plugin && states[s.id] == .on && SkillUse.lookup(usage, name: s.name) == nil && s.listingTokens >= minTokens
        }.sorted { $0.listingTokens > $1.listingTokens }
    }

    /// One source of skills, summarised as a single row: a plugin, a
    /// project, your personal folder, or claude.ai. The page shows these and
    /// keeps the individual skills folded away until asked.
    struct SkillGroupSummary: Identifiable, Equatable {
        enum Kind: Equatable { case personal, project(String), synced, plugin(String) }
        let id: String
        let kind: Kind
        let title: String
        let subtitle: String
        let items: [SkillInfo]
        /// Tokens the group puts in every turn as things stand.
        let tokens: Int
        /// The state every skill in it shares, or nil when they differ.
        let state: SkillSettings.Visibility?
    }

    nonisolated static func skillGroups(_ skills: [SkillInfo], states: [String: SkillSettings.Visibility],
                                        pluginDescriptions: [String: String]) -> [SkillGroupSummary] {
        func summary(_ id: String, _ kind: SkillGroupSummary.Kind, _ title: String, _ subtitle: String, _ items: [SkillInfo]) -> SkillGroupSummary {
            let vs = items.map { states[$0.id] ?? .on }
            let tokens = zip(items, vs).reduce(0) { $0 + (listedChars($1.0, $1.1) + 3) / 4 }
            return SkillGroupSummary(id: id, kind: kind, title: title, subtitle: subtitle, items: items, tokens: tokens,
                                     state: Set(vs).count == 1 ? vs.first : nil)
        }
        var out: [SkillGroupSummary] = []
        let personal = skills.filter { $0.source == .personal }
        if !personal.isEmpty { out.append(summary("personal", .personal, L("Your skills", comment: "Skill group"), L("Skills you added to ~/.claude/skills", comment: "Skill group subtitle"), personal)) }
        let synced = skills.filter { $0.source == .synced }
        if !synced.isEmpty { out.append(summary("synced", .synced, L("From claude.ai", comment: "Skill group"), L("Synced from your claude.ai account", comment: "Skill group subtitle"), synced)) }
        for p in Array(Set(skills.compactMap(\.project))).sorted() {
            out.append(summary("project:" + p, .project(p), (p as NSString).lastPathComponent, L("Skills in this project's .claude/skills", comment: "Skill group subtitle"), skills.filter { $0.project == p }))
        }
        for id in Array(Set(skills.compactMap(\.plugin))).sorted() {
            let name = String(id.split(separator: "@").first ?? Substring(id))
            out.append(summary("plugin:" + id, .plugin(id), name.prefix(1).uppercased() + name.dropFirst(),
                               pluginDescriptions[id] ?? L("A plugin you installed", comment: "Skill group subtitle"), skills.filter { $0.plugin == id }))
        }
        return out.sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.title < $1.title }
    }

    // MARK: - State

    func skillVisibility(_ skill: SkillInfo) -> SkillSettings.Visibility {
        Self.visibility(of: skill, user: skillOverridesUser, project: skill.project.flatMap { skillOverridesProject[$0] }, pluginEnabled: pluginEnabled)
    }
    /// Keyed by skill folder. Built with a merge, never `uniqueKeysWithValues`:
    /// a duplicate there is a trap that takes the whole app down.
    var skillStates: [String: SkillSettings.Visibility] { Dictionary(skills.map { ($0.id, skillVisibility($0)) }, uniquingKeysWith: { a, _ in a }) }
    var skillsListedTokens: Int { skills.reduce(0) { $0 + (Self.listedChars($1, skillVisibility($1)) + 3) / 4 } }
    var skillSuggestions: [SkillInfo] { Self.suggestions(skills, states: skillStates, usage: skillUsage) }
    var skillGroupSummaries: [SkillGroupSummary] { Self.skillGroups(skills, states: skillStates, pluginDescriptions: pluginDescriptions) }

    /// Read everything again, off the main thread.
    func refreshSkills() {
        skillsScanning = true
        let projects = recentProjects
        Task.detached(priority: .userInitiated) {
            let found = SkillsReader.scan(projects: projects)
            let trash = SkillTrash.list()
            let user = SkillSettings.overrides(at: SkillSettings.userSettingsPath)
            var perProject: [String: [String: SkillSettings.Visibility]] = [:]
            for p in Set(found.compactMap(\.project)) { perProject[p] = SkillSettings.overrides(at: SkillSettings.projectLocalPath(p)) }
            let plugins = SkillSettings.enabledPlugins(), projectOverrides = perProject, descriptions = SkillsReader.pluginDescriptions()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.skills = found; self.skillTrash = trash
                self.skillOverridesUser = user; self.skillOverridesProject = projectOverrides
                self.pluginEnabled = plugins; self.pluginDescriptions = descriptions; self.skillsScanning = false
            }
        }
    }

    /// Set a skill's state. A project skill can be set for its project only
    /// (its `.claude/settings.local.json`, where `/skills` writes) or everywhere.
    func setSkillVisibility(_ skill: SkillInfo, _ vis: SkillSettings.Visibility, scope: SkillScope = .everywhere) {
        guard skill.source != .plugin else { return }
        let path = scope == .project && skill.project != nil ? SkillSettings.projectLocalPath(skill.project!) : SkillSettings.userSettingsPath
        do {
            try SkillSettings.setVisibility(vis, for: skill.overrideKey, at: path)
            skillsMessage = nil
        } catch { skillsMessage = error.localizedDescription }
        refreshSkills()
    }

    /// Several at once, for "free up context". Everywhere, in user settings.
    func setSkillsVisibility(_ list: [SkillInfo], _ vis: SkillSettings.Visibility) {
        for s in list where s.source != .plugin {
            do { try SkillSettings.setVisibility(vis, for: s.overrideKey, at: s.source == .project && s.project != nil ? SkillSettings.projectLocalPath(s.project!) : SkillSettings.userSettingsPath) }
            catch { skillsMessage = error.localizedDescription; break }
        }
        refreshSkills()
    }

    func setPluginEnabled(_ id: String, _ on: Bool) {
        do { try SkillSettings.setPlugin(id, enabled: on); skillsMessage = nil } catch { skillsMessage = error.localizedDescription }
        refreshSkills()
    }

    func trashSkill(_ skill: SkillInfo) {
        do { try SkillTrash.trash(skill); skillsMessage = nil } catch { skillsMessage = error.localizedDescription }
        refreshSkills()
    }

    func restoreSkill(_ entry: SkillTrash.Entry) {
        do { try SkillTrash.restore(entry); skillsMessage = nil } catch { skillsMessage = error.localizedDescription }
        refreshSkills()
    }

    // MARK: - Usage

    /// A skill ran (Claude invoked it, or you typed it). Capped at
    /// `SkillUse.cap` names, dropping the least recently used.
    func recordSkillUse(_ rawName: String?) {
        guard let name = SkillUse.normalize(rawName) else { return }
        var u = skillUsage[name] ?? SkillUse(count: 0, last: Date())
        u.count += 1; u.last = Date()
        skillUsage[name] = u
        if skillUsage.count > SkillUse.cap,
           let oldest = skillUsage.min(by: { $0.value.last < $1.value.last })?.key { skillUsage[oldest] = nil }
        schedulePersist()
    }

    // MARK: - Finder

    func revealSkill(_ skill: SkillInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.path)])
    }
    func openSkillFile(_ skill: SkillInfo) {
        NSWorkspace.shared.open(URL(fileURLWithPath: (skill.path as NSString).appendingPathComponent("SKILL.md")))
    }
}
