import SwiftUI

/// Why the Auto-Approve sheet is up: switching it on, or changing its choices.
enum AutoApproveSheetMode: String, Identifiable {
    case turnOn, edit
    var id: String { rawValue }
}

/// The sheet that comes up when Auto-Approve is switched on (and from its
/// Change button): what it should answer for you, and what it does with a
/// destructive command. Nothing changes until Turn On / Save; cancelling
/// leaves Auto-Approve exactly as it was.
struct AutoApproveSetupSheet: View {
    @ObservedObject var state: AppState
    /// True when Auto-Approve is already on and this only edits the choices.
    let editing: Bool
    let onClose: () -> Void

    @State private var scope: AutoApproveScope
    @State private var dangerous: AutoApproveDangerous
    @State private var waitingForAuth = false

    init(state: AppState, editing: Bool, onClose: @escaping () -> Void) {
        self.state = state
        self.editing = editing
        self.onClose = onClose
        _scope = State(initialValue: state.autoApproveScope)
        _dangerous = State(initialValue: state.autoApproveDangerous)
    }

    private var dangerousChoices: [AutoApproveDangerous] {
        // Without biometrics there is no prompt to bring up on its own.
        BiometricAuth.isAvailable ? AutoApproveDangerous.allCases : [.ask, .allow]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Auto-approve permissions", comment: "Auto-Approve setup sheet title"))
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(L("What should it approve for you?", comment: "Auto-Approve setup sheet question"))
                    .font(.headline)
                Picker("", selection: $scope) {
                    ForEach(AutoApproveScope.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(scope.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Destructive commands", comment: "Auto-Approve setup sheet question"))
                    .font(.headline)
                Text(L("Deleting files, sudo, force pushes and the like: the ones that get the red card.", comment: "Auto-Approve setup sheet explanation"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $dangerous) {
                    ForEach(dangerousChoices, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Label(dangerous.explanation, systemImage: dangerous == .allow ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(dangerous == .allow ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.strictMode {
                    Label(L("Strict mode is on, so only commands that read and change nothing are approved for you, whatever is chosen here.", comment: "Auto-Approve setup sheet note"), systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = state.autoApproveDangerousMessage {
                    Label(message, systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button(L("Cancel", comment: "Button")) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(editing ? L("Save", comment: "Button") : L("Turn On", comment: "Button: switch Auto-Approve on")) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(waitingForAuth)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { state.autoApproveDangerousMessage = nil }
    }

    private func apply() {
        state.setAutoApproveScope(scope)
        waitingForAuth = true
        state.setAutoApproveDangerous(dangerous) { ok in
            waitingForAuth = false
            guard ok else { return }   // the sheet stays, with the reason under the choice
            if !editing { state.setAutoApprove(true) }
            onClose()
        }
    }
}
