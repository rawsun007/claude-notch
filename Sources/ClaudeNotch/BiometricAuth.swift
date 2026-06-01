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
    /// thread with whether the user authenticated successfully.
    static func confirm(reason: String, completion: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
