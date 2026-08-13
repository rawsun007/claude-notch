import SwiftUI
import AppKit

// The Rules page: the always-allow list you have been building by clicking
// "Always Allow", finally somewhere you can read it.
//
// These rules decide what runs without asking you, which makes them the app's
// security policy. A policy you can only see through a menu-bar submenu, and
// only change by deleting one row at a time, is a policy nobody audits.

extension SettingsView {
    var rules: some View {
        page(L("Rules", comment: "Settings page title")) {
            Text(L("Every time you click Always Allow, a rule lands here. Matching requests are approved without asking, so this is worth reading now and then.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)

            if state.allowRules.isEmpty {
                group {
                    HStack {
                        Text(L("No rules yet. Click Always Allow on a permission card to add one.", comment: "Settings empty state for the rules list"))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                }
            } else {
                ruleList
            }

            addRuleSection

            if !state.allowRules.isEmpty {
                exportSection
                HStack {
                    Spacer()
                    Button(L("Remove all rules", comment: "Settings button: delete every allow rule"), role: .destructive) {
                        state.clearAllowlist()
                    }
                    .foregroundStyle(.red)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - The list

    private var ruleList: some View {
        let list = state.sortedAllowRules
        return group {
            ForEach(Array(list.enumerated()), id: \.element.id) { idx, rule in
                ruleRow(rule)
                if idx < list.count - 1 { divider }
            }
        }
    }

    private func ruleRow(_ rule: AllowRule) -> some View {
        HStack(spacing: 10) {
            // A tool-wide rule is the broad one: it approves every call of that
            // tool forever, so it is the row you most want to notice.
            Image(systemName: rule.commandRegex == nil ? "exclamationmark.shield" : "checkmark.shield")
                .foregroundStyle(rule.commandRegex == nil ? .orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.tool).font(.body.weight(.medium))
                if let command = rule.literalCommand {
                    // The rule still MATCHES on the true command; only the
                    // printing of it is redacted.
                    Text(SecretRedactor.redact(command))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } else if let pattern = rule.commandRegex {
                    Text(String(format: L("matching /%@/", comment: "Rules list subtitle for a pattern rule. %@ is a regular expression"), pattern))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(L("every call of this tool", comment: "Rules list subtitle for a tool-wide rule"))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Button {
                state.removeAllowRule(rule)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Remove this rule, matching prompts will ask again", comment: "Tooltip on the delete button in the rules list"))
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
    }

    // MARK: - Adding one by hand

    private var addRuleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(L("Add a rule", comment: "Settings section heading"))
            group {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField(L("Tool, e.g. Bash", comment: "Placeholder in the new-rule tool field"),
                                  text: $newRuleTool)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        TextField(L("Exact command, leave blank for the whole tool", comment: "Placeholder in the new-rule command field"),
                                  text: $newRuleCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button(L("Add", comment: "Settings button: create the rule")) { addRule() }
                            .disabled(newRuleTool.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let note = newRuleNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    // Saying this once here is cheaper than a support thread
                    // about a rule that "did nothing".
                    Text(L("The command must match exactly, the way it appeared on the card. A blank command approves every call of the tool.", comment: "Explanation under the new-rule fields"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 10).padding(.horizontal, 14)
            }
        }
    }

    private func addRule() {
        let added = state.addAllowRule(tool: newRuleTool, command: newRuleCommand)
        newRuleNote = added
            ? nil
            : L("That rule is already in the list.", comment: "Note shown when a typed rule is a duplicate")
        if added {
            newRuleTool = ""
            newRuleCommand = ""
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        let skipped = AppState.unexportableRules(state.sortedAllowRules)
        let renamed = AppState.renamedOnExport(state.sortedAllowRules)
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel(L("Give these to Claude Code", comment: "Settings section heading"))
            group {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Claude Code keeps its own allowlist in ~/.claude/settings.json. Copy these rules across so a terminal session the notch is not watching stops asking too.", comment: "Explanation of the rule export"))
                        .font(.callout).foregroundStyle(.secondary)
                    if !skipped.isEmpty {
                        Text(String(format: L("%d rule(s) use a pattern Claude Code cannot express, and are left out rather than approximated.", comment: "Warning about rules that cannot be exported. %d is how many"), skipped.count))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !renamed.isEmpty {
                        Text(String(format: L("%d rule(s) are exported as Edit or Read: Claude Code deprecated the Write, NotebookEdit and Glob forms and warns at startup about them.", comment: "Note about rules whose tool name changes on export. %d is how many"), renamed.count))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button(rulesCopied
                               ? L("Copied", comment: "Button state right after copying to the clipboard")
                               : L("Copy as JSON", comment: "Settings button: put the export on the clipboard")) {
                            state.copyAllowRulesAsJSON()
                            rulesCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { rulesCopied = false }
                        }
                        Button(L("Add to settings.json", comment: "Settings button: merge the rules into Claude Code's settings")) {
                            mergeRules()
                        }
                        Spacer()
                    }
                    if let result = mergeResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10).padding(.horizontal, 14)
            }
        }
    }

    private func mergeRules() {
        guard let added = state.mergeAllowRulesIntoClaudeSettings() else {
            mergeResult = L("Could not write ~/.claude/settings.json. It exists but is not valid JSON, so nothing was changed.", comment: "Error after a failed rule merge")
            return
        }
        mergeResult = added == 0
            ? L("Claude Code already had all of them. A backup was saved anyway.", comment: "Result when the merge added nothing")
            : String(format: L("Added %d to ~/.claude/settings.json. The previous file was backed up beside it.", comment: "Result after merging rules. %d is how many were added"), added)
    }
}
