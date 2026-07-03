import Foundation
import LocalAuthentication
import SwiftUI

@MainActor
final class AuthGate: ObservableObject {
    enum State {
        case needsLogin    // First launch — no saved credentials
        case locked        // Saved + Touch ID required
        case unlocked      // Ready
    }

    @Published var state: State = .needsLogin
    @Published var lastError: String?

    @AppStorage("hasSavedLogin") var hasSavedLogin: Bool = false
    @AppStorage("requireTouchID") var requireTouchID: Bool = false
    @AppStorage("requireTouchIDForDestructive") var requireTouchIDForDestructive: Bool = true

    /// Determines initial state based on saved login + Touch ID preference.
    func bootstrap(settings: SettingsStore) {
        if hasSavedLogin {
            settings.loadPasswordFromKeychain()
            if settings.webAdminPass.isEmpty {
                state = .needsLogin
                hasSavedLogin = false
                return
            }
            state = requireTouchID ? .locked : .unlocked
        } else {
            state = .needsLogin
        }
    }

    var isBiometricsAvailable: Bool {
        let ctx = LAContext()
        var err: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
    }

    func unlockWithTouchID() async {
        guard state == .locked else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use password…"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // No biometrics AND no device password: the Mac has no OS-level
            // auth, so the app-lock is moot and failing closed would strand the
            // operator on the lock screen with no way in. Unlock, but log why —
            // unlike the destructive gate, blocking access here helps no one.
            Log.warn("Auth", "App-lock bypassed — cannot evaluate auth policy "
                + "(\(err?.localizedDescription ?? "unknown"))")
            state = .unlocked
            lastError = err?.localizedDescription
            return
        }
        do {
            let ok = try await ctx.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock BlueConnect Admin"
            )
            if ok { state = .unlocked }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func lock() {
        if hasSavedLogin && requireTouchID { state = .locked }
    }

    func logout(settings: SettingsStore) {
        settings.clearCredentials()
        hasSavedLogin = false
        requireTouchID = false
        state = .needsLogin
    }

    /// The destructive-gate decision, factored out so the fail-closed logic
    /// is unit-testable without a live biometric prompt.
    enum DestructiveGate: Equatable { case allow, promptUser, denyNoAuth }
    nonisolated static func destructiveGate(required: Bool, canEvaluate: Bool) -> DestructiveGate {
        guard required else { return .allow }
        return canEvaluate ? .promptUser : .denyNoAuth
    }

    /// Touch ID / device-password gate for destructive fleet actions (erase,
    /// unenroll, unblock). Fails CLOSED: if the operator required this gate but
    /// the Mac can't evaluate biometrics OR a device password — no auth method
    /// available, or a transient LAContext error — the action is blocked
    /// instead of silently allowed (the old fail-open). The escape hatch is the
    /// Settings toggle "Confirm destructive actions with Touch ID".
    func confirmDestructive(reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use password…"
        var err: NSError?
        let canEvaluate = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
        switch Self.destructiveGate(required: requireTouchIDForDestructive, canEvaluate: canEvaluate) {
        case .allow:
            return true
        case .denyNoAuth:
            lastError = "Couldn't verify your identity — this Mac has no Touch ID or "
                + "device password available, so the action was blocked. Turn off "
                + "“Confirm destructive actions with Touch ID” in Settings to proceed "
                + "without it."
            Log.warn("Auth", "Destructive action blocked — no evaluable auth policy "
                + "(\(err?.localizedDescription ?? "unknown")). reason=\(reason)")
            return false
        case .promptUser:
            do {
                return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch {
                // User cancelled or auth failed — the action does not run.
                return false
            }
        }
    }

    /// Mark login successful and persist preferences.
    func onLoginSuccess(enableTouchID: Bool) {
        hasSavedLogin = true
        requireTouchID = enableTouchID
        state = .unlocked
    }

    /// User chose "explore without a server" on the login screen. We
    /// don't persist this as "saved login" — they're explicitly in a
    /// stateless trial mode. Next launch will land on the login screen
    /// again (zero-friction return). Munki Repo, Settings, Quick
    /// Actions, Tailscale / Local Network discovery, and the inventory
    /// pane all still work; the BSC-backed host list is just empty.
    func skipLogin() {
        hasSavedLogin = false
        state = .unlocked
    }
}
