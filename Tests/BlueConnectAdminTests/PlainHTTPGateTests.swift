import Testing
import Foundation
@testable import BlueConnectAdmin

/// Plain http:// is allowed only to local hosts and hosts the operator
/// entered in Settings. Uses a throwaway UserDefaults suite.
@Suite("Plain HTTP gate")
struct PlainHTTPGateTests {
    private func defaults(_ values: [String: String] = [:]) -> UserDefaults {
        let d = UserDefaults(suiteName: "http-gate-test-\(UUID().uuidString)")!
        for (k, v) in values { d.set(v, forKey: k) }
        return d
    }
    private func allowed(_ s: String, _ d: UserDefaults) -> Bool {
        PlainHTTPGate.isAllowed(URL(string: s)!, defaults: d)
    }

    @Test func httpsIsNeverBlocked() {
        #expect(allowed("https://anything.example.com/x", defaults()))
    }

    @Test func unknownHostIsBlocked() {
        #expect(!allowed("http://192.0.2.10:9090/v1", defaults()))
        #expect(!allowed("http://example.com/", defaults()))
    }

    @Test func hostFromSettingsIsAllowedOnAnyPort() {
        let d = defaults(["nanoMDMBaseURL": " http://192.0.2.10:9090 "])
        #expect(allowed("http://192.0.2.10:9090/v1/enqueue", d))
        #expect(allowed("http://192.0.2.10:9093/v1/declarations", d))
        #expect(!allowed("http://192.0.2.11:9090/", d))
    }

    @Test func settingWithoutSchemeStillCounts() {
        let d = defaults(["munkiReportURL": "MR.Example.com:8080"])
        #expect(allowed("http://mr.example.com:8080/index.php", d))
    }

    @Test func localNamesAreAllowed() {
        let d = defaults()
        for u in ["http://localhost:8080/", "http://127.0.0.1:9090/", "http://munki.local/", "http://nas/", "http://[::1]:80/"] {
            #expect(allowed(u, d), "\(u)")
        }
    }

    @Test func operatorEnteredAllowsBeforeSave() {
        let d = defaults()
        #expect(!allowed("http://198.51.100.7:8095/bs_hosts.json.php", d))
        PlainHTTPGate.operatorEntered("http://198.51.100.7:8095")
        #expect(allowed("http://198.51.100.7:8095/bs_hosts.json.php", d))
    }

    /// End to end: once registered, URLSession.shared really refuses the
    /// request (no network needed; it fails before connecting).
    @Test func sharedSessionRefusesBlockedHost() async {
        URLProtocol.registerClass(PlainHTTPGate.self)
        defer { URLProtocol.unregisterClass(PlainHTTPGate.self) }
        do {
            _ = try await URLSession.shared.data(from: URL(string: "http://203.0.113.9:9/x")!)
            Issue.record("request should have been refused")
        } catch {
            #expect(error.localizedDescription.contains("blocked"))
        }
    }
}
