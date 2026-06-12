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
