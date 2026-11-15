import Foundation

/// Decides which hosts may be reached over plain `http://`.
///
/// App Transport Security lives in Info.plist and cannot be changed at
/// runtime, so it cannot know the servers an operator types into Settings.
/// The Info.plist therefore allows arbitrary loads and this gate enforces
/// the rule instead: plain HTTP is refused unless the host is local, or is
/// the host of a server address the operator entered in Settings. HTTPS is
/// never touched.
///
/// Registered globally at app start (covers `URLSession.shared`); a session
/// built from its own configuration must add it to `protocolClasses`.
final class PlainHTTPGate: URLProtocol {
    /// Settings keys that hold a server address the operator typed.
    static let settingsKeys = [
        "apiURL", "munkiReportURL", "nanoMDMBaseURL", "kmfddmBaseURL",
        "nanoDEPBaseURL", "mdmDevicesAPIBaseURL", "packageCatalogURL",
        "unifiBaseURL", "mdmPublicURL",
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var enteredHosts: Set<String> = []

    /// Allow the host of an address the operator has typed but that is not
    /// saved to Settings yet (the sign-in screen probes before it saves).
    static func operatorEntered(_ urlString: String) {
        guard let h = host(of: urlString) else { return }
        lock.lock(); enteredHosts.insert(h); lock.unlock()
    }

    static func isAllowed(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return true }
        guard let h = url.host?.lowercased(), !h.isEmpty else { return false }
        if isLocal(h) { return true }
        lock.lock(); let entered = enteredHosts.contains(h); lock.unlock()
        if entered { return true }
        return settingsKeys.contains { host(of: defaults.string(forKey: $0) ?? "") == h }
    }

    /// Loopback, link-local, `.local` and dot-less names: what ATS's
    /// NSAllowsLocalNetworking used to permit.
    static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasSuffix(".local")
            || host.hasPrefix("127.") || host.hasPrefix("169.254.")
            || !(host.contains(".") || host.contains(":"))
    }

    /// Host of a typed address; tolerates a missing scheme ("10.1.2.3:9090").
    static func host(of urlString: String) -> String? {
        let s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let h = URL(string: s)?.host ?? URL(string: "http://" + s)?.host
        return (h?.isEmpty == false) ? h?.lowercased() : nil
    }

    // MARK: URLProtocol: claim only the requests that must be refused.

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return !isAllowed(url)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? "this host"
        client?.urlProtocol(self, didFailWithError: NSError(
            domain: NSURLErrorDomain, code: NSURLErrorAppTransportSecurityRequiresSecureConnection,
            userInfo: [NSLocalizedDescriptionKey:
                "Plain HTTP to \(host) is blocked. Only servers entered in Settings may use http://. Enter this server's address in Settings, or use https://."]))
    }

    override func stopLoading() {}
}
