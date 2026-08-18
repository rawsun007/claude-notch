import Foundation
import LocalAuthentication

/// Thin wrapper around LocalAuthentication for confirming a dangerous action
/// with Touch ID (or Face ID). Needs no special permission — the system
/// presents its own biometric sheet. Falls back gracefully when unavailable.
enum BiometricAuth {
    /// True when this Mac has an enrolled biometric we can prompt for.
    static var isAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    /// "Touch ID" / "Face ID" / "biometrics" for labels.
    static var label: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .touchID: return "Touch ID"
        case .faceID:  return "Face ID"
        default:       return "biometrics"
        }
    }

    /// SF Symbol matching the available biometry.
    static var iconName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType == .faceID ? "faceid" : "touchid"
    }

    /// Present the biometric sheet. `completion` is always called on the main
    /// thread with whether the user authenticated, and with a line to show them
    /// when it failed for a reason they need to know about.
    ///
    /// The evaluation asks for `.deviceOwnerAuthentication`, not the biometrics
    /// -only policy: that adds the system's own "Use Password…" button. Three
    /// unrecognised fingers locks biometry out until the Mac is unlocked with a
    /// password, and with the stricter policy that left the only way to allow a
    /// dangerous command behind a sheet that could no longer succeed. The
    /// availability check above stays biometrics-only, because it decides
    /// whether to offer the button at all, and a password prompt is not what
    /// "use Touch ID for dangerous commands" was asking for.
    static func confirm(reason: String, completion: @escaping (Bool, String?) -> Void) {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            DispatchQueue.main.async { completion(false, failureMessage(for: err)) }
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            DispatchQueue.main.async {
                completion(ok, ok ? nil : failureMessage(for: error as NSError?))
            }
        }
    }

    /// What to tell the user, or nil when there is nothing worth saying.
    ///
    /// Cancelling is a decision, not a failure: the card stays as it was and
    /// says nothing, because the user just said no. Everything else leaves them
    /// pressing a button that appears to do nothing, which is the state this
    /// exists to prevent.
    nonisolated static func failureMessage(for error: NSError?) -> String? {
        guard let error else { return nil }
        switch LAError.Code(rawValue: error.code) {
        case .userCancel, .appCancel, .systemCancel:
            return nil
        case .userFallback:
            return nil   // the system is showing its own password prompt
        case .biometryLockout:
            return L("Too many attempts. Unlock your Mac with your password, then try again.",
                     comment: "Shown on the card when biometry is locked out")
        case .biometryNotEnrolled, .biometryNotAvailable:
            return L("Biometrics are unavailable right now. Use the hold-to-confirm button instead.",
                     comment: "Shown on the card when biometrics cannot be used")
        default:
            return L("That was not confirmed, so nothing was allowed.",
                     comment: "Shown on the card when a biometric confirmation failed for any other reason")
        }
    }
}
