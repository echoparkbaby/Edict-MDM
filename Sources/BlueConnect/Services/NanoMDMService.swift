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
