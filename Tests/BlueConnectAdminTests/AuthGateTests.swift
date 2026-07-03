import Testing
@testable import BlueConnectAdmin

/// The destructive-action gate decision. The security-critical case is the
/// last one: when the operator requires auth but the Mac can't evaluate any
/// (no Touch ID, no device password), the gate must DENY — the old code
/// silently allowed the erase/unenroll.
@Suite("AuthGate destructive gate")
struct AuthGateTests {
    @Test func notRequiredAlwaysAllows() {
        #expect(AuthGate.destructiveGate(required: false, canEvaluate: false) == .allow)
        #expect(AuthGate.destructiveGate(required: false, canEvaluate: true) == .allow)
    }

    @Test func requiredWithEvaluableAuthPrompts() {
        #expect(AuthGate.destructiveGate(required: true, canEvaluate: true) == .promptUser)
    }

    @Test func requiredWithoutEvaluableAuthFailsClosed() {
        #expect(AuthGate.destructiveGate(required: true, canEvaluate: false) == .denyNoAuth)
    }
}
