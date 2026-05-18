import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var state: OnboardingState
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    StepRow(
                        title: "Accessibility",
                        description: "Lets ClaudeNotch type your answers and messages into the terminal — needed for AskUserQuestion replies and the Send-to-Claude composer.",
                        done: state.accessibility,
                        actionLabel: state.accessibility ? "Granted" : "Open Settings",
                        action: state.requestAccessibility
                    )
                    StepRow(
                        title: "Input Monitoring",
                        description: "Lets the notch receive global Enter / Escape shortcuts so you can resolve prompts without raising the app.",
                        done: state.inputMonitoring,
                        actionLabel: state.inputMonitoring ? "Granted" : "Open Settings",
                        action: state.requestInputMonitoring
                    )
                    StepRow(
                        title: "Claude Code hooks",
                        description: "Wires permission prompts, notifications, and questions through the notch. Backs up your existing ~/.claude/settings.json first.",
                        done: state.hooksInstalled,
                        actionLabel: state.isInstallingHooks
                            ? "Installing…"
                            : (state.hooksInstalled ? "Installed" : "Install"),
                        action: state.installHooks,
                        busy: state.isInstallingHooks,
                        errorText: state.hookInstallError
                    )
                    if !state.hasJq {
                        JqWarningRow(action: state.copyBrewInstallCommand)
                    }
                    StepRow(
                        title: "Launch at login",
                        description: "Optional. Start ClaudeNotch automatically when you log in so it's always ready.",
                        done: state.launchAtLogin,
                        actionLabel: state.launchAtLogin ? "Enabled" : "Enable",
                        action: state.toggleLaunchAtLogin,
                        optional: true
                    )
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
            }
            Divider().opacity(0.4)
            footer
        }
        .background(WindowBackground())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to ClaudeNotch")
                .font(.system(size: 22, weight: .semibold))
            Text("Two quick permissions and a one-click hook install. Then your Claude Code prompts appear in the notch instead of your terminal.")
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
                 ? "All set — you're ready to go."
                 : "Finish the required steps to start using ClaudeNotch.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Button(state.allRequiredDone ? "Done" : "Close") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
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

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            statusBadge
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if optional {
                        Text("optional")
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
            .disabled(done || busy)
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
                Text("Install jq (recommended)")
                    .font(.system(size: 14, weight: .semibold))
                Text("ClaudeNotch's post-tool hook needs jq to forward what Claude just did. Without it, the notch won't show the live activity line.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(copied ? "Copied" : "Copy `brew install jq`") {
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
