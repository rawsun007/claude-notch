import AppKit

// The submenus that change a setting rather than report one: notch title,
// status-bar items, cost budget, auto-approve, snooze and sounds. They are all
// the same shape, a list of rows that check the current value and set a new one.

extension MenuBarController {
    func refreshNotchTitleMenu() {
        notchTitleMenu.removeAllItems()
        // Submenu title reflects the current choice (and the resolved label).
        // With no session running there is no project to resolve, and showing the
        // "Claude" fallback here reads as though the setting did not take. Say
        // what is actually going on instead.
        let resolved: String = {
            if state.notchTitleMode == .project, state.currentProject.isEmpty {
                return "Project name (no session yet)"
            }
            return state.entityName
        }()
        notchTitleItem.title = "Notch Title: \(resolved)"

        func row(_ title: String, mode: NotchTitleMode, action: Selector) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            mi.state = state.notchTitleMode == mode ? .on : .off
            notchTitleMenu.addItem(mi)
        }
        row("Claude", mode: .claude, action: #selector(setNotchTitleClaude))
        row("Project name", mode: .project, action: #selector(setNotchTitleProject))
        let customLabel = state.customNotchTitle.isEmpty
            ? "Custom…"
            : "Custom: \(state.customNotchTitle)…"
        row(customLabel, mode: .custom, action: #selector(setNotchTitleCustom))
    }

    func refreshStatusBarMenu() {
        statusBarMenu.removeAllItems()

        func header(_ s: String) {
            let mi = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            statusBarMenu.addItem(mi)
        }

        // Title: show labels of selected items.
        let selectedLabels = state.statusBarItems.map(\.barLabel)
        statusBarItem.title = selectedLabels.isEmpty
            ? "Status Bar: off"
            : "Status Bar: \(selectedLabels.joined(separator: " · "))"

        // Item checkboxes — max 2 selected. Disable unselected items when full.
        let selected = state.statusBarItems
        let full = selected.count >= 2
        header("Show in bar (pick up to 2)")
        for (idx, item) in StatusBarItem.allCases.enumerated() {
            let isOn = selected.contains(item)
            let mi = NSMenuItem(title: item.menuLabel,
                                action: #selector(toggleStatusBarItemAction(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.tag = idx
            mi.state = isOn ? .on : .off
            mi.isEnabled = isOn || !full   // grey out unchosen items when 2 already selected
            statusBarMenu.addItem(mi)
        }
        if selected.contains(.fiveHourLimit) || selected.contains(.weeklyLimit) {
            let note = NSMenuItem(title: "  plan limits need the status-line forwarder (auto-installed)", action: nil, keyEquivalent: "")
            note.isEnabled = false
            statusBarMenu.addItem(note)
        }

        // Context-window denominator override (affects the context bar, not the status row).
        statusBarMenu.addItem(.separator())
        header("Context window")
        let windows: [(String, Int, Bool)] = [
            ("Auto (detect from model)", 0, state.contextWindowMode == .auto),
            ("200K", 1, state.contextWindowMode == .w200k),
            ("1M", 2, state.contextWindowMode == .w1M),
        ]
        for (label, tag, on) in windows {
            let mi = NSMenuItem(title: label, action: #selector(setContextWindowModeAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = tag
            mi.state = on ? .on : .off
            statusBarMenu.addItem(mi)
        }
    }

    func refreshCostBudgetMenu() {
        costBudgetMenu.removeAllItems()
        let mn = ClaudeUsageReader.fmtMoney

        // Title reflects whichever caps are set.
        var parts: [String] = []
        if state.sessionCostCap > 0 { parts.append("session \(mn(state.sessionCostCap))") }
        if state.dailyCostCap > 0 { parts.append("daily \(mn(state.dailyCostCap))") }
        costBudgetItem.title = parts.isEmpty ? "Cost Budget" : "Cost Budget: \(parts.joined(separator: ", "))"

        func header(_ s: String) {
            let mi = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            costBudgetMenu.addItem(mi)
        }
        func caps(_ title: String, current: Double, action: Selector, presets: [Int], spent: Double) {
            header(title)
            // Current spend line.
            let spentItem = NSMenuItem(title: "  spent so far: ~\(mn(spent))", action: nil, keyEquivalent: "")
            spentItem.isEnabled = false
            costBudgetMenu.addItem(spentItem)
            // Off + presets, with a checkmark on the active one.
            for dollars in [0] + presets {
                let label = dollars == 0 ? "Off" : "$\(dollars)"
                let mi = NSMenuItem(title: label, action: action, keyEquivalent: "")
                mi.target = self
                mi.tag = dollars
                mi.state = Int(current.rounded()) == dollars ? .on : .off
                costBudgetMenu.addItem(mi)
            }
        }

        caps("Per-session cap, warn at 80% / 100%",
             current: state.sessionCostCap, action: #selector(setSessionCapAction(_:)),
             presets: [1, 2, 5, 10, 25], spent: state.currentCostUSD)
        costBudgetMenu.addItem(.separator())
        caps("Daily cap, across all sessions today",
             current: state.dailyCostCap, action: #selector(setDailyCapAction(_:)),
             presets: [5, 10, 25, 50, 100], spent: state.todayCostUSD)

        costBudgetMenu.addItem(.separator())
        let enforce = NSMenuItem(title: "Enforce: block new commands at 100%",
                                 action: #selector(toggleEnforceBudget), keyEquivalent: "")
        enforce.target = self
        enforce.state = state.enforceBudget ? .on : .off
        enforce.toolTip = "When a cap is reached, hold new tool calls for a decision (Deny / Allow once / Raise cap) instead of letting them run, even under auto-approve."
        costBudgetMenu.addItem(enforce)
    }

    func refreshAutoApproveMenu() {
        autoApproveMenu.removeAllItems()

        if state.autoApprove {
            if let until = state.autoApproveUntil {
                let remaining = max(0, Int(ceil(until.timeIntervalSinceNow / 60)))
                autoApproveItem.title = "Auto-Approve: On (\(remaining)m left)"
            } else {
                autoApproveItem.title = "Auto-Approve: On"
            }
        } else {
            autoApproveItem.title = "Auto-Approve"
        }

        let toggle = NSMenuItem(title: "Auto-Approve All", action: #selector(toggleAutoApprove), keyEquivalent: "")
        toggle.target = self
        toggle.state = (state.autoApprove && state.autoApproveUntil == nil) ? .on : .off
        autoApproveMenu.addItem(toggle)
        autoApproveMenu.addItem(.separator())

        for minutes in [5, 15, 30, 60] {
            let label = minutes < 60 ? "For \(minutes) minutes" : "For 1 hour"
            let mi = NSMenuItem(title: label, action: #selector(autoApproveForAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = minutes
            autoApproveMenu.addItem(mi)
        }

        if state.autoApprove {
            autoApproveMenu.addItem(.separator())
            let cancel = NSMenuItem(title: "Turn off", action: #selector(turnOffAutoApprove), keyEquivalent: "")
            cancel.target = self
            autoApproveMenu.addItem(cancel)
        }
    }

    func refreshSnoozeMenu() {
        snoozeMenu.removeAllItems()

        if let until = state.snoozedUntil, until > Date() {
            let remaining = max(0, Int(ceil(until.timeIntervalSinceNow / 60)))
            snoozeItem.title = "Snooze: \(remaining)m left"
        } else {
            snoozeItem.title = "Snooze"
        }

        let header = NSMenuItem(title: "Suppress non-blocking cards for…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        snoozeMenu.addItem(header)

        for minutes in [15, 30, 60, 120] {
            let label: String
            if minutes < 60 { label = "\(minutes) minutes" }
            else if minutes == 60 { label = "1 hour" }
            else { label = "\(minutes/60) hours" }
            let mi = NSMenuItem(title: label, action: #selector(snoozeForAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = minutes
            snoozeMenu.addItem(mi)
        }

        if state.isSnoozed {
            snoozeMenu.addItem(.separator())
            let cancel = NSMenuItem(title: "Cancel snooze", action: #selector(cancelSnoozeAction), keyEquivalent: "")
            cancel.target = self
            snoozeMenu.addItem(cancel)
        }
    }

    func refreshSoundMenu() {
        soundMenu.removeAllItems()
        soundRowViews.removeAll()

        // Mute toggle — keep-open so the user can toggle and then immediately
        // pick / preview sounds without re-opening the menu.
        let mute = KeepOpenRowView(
            title: state.soundMuted ? "Sounds Muted" : "Mute Sounds",
            checked: state.soundMuted
        )
        mute.handler = { [weak self] in
            guard let self else { return }
            self.state.setSoundMuted(!self.state.soundMuted)
            self.muteRowView?.update(
                title: self.state.soundMuted ? "Sounds Muted" : "Mute Sounds",
                checked: self.state.soundMuted
            )
        }
        let muteHolder = NSMenuItem()
        muteHolder.view = mute
        soundMenu.addItem(muteHolder)
        muteRowView = mute

        // Per-tool toggle — keep-open.
        let perTool = KeepOpenRowView(title: "Per-tool sounds", checked: state.perToolSounds)
        perTool.handler = { [weak self] in
            guard let self else { return }
            self.state.setPerToolSounds(!self.state.perToolSounds)
            self.perToolRowView?.update(title: "Per-tool sounds", checked: self.state.perToolSounds)
        }
        let perToolHolder = NSMenuItem()
        perToolHolder.view = perTool
        soundMenu.addItem(perToolHolder)
        perToolRowView = perTool

        soundMenu.addItem(.separator())
        let header = NSMenuItem(title: "Alert sound (click to preview)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        soundMenu.addItem(header)

        // Sound picker — keep-open per row, plays a preview on click.
        for sound in AppState.availableSounds {
            let row = KeepOpenRowView(title: sound, checked: sound == state.alertSound)
            row.handler = { [weak self] in
                guard let self else { return }
                let previous = self.state.alertSound
                self.state.setAlertSound(sound)
                if !self.state.soundMuted {
                    NSSound(named: NSSound.Name(sound))?.play()
                }
                self.soundRowViews[previous]?.update(title: previous, checked: false)
                self.soundRowViews[sound]?.update(title: sound, checked: true)
            }
            let holder = NSMenuItem()
            holder.view = row
            soundMenu.addItem(holder)
            soundRowViews[sound] = row
        }
    }
}
