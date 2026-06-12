import Foundation

/// One enrollment row from the enrollments sidecar on the MDM server —
/// a tiny read-only HTTP service in front of NanoMDM's database, since
/// NanoMDM exposes no list-enrollments API of its own. Device-type rows
/// are the Macs; User-type rows are their per-user channels.
struct MDMEnrollment: Decodable, Identifiable, Hashable {
    let id: String
    let type: String
    let enabled: Int
    let lastSeenAt: String?
    let createdAt: String?
    let serialNumber: String?

    enum CodingKeys: String, CodingKey {
        case id, type, enabled
        case lastSeenAt = "last_seen_at"
        case createdAt = "created_at"
        case serialNumber = "serial_number"
    }

    var isDevice: Bool { type == "Device" }
    var isEnabled: Bool { enabled != 0 }

    var lastSeenDate: Date? {
        guard let s = lastSeenAt else { return nil }
        return Self.iso.date(from: s)
    }

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// The MDM push certificate's identity + expiry, served by the sidecar.
struct PushCertInfo: Decodable {
    let topic: String
    let notAfter: String

    enum CodingKeys: String, CodingKey {
        case topic
        case notAfter = "not_after"
    }

    var expiryDate: Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: notAfter)
    }

    var daysLeft: Int? {
        guard let d = expiryDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: d).day
    }
}

/// A device's reply to a queued command, from nanomdm's command_results.
struct CommandResult: Decodable {
    let status: String
    /// Raw plist string the device returned (e.g. a ProfileList /
    /// InstalledApplicationList response). Empty for terminal NotNow.
    let result: String

    /// Parse a top-level array out of the result plist by key, e.g.
    /// "ProfileList" or "InstalledApplicationList", as dictionaries.
    func array(_ key: String) -> [[String: Any]] {
        guard let data = result.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arr = obj[key] as? [[String: Any]]
        else { return [] }
        return arr
    }
}

/// Client for the enrollments sidecar. Auth matches NanoMDM's admin API
/// (Basic, user `nanomdm`, same key) so the operator configures one key.
struct EnrollmentsAPI {
    let baseURL: String
    let apiKey: String

    @MainActor
    init(settings: SettingsStore) {
        self.baseURL = settings.mdmDevicesAPIBaseURL
        self.apiKey = settings.nanoMDMAPIKey
    }

    /// `GET /v1/enrollments` → every enrollment NanoMDM knows about.
    func list() async throws -> [MDMEnrollment] {
        let data = try await request("v1/enrollments")
        do {
            return try JSONDecoder().decode([MDMEnrollment].self, from: data)
        } catch {
            throw MDMError.transport("Unexpected response shape: \(error)")
        }
    }

    /// `DELETE /v1/enrollments/<deviceID>` — purge every row the MDM
    /// database holds for an unenrolled device (enrollments, device
    /// record, command history, cert association). The server refuses
    /// with 409 while the device is still enrolled.
    func purge(deviceID: String) async throws {
        let esc = deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceID
        _ = try await request("v1/enrollments/\(esc)", method: "DELETE")
    }

    /// `GET /v1/commandresult/<uuid>` → the result a device returned for a
    /// queued command, or nil while it hasn't answered yet (404). `result`
    /// is the raw plist string the device sent.
    func commandResult(uuid: String) async throws -> CommandResult? {
        do {
            let data = try await request("v1/commandresult/\(uuid)")
            return try JSONDecoder().decode(CommandResult.self, from: data)
        } catch MDMError.http(404, _) {
            return nil
        }
    }

    /// `GET /v1/pushcert` → the APNs push certificate's topic and expiry,
    /// read from NanoMDM's store. An expired push cert silently kills the
    /// whole MDM, so the app surfaces a countdown.
    func pushCert() async throws -> PushCertInfo {
        let data = try await request("v1/pushcert")
        do {
            return try JSONDecoder().decode(PushCertInfo.self, from: data)
        } catch {
            throw MDMError.transport("Unexpected response shape: \(error)")
        }
    }

    private func request(_ path: String, method: String = "GET") async throws -> Data {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !apiKey.isEmpty else { throw MDMError.notConfigured }
        let joined = base.hasSuffix("/") ? base + path : base + "/" + path
        guard let url = URL(string: joined) else { throw MDMError.badURL(joined) }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        let token = Data("nanomdm:\(apiKey)".utf8).base64EncodedString()
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw MDMError.transport("Non-HTTP response")
            }
            guard (200...299).contains(http.statusCode) else {
                throw MDMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            return data
        } catch let e as MDMError {
            throw e
        } catch {
            throw MDMError.transport(error.localizedDescription)
        }
    }
}
