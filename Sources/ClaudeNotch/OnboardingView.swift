import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var state: OnboardingState
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            VStack(spacing: 10) {
                StepRow(
                    title: L("Accessibility", comment: "Onboarding step name for the accessibility permission"),
                    description: L("Lets ClaudeNotch type your answers and messages into the terminal, needed for AskUserQuestion replies and the Send-to-Claude composer.", comment: "Onboarding step description for the accessibility permission"),
                    done: state.accessibility,
                    actionLabel: state.accessibility
                        ? L("Granted", comment: "Onboarding button state when a permission is already given")
                        : L("Open Settings", comment: "Onboarding button: open the macOS settings pane for a permission"),
                    action: state.requestAccessibility,
                    needsRelaunch: state.accessibilityNeedsRelaunch,
                    relaunch: state.relaunch
                )
                StepRow(
                    title: L("Input Monitoring", comment: "Onboarding step name for the input monitoring permission"),
                    description: L("Lets the notch receive global Enter / Escape shortcuts so you can resolve prompts without raising the app.", comment: "Onboarding step description for the input monitoring permission"),
                    done: state.inputMonitoring,
                    actionLabel: state.inputMonitoring
                        ? L("Granted", comment: "Onboarding button state when a permission is already given")
                        : L("Open Settings", comment: "Onboarding button: open the macOS settings pane for a permission"),
                    action: state.requestInputMonitoring,
                    needsRelaunch: state.inputMonitoringNeedsRelaunch,
                    relaunch: state.relaunch
                )
                StepRow(
                    title: L("Claude Code hooks", comment: "Onboarding step name for installing the hooks"),
                    description: L("Wires permission prompts, notifications, and questions through the notch. Backs up your existing ~/.claude/settings.json first.", comment: "Onboarding step description for installing the hooks"),
                    done: state.hooksInstalled,
                    actionLabel: state.isInstallingHooks
                        ? L("Installing…", comment: "Onboarding button state while the hooks are being written")
                        : (state.hooksInstalled
                           ? L("Installed", comment: "Onboarding button state once the hooks are in place")
                           : L("Install", comment: "Onboarding button: write the hooks")),
                    action: state.installHooks,
                    busy: state.isInstallingHooks,
                    errorText: state.hookInstallError
                )
                if !state.hasJq {
                    JqWarningRow(action: state.copyBrewInstallCommand)
                }
                StepRow(
                    title: L("Launch at login", comment: "Onboarding step name for the login item"),
                    description: L("Optional. Start ClaudeNotch automatically when you log in so it's always ready.", comment: "Onboarding step description for the login item"),
                    done: state.launchAtLogin,
                    actionLabel: state.launchAtLogin
                        ? L("Enabled", comment: "Onboarding button state when an optional step is on")
                        : L("Enable", comment: "Onboarding button: turn an optional step on"),
                    action: state.toggleLaunchAtLogin,
                    optional: true
                )
                StepRow(
                    title: L("Auto-approve everything", comment: "Onboarding step name for auto-approval"),
                    description: L("Optional. Skip the Allow/Deny buttons, every tool is allowed automatically and the notch just shows what's changing. Destructive commands still ask. Toggle anytime from the menu bar.", comment: "Onboarding step description for auto-approval"),
                    done: state.autoApprove,
                    actionLabel: state.autoApprove
                        ? L("Turn Off", comment: "Onboarding button: switch auto-approval off")
                        : L("Turn On", comment: "Onboarding button: switch auto-approval on"),
                    action: state.toggleAutoApprove,
                    optional: true,
                    alwaysEnabled: true
                )
                NameRow(name: Binding(get: { state.notchName }, set: { state.notchName = $0 }))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowBackground())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Welcome to ClaudeNotch", comment: "Onboarding window title"))
                .font(.system(size: 22, weight: .semibold))
            Text(L("Two quick permissions and a one-click hook install. Then your Claude Code prompts appear in the notch instead of your terminal.", comment: "Onboarding window subtitle"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            ProgressDots(done: state.allRequiredDone)
            Text(state.allRequiredDone
                 ? L("All set. Tip: drag any folder onto the notch to start Claude there.", comment: "Onboarding footer once every required step is done")
                 : L("Finish the required steps to start using ClaudeNotch.", comment: "Onboarding footer while required steps remain"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Button(state.allRequiredDone
                   ? L("Done", comment: "Onboarding button: close the finished setup")
                   : L("Close", comment: "Onboarding button: close the unfinished setup")) { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }
}

/// Optional "name your notch" field. Empty keeps the default (the agent name).
/// Mirrors Settings > Notch > Notch Title (custom).
private struct NameRow: View {
    @Binding var name: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "textformat")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L("Name the notch", comment: "Onboarding step name for the custom notch title")).font(.system(size: 14, weight: .semibold))
                    Text(L("optional", comment: "Badge marking an onboarding step you can skip")).font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Text(L("What the notch calls itself. Leave blank to use the agent name (Claude, Codex). Change it anytime in Settings.", comment: "Onboarding step description for the custom notch title"))
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(L("e.g. Robo, Jarvis, my mac", comment: "Placeholder in the notch name field"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 240)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct StepRow: View {
    let title: String
    let description: String
    let done: Bool
    let actionLabel: String
    let action: () -> Void
    var busy: Bool = false
    var optional: Bool = false
    var errorText: String? = nil
    var needsRelaunch: Bool = false
    var relaunch: (() -> Void)? = nil
    var alwaysEnabled: Bool = false   // for toggles that can switch back off

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            statusBadge
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if optional {
                        Text(L("optional", comment: "Badge marking an onboarding step you can skip"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if needsRelaunch, let relaunch {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 12))
                        Text(L("Granted in Settings but not picked up yet. macOS sometimes needs a relaunch.", comment: "Onboarding warning when macOS has not applied a granted permission"))
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("Quit & relaunch", comment: "Onboarding button: restart the app so macOS applies a permission"), action: relaunch)
                            .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
                if let err = errorText {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button(action: action) {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    }
                    Text(actionLabel)
                }
                .frame(minWidth: 78)
            }
            .disabled((done && !alwaysEnabled) || busy)
            .controlSize(.regular)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var statusBadge: some View {
        ZStack {
            Circle()
                .fill(done ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 22, height: 22)
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .padding(.top, 1)
    }
}

private struct JqWarningRow: View {
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.85)).frame(width: 22, height: 22)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Install jq (recommended)", comment: "Onboarding warning row title"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L("ClaudeNotch's post-tool hook needs jq to forward what Claude just did. Without it, the notch won't show the live activity line.", comment: "Onboarding warning row body"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(copied
                   ? L("Copied", comment: "Button state right after copying to the clipboard")
                   : L("Copy `brew install jq`", comment: "Onboarding button: copy the jq install command")) {
                action()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
            }
            .frame(minWidth: 78)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
    }
}

private struct ProgressDots: View {
    let done: Bool
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

private struct WindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .windowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
