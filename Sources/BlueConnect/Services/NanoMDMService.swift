import Foundation

/// Shared error for the Edict MDM admin clients (NanoMDM + KMFDDM).
enum MDMError: LocalizedError {
    case notConfigured
    case badURL(String)
    case transport(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:        return "MDM server URL or API key is not set."
        case .badURL(let s):        return "Invalid URL: \(s)"
        case .transport(let s):     return s
        case .http(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "HTTP \(code)" + (trimmed.isEmpty ? "" : ": \(trimmed.prefix(200))")
        }
    }
}

/// Client for a NanoMDM **admin** API, reached over the tailnet
/// (e.g. `http://192.0.2.10:9090`). HTTP Basic auth with username
/// `nanomdm` and the API key as the password. These are the operator
/// endpoints (version / push / enqueue / pushcert) — distinct from the
/// public device-facing `/mdm` checkin path that enrolled Macs hit
/// through the reverse proxy.
struct NanoMDMService {
    let baseURL: String
    let apiKey: String
    private let user = "nanomdm"

    @MainActor
    init(settings: SettingsStore) {
        self.baseURL = settings.nanoMDMBaseURL
        self.apiKey = settings.nanoMDMAPIKey
    }

    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// `GET /version` — connectivity + auth-free health check. Returns the
    /// reported version string (often "unknown" for source builds).
    func version() async throws -> String {
        let (data, _) = try await request("version", authenticated: false)
        struct V: Decodable { let version: String }
        if let v = try? JSONDecoder().decode(V.self, from: data) { return v.version }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    /// `GET /v1/push/<id>` — send an APNs push to wake the device(s).
    /// Multiple IDs may be comma-separated.
    @discardableResult
    func push(enrollmentIDs: String) async throws -> Data {
        let (data, _) = try await request("v1/push/\(enrollmentIDs)")
        return data
    }

    /// `PUT /v1/enqueue/<id>` — queue a raw MDM command (plist body) and
    /// push. Multiple IDs may be comma-separated.
    @discardableResult
    func enqueue(enrollmentIDs: String, commandPlist: Data) async throws -> Data {
        let (data, _) = try await request("v1/enqueue/\(enrollmentIDs)",
                                          method: "PUT", body: commandPlist)
        return data
    }

    /// Remotely unenroll a device: enqueue a `RemoveProfile` for the
    /// enrollment profile's PayloadIdentifier. Removing the enrollment
    /// profile takes the MDM payload (and the device's management) with
    /// it — the device checks out and NanoMDM marks the enrollment
    /// inactive. Works on manually-enrolled Macs; the device must be
    /// online to receive the push.
    @discardableResult
    func unenroll(enrollmentID: String, profileIdentifier: String) async throws -> Data {
        try await enqueue(enrollmentIDs: enrollmentID,
                          commandPlist: Self.removeProfileCommand(identifier: profileIdentifier))
    }

    /// Queue an `InstalledApplicationList` query. Returns the command
    /// UUID to poll for the result.
    func requestInstalledApps(enrollmentID: String) async throws -> String {
        let (uuid, plist) = Self.commandWithUUID([("RequestType", "InstalledApplicationList")])
        _ = try await enqueue(enrollmentIDs: enrollmentID, commandPlist: plist)
        return uuid
    }

    /// Queue a `ProfileList` query. Returns the command UUID.
    func requestProfileList(enrollmentID: String) async throws -> String {
        let (uuid, plist) = Self.commandWithUUID([("RequestType", "ProfileList")])
        _ = try await enqueue(enrollmentIDs: enrollmentID, commandPlist: plist)
        return uuid
    }

    /// Queue an `InstallProfile` of a configuration profile (mobileconfig
    /// bytes). The profile installs on the device's next checkin.
    @discardableResult
    func installProfile(enrollmentID: String, profile: Data) async throws -> Data {
        let b64 = profile.base64EncodedString()
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Command</key>
        \t<dict>
        \t\t<key>RequestType</key>
        \t\t<string>InstallProfile</string>
        \t\t<key>Payload</key>
        \t\t<data>\(b64)</data>
        \t</dict>
        \t<key>CommandUUID</key>
        \t<string>\(UUID().uuidString)</string>
        </dict>
        </plist>
        """
        return try await enqueue(enrollmentIDs: enrollmentID, commandPlist: Data(plist.utf8))
    }

    /// Queue a `RemoveProfile` for an arbitrary installed profile by its
    /// PayloadIdentifier (not just the enrollment profile).
    @discardableResult
    func removeProfile(enrollmentID: String, identifier: String) async throws -> Data {
        try await enqueue(enrollmentIDs: enrollmentID,
                          commandPlist: Self.removeProfileCommand(identifier: identifier))
    }

    /// Queue a `RestartDevice` command.
    @discardableResult
    func restart(enrollmentID: String) async throws -> Data {
        try await enqueue(enrollmentIDs: enrollmentID,
                          commandPlist: Self.command([("RequestType", "RestartDevice")]))
    }

    /// Lock the Mac behind a 6-digit PIN (lost/stolen response). The
    /// device reboots into a lock screen and won't proceed without the
    /// PIN. Optional message is shown on that screen.
    @discardableResult
    func lock(enrollmentID: String, pin: String, message: String?) async throws -> Data {
        var keys: [(String, String)] = [("RequestType", "DeviceLock"), ("PIN", pin)]
        if let m = message, !m.isEmpty { keys.append(("Message", m)) }
        return try await enqueue(enrollmentIDs: enrollmentID,
                                 commandPlist: Self.command(keys))
    }

    /// Remote-erase the Mac. The PIN unlocks it after the wipe on
    /// Intel/T2 machines; Apple Silicon ignores it but the protocol
    /// requires it. There is no undo.
    @discardableResult
    func erase(enrollmentID: String, pin: String) async throws -> Data {
        try await enqueue(enrollmentIDs: enrollmentID,
                          commandPlist: Self.command([("RequestType", "EraseDevice"),
                                                      ("PIN", pin)]))
    }

    /// Minimal MDM command plist for `RemoveProfile`. Removing the
    /// enrollment profile unenrolls the device.
    static func removeProfileCommand(identifier: String) -> Data {
        command([("RequestType", "RemoveProfile"), ("Identifier", identifier)])
    }

    /// Build a one-level MDM command plist from string key/value pairs.
    static func command(_ pairs: [(String, String)]) -> Data {
        commandWithUUID(pairs).plist
    }

    /// Same, but returns the generated CommandUUID too — needed when the
    /// caller wants to poll for the device's result (inventory queries).
    /// Values are XML-escaped.
    static func commandWithUUID(_ pairs: [(String, String)]) -> (uuid: String, plist: Data) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let uuid = UUID().uuidString
        let body = pairs
            .map { "\t\t<key>\(esc($0.0))</key>\n\t\t<string>\(esc($0.1))</string>" }
            .joined(separator: "\n")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Command</key>
        \t<dict>
        \(body)
        \t</dict>
        \t<key>CommandUUID</key>
        \t<string>\(uuid)</string>
        </dict>
        </plist>
        """
        return (uuid, Data(plist.utf8))
    }

    // MARK: - HTTP

    private func request(_ path: String,
                         method: String = "GET",
                         body: Data? = nil,
                         authenticated: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, (authenticated == false || !apiKey.isEmpty) else {
            throw MDMError.notConfigured
        }
        let joined = base.hasSuffix("/") ? base + path : base + "/" + path
        guard let url = URL(string: joined) else { throw MDMError.badURL(joined) }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 15
        if authenticated {
            let token = Data("\(user):\(apiKey)".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw MDMError.transport("Non-HTTP response")
            }
            guard (200...299).contains(http.statusCode) else {
                throw MDMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            return (data, http)
        } catch let e as MDMError {
            throw e
        } catch {
            throw MDMError.transport(error.localizedDescription)
        }
    }
}
